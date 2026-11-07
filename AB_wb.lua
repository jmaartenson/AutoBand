-- AB_wb.lua

AB_wb = {
    group = {},
    player_count = 0,
    group_count = 0,
    fullgroup_count = 0,
    remainder = 0,
    MAX_GROUPS = 0            -- max number of groups (wb=4, sc=6)
}

-- Mapping of base careers to an alternate career line when the player
-- is detected as playing a DPS spec via RoRGroupScoreboard.
-- Primarily targets healers, but includes some RDPS that shift under scoreboard data.
local ALT_SPEC_TRANSFORMS = {
    [GameData.CareerLine.ZEALOT]        = GameData.CareerLine.MAGUS,
    [GameData.CareerLine.WARRIOR_PRIEST] = GameData.CareerLine.SLAYER,
    [GameData.CareerLine.RUNE_PRIEST]    = GameData.CareerLine.ENGINEER,
    [GameData.CareerLine.ARCHMAGE]       = GameData.CareerLine.ENGINEER,
    [GameData.CareerLine.SHAMAN]         = GameData.CareerLine.MAGUS,
    [GameData.CareerLine.DISCIPLE]       = GameData.CareerLine.CHOPPA,
    [GameData.CareerLine.SQUIG_HERDER]   = GameData.CareerLine.CHOPPA,
    [GameData.CareerLine.SHADOW_WARRIOR] = GameData.CareerLine.SLAYER,
}

local function should_exclude_realm_healer_alt_spec(career_line)
    if not AutoBand or not AutoBand.saved or AutoBand.saved.exclude_realm_healer_alt_spec ~= true then
        return false
    end
    if AutoBand.faction == AB_const.ORDER then
        return career_line == GameData.CareerLine.RUNE_PRIEST
    end
    if AutoBand.faction == AB_const.DESTRUCTION then
        return career_line == GameData.CareerLine.ZEALOT
    end
    return career_line == GameData.CareerLine.RUNE_PRIEST or career_line == GameData.CareerLine.ZEALOT
end

local function get_alt_spec_transformed_career(career_line)
    if should_exclude_realm_healer_alt_spec(career_line) then
        return career_line
    end
    return ALT_SPEC_TRANSFORMS[career_line] or career_line
end

local function make_colored_text(text, rgb, fallback)
    local color = rgb or fallback or { 255, 255, 255 }
    local r = color[1] or 255
    local g = color[2] or 255
    local b = color[3] or 255
    return string.format("<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">", r, g, b, text)
end

local function color_parenthetical(text)
    return make_colored_text(text, AB_const.COLOR_SILVER, { 192, 192, 192 })
end

local function should_show_arrival_notification_tag()
    return AutoBand and AutoBand.saved and AutoBand.saved.print_arrival_notify_tags_enabled == true
end

local function format_name_with_level(name, level, career_line)
    local lvl_number = tonumber(level)
    local rr_number = nil
    if AutoBand and AutoBand.get_realm_rank_for_name then
        local ok_rr, rr = pcall(AutoBand.get_realm_rank_for_name, name)
        if ok_rr and rr ~= nil then
            rr = tonumber(rr)
            if rr then
                rr_number = math.floor(rr)
            end
        end
    end
    local career_icon = nil
    if career_line and AB_const.CAREERLINE_ICON_MAP then
        career_icon = AB_const.CAREERLINE_ICON_MAP[career_line]
    end

    if lvl_number then
        local rank_parts = { "CR " .. tostring(lvl_number) }
        if rr_number and rr_number >= 0 then
            rank_parts[#rank_parts + 1] = "RR " .. tostring(rr_number)
        end
        local rank_text = color_parenthetical("(" .. table.concat(rank_parts, ", ") .. ")")
        if career_icon then
            return career_icon .. " " .. rank_text .. " " .. name
        end
        return rank_text .. " " .. name
    end

    if career_icon then
        return career_icon .. " " .. name
    end

    return name
end

local function format_arrival_tag_from_entry(entry)
    if not should_show_arrival_notification_tag() then
        return ""
    end
    if not entry or type(entry) ~= "table" then
        return ""
    end
    local idx = entry.arrival_index
    if not idx then
        return ""
    end
    local total = entry.arrival_total
    if total and total > 0 then
        return " " .. color_parenthetical("(arr " .. tostring(idx) .. "/" .. tostring(total) .. ")")
    end
    return " " .. color_parenthetical("(arr " .. tostring(idx) .. ")")
end

local function get_arrival_tag_for_name(name)
    if not should_show_arrival_notification_tag() then
        return "", nil, nil
    end
    if AutoBand and AutoBand.get_arrival_index then
        local ok, idx, total = pcall(AutoBand.get_arrival_index, name)
        if ok and idx then
            if total and total > 0 then
                return " " .. color_parenthetical("(arr " .. tostring(idx) .. "/" .. tostring(total) .. ")"), idx, total
            end
            return " " .. color_parenthetical("(arr " .. tostring(idx) .. ")"), idx, total
        end
    end
    return "", nil, nil
end

local function get_backfill_route_tag_for_name(name, route_lookup)
    if not route_lookup or type(route_lookup) ~= "table" then
        return ""
    end
    if not AutoBand or not AutoBand.normalize_wb_player_name then
        return ""
    end
    local key = AutoBand.normalize_wb_player_name(name)
    if key and route_lookup[key] then
        return " " .. color_parenthetical("(trim candidate)")
    end
    return ""
end

-- Log leave as soon as a player is missing in the latest update.
local MAX_DETAILED_LEAVERS = 4

-- Build a lookup table of players running alt specs based on
-- RoRGroupScoreboard data. Keys are string player names, values are true.
local function build_name_signature(names)
    if type(names) ~= "table" or #names == 0 then
        return ""
    end
    table.sort(names)
    return table.concat(names, "|")
end

local function build_alt_spec_lookup(preloaded_lookup, preloaded_signature)
    if type(preloaded_lookup) == "table" then
        return preloaded_lookup, preloaded_signature or ""
    end
    if AutoBand and AutoBand._core_api and type(AutoBand._core_api.build_alt_spec_snapshot) == "function" then
        local lookup_from_core, signature_from_core = AutoBand._core_api.build_alt_spec_snapshot()
        if type(lookup_from_core) == "table" then
            return lookup_from_core, signature_from_core or ""
        end
    end

    local lookup = {}
    local raw = RoRGroupScoreboard and RoRGroupScoreboard.playersDataRaw
    if type(raw) == "table" then
        local names = {}
        for _, pdata in pairs(raw) do
            if pdata.archtype and pdata.archtype > 0 and pdata.name then
                lookup[tostring(pdata.name)] = true
                names[#names + 1] = tostring(pdata.name)
            end
        end
        return lookup, build_name_signature(names)
    end
    return lookup, ""
end

-- default ctor
function AB_wb:new(t)
    t = t or {}
    setmetatable(t, self)
    self.__index = self
    return t
end

function AB_wb:set_groups()
    self.group = {}
    self.player_count = 0
    self.MAX_GROUPS = AB_const.MAX_WB_GROUPS
    for i= 1, AB_const.MAX_WB_GROUPS do
        self.group[i] = {}
    end
end

function AB_wb:add_to_gid(role, pid, gid)
    local player = {["name"]= "Fake_" .. gid .. "_" .. pid }
    for key, fake in pairs(AB_const.FAKE_PLAYERS[role]) do
        player[key] = fake
    end
    player.role = role
    player.online = false
    player.zid = 0
    table.insert(self.group[gid], player)
    self.player_count = self.player_count + 1
end

-- loads group data from warband party
function AB_wb:load_from_wbdata(wbdata, preload)
    self.group = {}
    self.player_count = 0
    local alt_lookup = nil
    preload = type(preload) == "table" and preload or nil
    self.roster_signature = preload and preload.roster_signature or nil
    self.alt_spec_signature = preload and preload.alt_spec_signature or nil
    if AutoBand.saved.alt_speccheck_enabled then
        alt_lookup, self.alt_spec_signature = build_alt_spec_lookup(preload and preload.alt_lookup, self.alt_spec_signature)
    end
    wbdata = wbdata or GetBattlegroupMemberData()
    if type(wbdata) ~= "table" then
        error("invalid warband data")
    end
    local roster_names = nil
    if type(self.roster_signature) ~= "string" then
        roster_names = {}
    end
    for i in ipairs(wbdata) do
        self.group[i] = {}
    end
    for gid, grp in ipairs(wbdata) do
        for _, player in ipairs(grp.players) do
            if roster_names and player and player.name then
                roster_names[#roster_names + 1] = tostring(player.name)
            end
            local name_lower = tostring(player.name):lower()
            local override = AutoBand.saved.custom_roles and AutoBand.saved.custom_roles[name_lower]
            local base_career = player.careerLine
            local role
            local role_source = "archetype"

            -- Determine effective career from alt-spec
            local effective_career = base_career
            if AutoBand.saved.alt_speccheck_enabled then
                local career_after_alt_check = AB_wb:getArcheType(player, alt_lookup)
                if career_after_alt_check ~= base_career then
                    role_source = "spec check"
                    effective_career = career_after_alt_check
                end
            end

            role = AB_util.career_category(effective_career)

            -- Check for BW/Sorc as MDPS toggle
            if AutoBand.saved.bw_sorc_as_mdps then
                if base_career == GameData.CareerLine.BRIGHT_WIZARD or base_career == GameData.CareerLine.SORCERER then
                    if role ~= AB_const.MDPS then
                        role = AB_const.MDPS
                        if AutoBand.faction == AB_const.ORDER then
                            role_source = "BW as mDPS"
                        elseif AutoBand.faction == AB_const.DESTRUCTION then
                            role_source = "Sorc as mDPS"
                        else
                            role_source = "BW/Sorc as mDPS"
                        end
                    end
                end
            end

            -- Check for custom role override (highest priority)
            if override and (override == AB_const.TANK or override == AB_const.HEALER or override == AB_const.MDPS or override == AB_const.RDPS) then
                role = override
                role_source = "role override"
            end

            player.role = role
            player.role_source = role_source
            table.insert(self.group[gid], player)
            self.player_count = self.player_count + 1
        end
    end
    self.MAX_GROUPS = AB_const.MAX_WB_GROUPS
    if type(self.roster_signature) ~= "string" then
        self.roster_signature = build_name_signature(roster_names)
    end
    self:recalc_counters()
end

-- Returns player.careerLine adjusted for alt-spec information when available.
function AB_wb.getArcheType(_self, player, alt_lookup)
    local name_str = tostring(player.name)
    if alt_lookup and alt_lookup[name_str] then
        return get_alt_spec_transformed_career(player.careerLine)
    end

    if alt_lookup == nil then
        if not RoRGroupScoreboard or not RoRGroupScoreboard.playersDataRaw then
            return player.careerLine
        end
        for _, p in pairs(RoRGroupScoreboard.playersDataRaw) do
            if p.name == towstring(player.name) and p.archtype > 0 then
                return get_alt_spec_transformed_career(player.careerLine)
            end
        end
    end

    return player.careerLine
end

function AB_wb.sync_role_notifications(_self, wb_obj)
    roles_last = roles_last or {}
    local print_enabled = AutoBand.saved.printrole_enabled and not AutoBand.suppressRoleNotifs
    AutoBand.role_tick = (AutoBand.role_tick or 0) + 1
    local tick = AutoBand.role_tick
    local backfill_route_lookup = nil
    if print_enabled then
        local can_show_backfill_route = false
        if AutoBand and AutoBand.is_wb_leader then
            local ok_lead, is_lead = pcall(AutoBand.is_wb_leader)
            if ok_lead and is_lead then
                can_show_backfill_route = true
            end
        end

        if can_show_backfill_route and AutoBand and AutoBand.get_backfill_route_lookup then
            local ok_route, route_lookup = pcall(AutoBand.get_backfill_route_lookup, wb_obj)
            if ok_route and type(route_lookup) == "table" then
                backfill_route_lookup = route_lookup
            end
        end
    end

    wb_obj:foreach_player(function(_gid, player)
        local name = tostring(player.name)
        local new_role = tostring(player.role)
        local role_source = player.role_source or "archetype"
        local entry = roles_last[name]
        local prev_role = entry and ((type(entry) == "table" and entry.role) or entry)
        local arrival_index = nil
        local arrival_total = nil

        if print_enabled then
            local icon = AB_const.ICONS[new_role] or ""
            local name_with_level = format_name_with_level(name, player.level, player.careerLine)
            local arrival_tag, tracked_arrival_index, tracked_arrival_total = get_arrival_tag_for_name(name)
            local backfill_tag = get_backfill_route_tag_for_name(name, backfill_route_lookup)
            local source_chunk = color_parenthetical("(via " .. role_source .. ")")
            if not prev_role then
                AB_util.print(name_with_level .. arrival_tag .. backfill_tag .. " assigned role " .. icon .. " " .. new_role .. " " .. source_chunk .. ".")
            elseif prev_role ~= new_role then
                local prev_icon = AB_const.ICONS[prev_role] or ""
                AB_util.print(name_with_level .. arrival_tag .. " reassigned role from " .. prev_icon .. " " .. prev_role .. " to " .. icon .. " " .. new_role .. " " .. source_chunk .. ".")
            end
            arrival_index = tracked_arrival_index
            arrival_total = tracked_arrival_total
        end

        if not entry or type(entry) ~= "table" then
            entry = {}
        end
        entry.role = new_role
        entry.level = player.level
        entry.career = player.careerLine
        entry.role_source = role_source
        if arrival_index then
            entry.arrival_index = arrival_index
            entry.arrival_total = arrival_total
        end
        entry.seen = tick
        roles_last[name] = entry
    end)

    local leavers = {}
    for name, entry in pairs(roles_last) do
        if entry.seen ~= tick then
            table.insert(leavers, name)
        end
    end

    if #leavers > 0 then
        if print_enabled then
            if #leavers <= MAX_DETAILED_LEAVERS then
                for _, name in ipairs(leavers) do
                    local entry = roles_last[name]
                    local role = entry and ((type(entry) == "table" and entry.role) or entry)
                    local icon = AB_const.ICONS[role] or ""
                    local level = entry and entry.level or nil
                    local career_line = entry and entry.career or nil
                    local name_with_level = format_name_with_level(name, level, career_line)
                    local role_desc = role or ""
                    local arrival_tag = format_arrival_tag_from_entry(entry)
                    if icon and icon ~= "" then
                        local colored_open = color_parenthetical("(")
                        local colored_close = color_parenthetical(" " .. role_desc .. ")")
                        AB_util.print(name_with_level .. arrival_tag .. " " .. colored_open .. icon .. colored_close .. " left.")
                    else
                        AB_util.print(name_with_level .. arrival_tag .. " " .. color_parenthetical("(" .. role_desc .. ")") .. " left.")
                    end
                end
            else
                AB_util.print(#leavers .. " assigned roles cleared from the warband roster.")
            end
        end

        for _, name in ipairs(leavers) do
            roles_last[name] = nil
        end
    end
end

-- iterates over every player in data calling "f(group id, player object, player position)"
function AB_wb:foreach_player(func)
    for i, grp in ipairs(self.group) do
        for j, player in ipairs(grp) do
            func(i, player, j)
        end
    end
end

-- Recompute cached group counters after roster mutations.
function AB_wb:recalc_counters()
    self.group_count = math.ceil(self.player_count / AB_const.GROUP_SIZE)        -- total number of groups
    self.fullgroup_count = math.floor(self.player_count / AB_const.GROUP_SIZE)    -- full groups
    self.remainder = self.player_count % AB_const.GROUP_SIZE            -- last group size
    if (self.remainder > math.floor(AB_const.GROUP_SIZE / 2)) then
        self.fullgroup_count = self.fullgroup_count + 1
        self.remainder = 0
    end
end

-- Debug helper: print current counters and roster entries.
function AB_wb:print()
    AB_util.print("groups: " .. self.group_count)
    AB_util.print("full groups: " .. self.fullgroup_count)
    AB_util.print("remainder group size: " .. self.remainder)
    self:foreach_player(
        function (gid, player, _pid)
            AB_util.print("gid " .. gid .. " " .. tostring(player.name) .. " " .. player.role)
        end
    )
end
