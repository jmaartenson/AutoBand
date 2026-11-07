-- AB_wbleaders.lua
-- WB leader discovery from the full open-warband list, current map pins, and manual entries.

AutoBand.WBLeaders = AutoBand.WBLeaders or {}
local WBLeaders = AutoBand.WBLeaders

WBLeaders.command_help = "list/add/remove/clear/min/notify/debug known WB leaders from full open list + current map pins"
WBLeaders.command_print_id = 82.3
WBLeaders.map_point_limit = 511
WBLeaders.zone_color = "210,180,140"
WBLeaders.open_source_label = "openwb"
WBLeaders.map_source_label = "map"
WBLeaders.manual_source_label = "manual"
WBLeaders.default_min_members = 6
WBLeaders.min_members_floor = 1
WBLeaders.min_members_ceiling = 24
WBLeaders.notify_remove_missing_cycles = 3
WBLeaders.notify_swap_member_delta = 4
WBLeaders.default_crown_icon = "<icon41007>"
WBLeaders.crown_icon_min = 41000
WBLeaders.crown_icon_max = 41009
WBLeaders.map_crown_icon_to_chat_icon = {
    [1850] = 41001, -- CrownDarkBlue
    [1851] = 41009, -- CrownDarkPurple
    [1852] = 41008, -- CrownDarkGreen
    [1853] = 41007, -- CrownLightGreen
    [1854] = 41005, -- CrownLightBlue
    [1855] = 41004, -- CrownLightGold
    [1856] = 41003, -- CrownPink
    [1857] = 41002, -- CrownRed
    [1858] = 41000  -- CrownDarkGold
}
WBLeaders.crown_icon_color = {
    ["<icon41000>"] = AB_const.COLOR_DARK_GOLD,
    ["<icon41001>"] = AB_const.COLOR_DARK_BLUE,
    ["<icon41002>"] = AB_const.COLOR_RED,
    ["<icon41003>"] = AB_const.COLOR_PINK,
    ["<icon41004>"] = AB_const.COLOR_GOLD,
    ["<icon41005>"] = AB_const.COLOR_SKY,
    ["<icon41006>"] = AB_const.COLOR_SILVER,
    ["<icon41007>"] = AB_const.COLOR_LIME,
    ["<icon41008>"] = AB_const.COLOR_DARK_GREEN,
    ["<icon41009>"] = AB_const.COLOR_PURPLE
}

local MAP_DISPLAYS = {
    "EA_Window_WorldMapZoneViewMapDisplay",
    "EA_Window_OverheadMapMapDisplay"
}

local function to_plain_string(value)
    if value == nil then
        return nil
    end

    local fixed = value
    if AutoBand and type(AutoBand.FixString) == "function" then
        local ok_fix, fixed_value = pcall(AutoBand.FixString, value)
        if ok_fix and fixed_value ~= nil then
            fixed = fixed_value
        end
    end

    if type(fixed) ~= "string" and type(WStringToString) == "function" then
        local ok_ws, ws_value = pcall(WStringToString, fixed)
        if ok_ws and ws_value ~= nil then
            fixed = ws_value
        end
    end

    local ok_str, str_value = pcall(tostring, fixed)
    if not ok_str or str_value == nil then
        return nil
    end
    return str_value
end

local function trim_ascii(text)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil
    end
    return text
end

local function normalize_name(name_raw)
    if AutoBand and type(AutoBand.normalize_wb_player_name) == "function" then
        local key, display = AutoBand.normalize_wb_player_name(name_raw)
        if key and display then
            return key, display
        end
    end

    local name_s = trim_ascii(to_plain_string(name_raw))
    if not name_s then
        return nil, nil
    end
    local ok_lower, name_key = pcall(string.lower, name_s)
    if not ok_lower or not name_key or name_key == "" then
        return nil, nil
    end
    return name_key, name_s
end

local function wbleader_features_enabled()
    if AutoBand and type(AutoBand.is_warband_enabled) == "function" then
        return AutoBand.is_warband_enabled() == true
    end
    return true
end

local function parse_warband_pin_name(name_raw)
    local name_s = trim_ascii(to_plain_string(name_raw))
    if not name_s then
        return nil, nil
    end

    -- CP-1252 right single quote can appear in client strings; normalize it to
    -- the ASCII apostrophe used by the map pin examples.
    name_s = string.gsub(name_s, "\146", "'")

    local lower = string.lower(name_s)
    local suffix = "'s warband"
    if string.sub(lower, -#suffix) ~= suffix then
        return nil, nil
    end

    local leader_name = trim_ascii(string.sub(name_s, 1, #name_s - #suffix))
    if not leader_name then
        return nil, nil
    end
    return normalize_name(leader_name)
end

local function color_text(text, color_s)
    return string.format(
        "<LINK data=\"0\" color=\"%s\" text=\"%s\">",
        tostring(color_s or "255,255,255"),
        tostring(text or "")
    )
end

local function rgb_components(rgb, fallback)
    if type(rgb) ~= "table" then
        rgb = fallback
    end
    if type(rgb) ~= "table" then
        rgb = AB_const.COLOR_WHITE or { 255, 255, 255 }
    end
    return rgb[1] or 255, rgb[2] or 255, rgb[3] or 255
end

local function muted_text(text)
    local r, g, b = rgb_components(AB_const.COLOR_SILVER, { 192, 192, 192 })
    return string.format(
        "<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">",
        r, g, b, tostring(text or "")
    )
end

local function crown_color_for_icon(crown_icon)
    local icon = trim_ascii(to_plain_string(crown_icon)) or WBLeaders.default_crown_icon
    return WBLeaders.crown_icon_color[icon] or
           WBLeaders.crown_icon_color[WBLeaders.default_crown_icon] or
           AB_const.COLOR_WHITE
end

local function player_link_text(name, rgb)
    local name_s = tostring(name or "")
    if name_s == "" then
        return ""
    end

    local r, g, b = rgb_components(rgb, AB_const.COLOR_WHITE)
    local link_name = string.gsub(name_s, "\"", "'")
    local display_name = "@" .. link_name

    return string.format(
        "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
        link_name, r, g, b, display_name
    )
end

local function known_zone_label(zone_id)
    local zid = tonumber(zone_id)
    if not zid or zid == 0 then
        return nil
    end

    local zone_name = nil
    if AB_util and type(AB_util.get_zone_name_sanitized) == "function" then
        local ok_zone, resolved = pcall(AB_util.get_zone_name_sanitized, zid)
        if ok_zone and resolved and resolved ~= "" then
            zone_name = resolved
        end
    end

    if not zone_name and type(GetZoneName) == "function" then
        local ok_engine, engine_zone = pcall(GetZoneName, zid)
        if ok_engine and engine_zone then
            zone_name = trim_ascii(to_plain_string(engine_zone))
        end
    end

    if not zone_name or zone_name == "" then
        return nil
    end

    local lower = string.lower(zone_name)
    if string.find(lower, "unknown", 1, true) or string.find(lower, "offline", 1, true) then
        return nil
    end
    return zone_name
end

local function colored_zone_label(zone_id)
    local zone_name = known_zone_label(zone_id)
    if not zone_name then
        return nil
    end
    return color_text(zone_name, WBLeaders.zone_color)
end

local function colored_map_campaign_label(zone_id)
    local label = nil
    if AB_util and type(AB_util.get_campaign_zone_scope_label) == "function" then
        label = AB_util.get_campaign_zone_scope_label(zone_id)
    end
    if not label then
        return colored_zone_label(zone_id), false
    end
    return color_text(label, WBLeaders.zone_color), true
end

local function normalized_positive_rank(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n <= 0 then
        return nil
    end
    return n
end

local function normalized_nonnegative_rank(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n < 0 then
        return nil
    end
    return n
end

local function normalized_min_members(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n < WBLeaders.min_members_floor or n > WBLeaders.min_members_ceiling then
        return nil
    end
    return n
end

local function current_player_cr()
    if not (GameData and type(GameData.Player) == "table") then
        return nil
    end
    local player = GameData.Player
    return normalized_positive_rank(player.level or player.careerRank or player.rank or player.m_level)
end

local function current_uptime_seconds()
    if type(GetGameTime) ~= "function" then
        return nil
    end
    local ok_time, uptime = pcall(GetGameTime)
    if not ok_time then
        return nil
    end
    return normalized_nonnegative_rank(uptime)
end

function WBLeaders.GetMinMembers()
    if AutoBand and AutoBand.saved then
        local saved_min = normalized_min_members(AutoBand.saved.wbleader_min_members)
        if saved_min then
            return saved_min
        end
    end
    return WBLeaders.default_min_members
end

function WBLeaders.SetMinMembers(value)
    local min_members = normalized_min_members(value)
    if not min_members then
        return false, "usage: /ab wblead min <1-24|reset>"
    end
    AutoBand.saved = AutoBand.saved or {}
    if normalized_min_members(AutoBand.saved.wbleader_min_members) ~= min_members then
        WBLeaders.tracked_open_leader_by_key = {}
    end
    AutoBand.saved.wbleader_min_members = min_members
    return true, min_members
end

local function ensure_tracked_open_leaders()
    if type(WBLeaders.tracked_open_leader_by_key) ~= "table" then
        WBLeaders.tracked_open_leader_by_key = {}
    end
    return WBLeaders.tracked_open_leader_by_key
end

local function mark_tracked_open_leader(key)
    if key and key ~= "" then
        ensure_tracked_open_leaders()[key] = true
    end
end

local function is_tracked_open_leader(key)
    return key and ensure_tracked_open_leaders()[key] == true
end

local function row_leader_cr(row)
    if type(row) ~= "table" then
        return nil
    end

    local direct = normalized_positive_rank(row.leaderLevel or row.leaderRank or row.level or row.rank or row.m_level)
    if direct then
        return direct
    end

    local leader_key = normalize_name(row.leaderName or row.name)
    if not leader_key or type(row.Group) ~= "table" then
        return nil
    end

    for i = 1, #row.Group do
        local member = row.Group[i]
        if type(member) == "table" then
            local member_key = normalize_name(member.m_memberName or member.name)
            if member_key and member_key == leader_key then
                return normalized_positive_rank(member.m_level or member.level or member.rank)
            end
        end
    end
    return nil
end

local function normalized_career_line(value)
    local n = tonumber(value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n <= 0 then
        return nil
    end
    return n
end

local function row_leader_career_line(row)
    if type(row) ~= "table" then
        return nil
    end

    local direct = normalized_career_line(row.leaderCareer or row.leaderCareerLine or row.careerLine or row.career)
    if direct then
        return direct
    end

    local leader_key = normalize_name(row.leaderName or row.name)
    if not leader_key or type(row.Group) ~= "table" then
        return nil
    end

    for i = 1, #row.Group do
        local member = row.Group[i]
        if type(member) == "table" then
            local member_key = normalize_name(member.m_memberName or member.name)
            if member_key and member_key == leader_key then
                return normalized_career_line(member.m_careerLine or member.careerLine or member.career)
            end
        end
    end
    return nil
end

local function row_group_contains_key(row, wanted_key)
    if not wanted_key or type(row) ~= "table" or type(row.Group) ~= "table" then
        return false
    end

    for i = 1, #row.Group do
        local member = row.Group[i]
        if type(member) == "table" then
            local member_key = normalize_name(member.m_memberName or member.name)
            if member_key and member_key == wanted_key then
                return true
            end
        end
    end
    return false
end

local function row_group_contains_leader(row)
    local leader_key = type(row) == "table" and normalize_name(row.leaderName or row.name) or nil
    return row_group_contains_key(row, leader_key)
end

local function career_icon_for_line(career_line)
    if career_line and AB_const and type(AB_const.CAREERLINE_ICON_MAP) == "table" then
        return AB_const.CAREERLINE_ICON_MAP[career_line]
    end
    return nil
end

local function current_world_map_zone()
    if type(EA_Window_WorldMap) ~= "table" then
        return nil
    end
    if GameDefs and GameDefs.MapLevel and EA_Window_WorldMap.currentLevel ~= nil and
       EA_Window_WorldMap.currentLevel ~= GameDefs.MapLevel.ZONE_MAP then
        return nil
    end
    return tonumber(EA_Window_WorldMap.currentMap)
end

local function display_exists(display)
    if type(DoesWindowExist) ~= "function" then
        return true
    end
    local ok_exists, exists = pcall(DoesWindowExist, display)
    return ok_exists == true and exists == true
end

local function point_zone_id(display, point)
    local zone_id = nil
    if type(point) == "table" then
        zone_id = tonumber(point.zone)
    end
    if not zone_id or zone_id == 0 then
        if display == "EA_Window_OverheadMapMapDisplay" and GameData and GameData.Player then
            zone_id = tonumber(GameData.Player.zone)
        elseif display == "EA_Window_WorldMapZoneViewMapDisplay" then
            zone_id = current_world_map_zone()
        end
    end
    return zone_id
end

local function point_position_text(point)
    if type(point) ~= "table" then
        return nil
    end

    local x = tonumber(point.x)
    local y = tonumber(point.y)
    if (not x or not y) and point.objPositionX ~= nil and point.objPositionY ~= nil then
        x = tonumber(point.objPositionX)
        y = tonumber(point.objPositionY)
    end
    if not x or not y then
        return nil
    end

    return tostring(math.floor(x + 0.5)) .. "," .. tostring(math.floor(y + 0.5))
end

local function crown_icon_tag_from_point(point)
    if type(point) ~= "table" then
        return nil
    end

    local icon_id = tonumber(point.mapIcon or point.icon or point.iconId or point.iconID or point.iconNum)
    if not icon_id then
        return nil
    end
    icon_id = math.floor(icon_id)
    if WBLeaders.map_crown_icon_to_chat_icon[icon_id] then
        icon_id = WBLeaders.map_crown_icon_to_chat_icon[icon_id]
    end
    if icon_id < WBLeaders.crown_icon_min or icon_id > WBLeaders.crown_icon_max then
        return nil
    end
    return "<icon" .. tostring(icon_id) .. ">"
end

local function add_unique(list, lookup, value)
    if value == nil or value == "" then
        return
    end
    if lookup[value] == true then
        return
    end
    lookup[value] = true
    list[#list + 1] = value
end

local function join_args(args, start_index)
    if type(args) ~= "table" then
        return nil
    end
    local parts = {}
    for i = start_index or 1, #args do
        if args[i] ~= nil then
            parts[#parts + 1] = tostring(args[i])
        end
    end
    return trim_ascii(table.concat(parts, " "))
end

local function ensure_manual_state()
    if type(WBLeaders.manual_entries) ~= "table" then
        WBLeaders.manual_entries = {}
    end
    if type(WBLeaders.manual_by_key) ~= "table" then
        WBLeaders.manual_by_key = {}
        for i = 1, #WBLeaders.manual_entries do
            local entry = WBLeaders.manual_entries[i]
            if type(entry) == "table" and entry.key then
                WBLeaders.manual_by_key[entry.key] = entry
            end
        end
    end
end

local function list_has_name(list, key, fields)
    if type(list) ~= "table" or not key then
        return false
    end
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            for f = 1, #fields do
                local row_key = normalize_name(row[fields[f]])
                if row_key and row_key == key then
                    return true
                end
            end
        end
    end
    return false
end

local function fetched_list_has_name(fetch_fn, key, fields)
    if type(fetch_fn) ~= "function" then
        return false
    end
    local ok_list, list = pcall(fetch_fn)
    if not ok_list then
        return false
    end
    return list_has_name(list, key, fields)
end

local function fetch_open_list(fetch_fn)
    if type(fetch_fn) ~= "function" then
        return nil
    end

    local ok_list, list = pcall(fetch_fn)
    if ok_list and type(list) == "table" then
        return list
    end
    return nil
end

local function open_list_has_name(key)
    local list = fetch_open_list(GetOpenPartyFullList)
    if type(list) ~= "table" then
        return false
    end

    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" then
            local leader_key = normalize_name(row.leaderName or row.name)
            if leader_key and leader_key == key then
                return true
            end
            if list_has_name(row.Group, key, { "m_memberName", "name" }) then
                return true
            end
        end
    end
    return false
end

local function map_pins_have_name(key)
    if type(GetMapPointData) ~= "function" or type(SystemData) ~= "table" or
       type(SystemData.MapPips) ~= "table" or SystemData.MapPips.IMPORTANT_MONSTER == nil then
        return false
    end

    local important_type = SystemData.MapPips.IMPORTANT_MONSTER
    for s = 1, #MAP_DISPLAYS do
        local display = MAP_DISPLAYS[s]
        if display_exists(display) then
            for i = 1, WBLeaders.map_point_limit do
                local ok_point, point = pcall(GetMapPointData, display, i)
                if ok_point and type(point) == "table" and tonumber(point.pointType) == important_type then
                    local point_key = parse_warband_pin_name(point.name)
                    if point_key and point_key == key then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function WBLeaders.VerifyPlayer(name_raw)
    local key, display_name = normalize_name(name_raw)
    if not key then
        return { confirmed = false, source = nil, name = display_name }
    end

    local last_results = WBLeaders.last_results
    if last_results and last_results.by_key and last_results.by_key[key] then
        return { confirmed = true, source = "current WB lead cache", name = display_name }
    end
    if open_list_has_name(key) then
        return { confirmed = true, source = "open-party cache", name = display_name }
    end
    if map_pins_have_name(key) then
        return { confirmed = true, source = "map pins", name = display_name }
    end
    if AutoBand and type(AutoBand.get_realm_rank_lookup_result) == "function" then
        local ok_lookup, lookup = pcall(AutoBand.get_realm_rank_lookup_result, display_name, {
            allow_cache_fallback = true,
            touch_cache = false
        })
        if ok_lookup and type(lookup) == "table" then
            return { confirmed = true, source = "RR lookup", name = display_name }
        end
    end
    if fetched_list_has_name(GetSearchList, key, { "name" }) then
        return { confirmed = true, source = "social search cache", name = display_name }
    end
    if fetched_list_has_name(GetFriendsList, key, { "name" }) then
        return { confirmed = true, source = "friends list", name = display_name }
    end
    if fetched_list_has_name(GetIgnoreList, key, { "name" }) then
        return { confirmed = true, source = "ignore list", name = display_name }
    end
    if fetched_list_has_name(GetGuildMemberData, key, { "name", "m_memberName" }) then
        return { confirmed = true, source = "guild roster", name = display_name }
    end

    return { confirmed = false, source = nil, name = display_name }
end

local function get_or_create_entry(results, key, display_name)
    local entry = results.by_key[key]
    if not entry then
        entry = {
            key = key,
            name = display_name,
            source_lookup = {},
            sources = {},
            detail_lookup = {},
            details = {},
            leader_cr = nil,
            leader_rr = nil,
            career_line = nil,
            career_icon = nil,
            crown_icon = nil,
            open_member_count = nil,
            open_location_detail = nil,
            open_location_kind = nil,
            first_source_order = results.next_order
        }
        results.next_order = results.next_order + 1
        results.by_key[key] = entry
        results.entries[#results.entries + 1] = entry
    elseif display_name and display_name ~= "" then
        entry.name = display_name
    end
    return entry
end

local function remove_entry(results, key)
    local entry = results.by_key[key]
    if not entry then
        return
    end
    results.by_key[key] = nil
    for i = #results.entries, 1, -1 do
        if results.entries[i] == entry then
            table.remove(results.entries, i)
            break
        end
    end
end

local function merge_entry_cr(entry, value)
    local cr = normalized_positive_rank(value)
    if cr and entry.leader_cr == nil then
        entry.leader_cr = cr
    end
end

local function merge_entry_rr(entry, value)
    local rr = normalized_nonnegative_rank(value)
    if rr and entry.leader_rr == nil then
        entry.leader_rr = rr
    end
end

local function merge_entry_crown(entry, crown_icon)
    local icon = trim_ascii(to_plain_string(crown_icon))
    if icon and entry.crown_icon == nil then
        entry.crown_icon = icon
    end
end

local function merge_entry_career(entry, career_line, career_icon)
    local line = normalized_career_line(career_line)
    if line and entry.career_line == nil then
        entry.career_line = line
    end

    local icon = trim_ascii(to_plain_string(career_icon))
    if not icon and line then
        icon = career_icon_for_line(line)
    end
    if not icon and entry.career_line then
        icon = career_icon_for_line(entry.career_line)
    end
    if icon and entry.career_icon == nil then
        entry.career_icon = icon
    end
end

local function enrich_entry_from_open_row(entry, row, leader_cr, below_min)
    merge_entry_cr(entry, leader_cr)
    merge_entry_career(entry, row_leader_career_line(row), nil)
    local count = tonumber(row and row.numGroupMembers)
    if count then
        entry.open_member_count = math.floor(count)
    end
    entry.open_below_min = below_min == true
end

local function enrich_entry_from_realmrank(entry)
    if not (entry and entry.name and AutoBand and type(AutoBand.get_realm_rank_lookup_result) == "function") then
        return
    end

    local ok_lookup, lookup = pcall(AutoBand.get_realm_rank_lookup_result, entry.name, {
        allow_cache_fallback = true,
        touch_cache = false
    })
    if not ok_lookup or type(lookup) ~= "table" then
        return
    end

    merge_entry_rr(entry, lookup.rr)
    merge_entry_cr(entry, lookup.level)
    merge_entry_career(entry, lookup.career_line, lookup.career_icon)
    if (not entry.name or entry.name == "") and lookup.display_name then
        entry.name = lookup.display_name
    end
end

local function enrich_entries_from_realmrank(results)
    for i = 1, #(results.entries or {}) do
        enrich_entry_from_realmrank(results.entries[i])
    end
end

local function remove_low_cr_enriched_entries(results)
    if results.low_cr_filter_enabled ~= true then
        return
    end

    for i = #(results.entries or {}), 1, -1 do
        local entry = results.entries[i]
        if entry and entry.key and entry.leader_cr ~= nil and entry.leader_cr < 16 then
            results.low_cr_filtered_lookup[entry.key] = true
            results.by_key[entry.key] = nil
            table.remove(results.entries, i)
            results.low_cr_filtered = results.low_cr_filtered + 1
        end
    end
end

local function entry_add_source(entry, source)
    add_unique(entry.sources, entry.source_lookup, source)
end

local function entry_add_detail(entry, source, detail)
    entry_add_source(entry, source)
    add_unique(entry.details, entry.detail_lookup, detail)
end

local function entry_remove_detail(entry, detail)
    if not (type(entry) == "table" and detail and detail ~= "") then
        return
    end
    if type(entry.detail_lookup) == "table" then
        entry.detail_lookup[detail] = nil
    end
    if type(entry.details) ~= "table" then
        return
    end
    for i = #entry.details, 1, -1 do
        if entry.details[i] == detail then
            table.remove(entry.details, i)
            return
        end
    end
end

local function entry_set_location_detail(entry, detail, kind)
    if not (type(entry) == "table" and detail and detail ~= "") then
        return false
    end
    if entry.open_location_detail and entry.open_location_detail ~= detail then
        entry_remove_detail(entry, entry.open_location_detail)
    end
    entry.open_location_detail = detail
    entry.open_location_kind = kind
    add_unique(entry.details, entry.detail_lookup, detail)
    return true
end

local function build_open_location_detail(row)
    if not row_group_contains_leader(row) then
        return nil, nil
    end

    local zone_text = colored_zone_label(row and row.leaderZone)
    if zone_text then
        return zone_text, "leaderZone"
    end

    -- Nearby pvpAreaName is objective text and can repeat another warband's area.
    return nil, nil
end

local function add_open_details(entry, source, row)
    entry_add_source(entry, source)

    local count = tonumber(row and row.numGroupMembers)
    if count then
        add_unique(entry.details, entry.detail_lookup, tostring(math.floor(count)) .. "/24")
    end

    local location_detail, location_kind = build_open_location_detail(row)
    if location_detail then
        entry_set_location_detail(entry, location_detail, location_kind)
    end

    if row and row.isOpen == false then
        add_unique(entry.details, entry.detail_lookup, "listed-closed")
    end
end

local function build_map_only_detail(display, point)
    local parts = {}
    local zone_text, is_broad_scope = colored_map_campaign_label(point_zone_id(display, point))
    if zone_text then
        parts[#parts + 1] = zone_text
    end

    local pos_text = nil
    if is_broad_scope ~= true then
        pos_text = point_position_text(point)
    end
    if pos_text then
        parts[#parts + 1] = "pos " .. pos_text
    end
    return table.concat(parts, " ")
end

local function combo_map_zone_id(display, point)
    local zone_id = nil
    if type(point) == "table" then
        zone_id = tonumber(point.zone)
    end
    if zone_id and zone_id ~= 0 then
        return zone_id
    end

    if display == "EA_Window_OverheadMapMapDisplay" and GameData and GameData.Player then
        zone_id = tonumber(GameData.Player.zone)
        if zone_id and zone_id ~= 0 then
            return zone_id
        end
    end
    return nil
end

local function build_combo_map_location_detail(display, point)
    return colored_zone_label(combo_map_zone_id(display, point))
end

local function is_warband_listing(entry, min_members)
    if type(entry) ~= "table" then
        return false, false
    end
    local count = tonumber(entry.numGroupMembers)
    if count then
        count = math.floor(count)
    end
    if count and count < min_members then
        return false, true
    end
    if entry.isWarband == true then
        return true, false
    end
    return entry.isWarband == nil and count ~= nil and count >= min_members, false
end

local function should_filter_low_cr(results, key, leader_cr)
    if key and results.low_cr_filter_enabled == true and leader_cr ~= nil and leader_cr < 16 then
        results.low_cr_filtered_lookup[key] = true
        remove_entry(results, key)
        results.low_cr_filtered = results.low_cr_filtered + 1
        return true
    end
    return false
end

local function request_open_party_refresh()
    if type(SendOpenPartySearchRequest) ~= "function" then
        return false, "SendOpenPartySearchRequest unavailable"
    end
    if not (GameData and GameData.OpenPartyRequestType) then
        return false, "GameData.OpenPartyRequestType unavailable"
    end

    local request_type = GameData.OpenPartyRequestType.ALL
    if request_type == nil then
        return false, "GameData.OpenPartyRequestType.ALL unavailable"
    end

    local ok_request = pcall(SendOpenPartySearchRequest, request_type)
    if not ok_request then
        return false, "SendOpenPartySearchRequest failed"
    end
    return true, "requested"
end

local function collect_open_list(results, list, source)
    if type(list) ~= "table" then
        return
    end

    for i = 1, #list do
        local row = list[i]
        local key, display_name = normalize_name(row and (row.leaderName or row.name))
        local is_listing, filtered_by_min = is_warband_listing(row, results.min_open_members)
        if key and (is_listing or filtered_by_min) then
            results.open_seen_lookup[key] = true
        end
        if is_listing or (filtered_by_min and is_tracked_open_leader(key)) then
            if key then
                local leader_cr = row_leader_cr(row)
                if not should_filter_low_cr(results, key, leader_cr) then
                    local tracked_below_min = filtered_by_min and not is_listing
                    local entry = get_or_create_entry(results, key, display_name)
                    if is_listing then
                        mark_tracked_open_leader(key)
                    elseif tracked_below_min then
                        results.open_tracked_below_min = results.open_tracked_below_min + 1
                    end
                    enrich_entry_from_open_row(entry, row, leader_cr, tracked_below_min)
                    add_open_details(entry, source, row)
                    results.open_matches = results.open_matches + 1
                end
            end
        elseif filtered_by_min then
            results.open_min_filtered = results.open_min_filtered + 1
        end
    end
end

local function collect_open_lists(results, include_world)
    collect_open_list(results, fetch_open_list(GetOpenPartyFullList), WBLeaders.open_source_label)
    if include_world == false then
        return
    end
    -- Join by leader identity, never by the independently ordered list indices.
    for _, row in ipairs(fetch_open_list(GetOpenPartyWorldList) or {}) do
        local key = type(row) == "table" and normalize_name(row.leaderName or row.name)
        local entry = key and results.by_key[key]
        if entry then
            local detail, kind = build_open_location_detail(row)
            if detail then
                entry_set_location_detail(entry, detail, kind)
            end
        end
    end
end

local function debug_value(value)
    local text = trim_ascii(to_plain_string(value))
    if not text then
        return "-"
    end
    text = string.gsub(text, "<", "(")
    text = string.gsub(text, ">", ")")
    return text
end

local function debug_bool(value)
    if value == true then
        return "true"
    end
    if value == false then
        return "false"
    end
    return "-"
end

local function debug_zone_value(zone_id)
    local zid = tonumber(zone_id)
    if not zid or zid == 0 then
        return "-"
    end
    local label = known_zone_label(zid) or "?"
    return tostring(math.floor(zid)) .. "/" .. tostring(label)
end

local function debug_member_text(member, index)
    if type(member) ~= "table" then
        return tostring(index) .. ":<bad>"
    end

    local text = tostring(index) .. ":" .. debug_value(member.m_memberName or member.name)
    local cr = normalized_positive_rank(member.m_level or member.level or member.rank)
    if cr then
        text = text .. " CR" .. tostring(cr)
    end
    local career_line = normalized_career_line(member.m_careerLine or member.careerLine or member.career)
    if career_line then
        text = text .. " CL" .. tostring(career_line)
    end
    return text
end

local function print_debug_group(row)
    if type(row) ~= "table" or type(row.Group) ~= "table" then
        AB_util.print("    group: -")
        return
    end

    local chunk = {}
    for i = 1, #row.Group do
        chunk[#chunk + 1] = debug_member_text(row.Group[i], i)
        if #chunk >= 4 then
            AB_util.print("    group: " .. table.concat(chunk, "; "))
            chunk = {}
        end
    end
    if #chunk > 0 then
        AB_util.print("    group: " .. table.concat(chunk, "; "))
    elseif #row.Group == 0 then
        AB_util.print("    group: empty")
    end
end

local function debug_display_name(display)
    if display == "EA_Window_WorldMapZoneViewMapDisplay" then
        return "world"
    end
    if display == "EA_Window_OverheadMapMapDisplay" then
        return "overhead"
    end
    return display
end

local function debug_map_icon_value(point)
    if type(point) ~= "table" then
        return "-"
    end
    return debug_value(point.mapIcon or point.icon or point.iconId or point.iconID or point.iconNum)
end

local function print_debug_map_scan(target_key, debug_all)
    if type(GetMapPointData) ~= "function" or type(SystemData) ~= "table" or
       type(SystemData.MapPips) ~= "table" or SystemData.MapPips.IMPORTANT_MONSTER == nil then
        AB_util.print("  mapscan: unavailable.")
        return
    end

    local important_type = SystemData.MapPips.IMPORTANT_MONSTER
    local matches = 0
    for display_index = 1, #MAP_DISPLAYS do
        local display = MAP_DISPLAYS[display_index]
        if display_exists(display) then
            for i = 1, WBLeaders.map_point_limit do
                local ok_point, point = pcall(GetMapPointData, display, i)
                if ok_point and type(point) == "table" and tonumber(point.pointType) == important_type then
                    local key, display_name = parse_warband_pin_name(point.name)
                    if key and (debug_all or key == target_key) then
                        matches = matches + 1
                        local zone_id = point_zone_id(display, point)
                        AB_util.print(
                            "  mapscan " .. tostring(matches) ..
                            ": display=" .. debug_value(debug_display_name(display)) ..
                            " index=" .. tostring(i) ..
                            " leader=" .. debug_value(display_name) ..
                            " rawName=" .. debug_value(point.name)
                        )
                        AB_util.print(
                            "    pin: pointType=" .. debug_value(point.pointType) ..
                            " mapIcon=" .. debug_map_icon_value(point) ..
                            " crown=" .. debug_value(crown_icon_tag_from_point(point)) ..
                            " zone=" .. debug_zone_value(zone_id) ..
                            " pos=" .. debug_value(point_position_text(point))
                        )
                        AB_util.print(
                            "    detail: mapOnly=" .. debug_value(build_map_only_detail(display, point)) ..
                            " comboIfOpenwb=" .. debug_value(build_combo_map_location_detail(display, point))
                        )
                    end
                end
            end
        end
    end

    if matches == 0 then
        AB_util.print("  no matching map pins.")
    end
end

function WBLeaders.DebugOpenList(name_raw)
    local target_text = trim_ascii(to_plain_string(name_raw))
    local debug_all = target_text and string.lower(target_text) == "all"
    local target_key, target_display = nil, nil
    if not debug_all then
        target_key, target_display = normalize_name(target_text)
        if not target_key then
            return false, "usage: /ab wblead debug <leader|all>"
        end
    end

    local refresh_requested, refresh_status = request_open_party_refresh()
    local list = fetch_open_list(GetOpenPartyFullList)
    local row_count = type(list) == "table" and #list or 0
    AB_util.print(
        "wblead debug target=" .. tostring(debug_all and "all" or target_display) ..
        " rows=" .. tostring(row_count) ..
        " refresh=" .. tostring(refresh_status or refresh_requested)
    )
    AB_util.print("  using current cached GetOpenPartyFullList; rerun after the open-party list refreshes if needed.")

    local list_valid = type(list) == "table"
    if not list_valid then
        AB_util.print("  GetOpenPartyFullList unavailable or invalid.")
        print_debug_map_scan(target_key, debug_all)
    else
        local matches = 0
        for i = 1, #list do
            local row = list[i]
            if type(row) == "table" then
                local leader_key, leader_display = normalize_name(row.leaderName or row.name)
                local leader_match = debug_all or (target_key and leader_key == target_key)
                local member_match = (not debug_all) and row_group_contains_key(row, target_key)
                if leader_match or member_match then
                    matches = matches + 1
                    local match_text = "leader"
                    if leader_match and member_match then
                        match_text = "leader+member"
                    elseif member_match then
                        match_text = "member"
                    elseif debug_all then
                        match_text = "all"
                    end

                    local group_count = type(row.Group) == "table" and #row.Group or 0
                    AB_util.print(
                        "  row " .. tostring(i) ..
                        " match=" .. match_text ..
                        " leader=" .. debug_value(leader_display or row.leaderName or row.name) ..
                        " count=" .. debug_value(row.numGroupMembers) ..
                        " groupRows=" .. tostring(group_count) ..
                        " leaderInGroup=" .. debug_bool(row_group_contains_leader(row))
                    )
                    AB_util.print(
                        "    flags: isWarband=" .. debug_bool(row.isWarband) ..
                        " isOpen=" .. debug_bool(row.isOpen) ..
                        " leaderLevel=" .. debug_value(row.leaderLevel or row.leaderRank or row.level or row.rank) ..
                        " leaderCareer=" .. debug_value(row.leaderCareer or row.leaderCareerLine or row.careerLine or row.career)
                    )
                    AB_util.print(
                        "    loc: leaderZone=" .. debug_zone_value(row.leaderZone) ..
                        " pvpAreaName=" .. debug_value(row.pvpAreaName) ..
                        " influenceID=" .. debug_value(row.influenceID) ..
                        " objectiveName=" .. debug_value(row.objectiveName)
                    )
                    print_debug_group(row)
                end
            end
        end

        if matches == 0 then
            AB_util.print("  no matching open-list rows.")
        end
        print_debug_map_scan(target_key, debug_all)
    end
    AB_util.print("  merged /ab wbleads output:")
    WBLeaders.PrintResults(WBLeaders.Collect({ request_open_party = false }))
    return true
end

local function collect_map_display(results, display)
    if type(GetMapPointData) ~= "function" or type(SystemData) ~= "table" or
       type(SystemData.MapPips) ~= "table" or SystemData.MapPips.IMPORTANT_MONSTER == nil then
        return
    end
    if not display_exists(display) then
        return
    end

    local important_type = SystemData.MapPips.IMPORTANT_MONSTER
    for i = 1, WBLeaders.map_point_limit do
        local ok_point, point = pcall(GetMapPointData, display, i)
        if ok_point and type(point) == "table" then
            local point_type = tonumber(point.pointType)
            if point_type == important_type then
                local key, display_name = parse_warband_pin_name(point.name)
                if key and results.low_cr_filtered_lookup[key] ~= true then
                    local entry = results.by_key[key]
                    if entry or results.open_seen_lookup[key] ~= true then
                        entry = get_or_create_entry(results, key, display_name)
                        merge_entry_crown(entry, crown_icon_tag_from_point(point))
                        local open_source_wins =
                            entry.source_lookup and entry.source_lookup[WBLeaders.open_source_label] == true
                        local detail = build_map_only_detail(display, point)
                        if open_source_wins then
                            detail = nil
                            local combo_detail = build_combo_map_location_detail(display, point)
                            if combo_detail and entry.open_location_kind ~= "leaderZone" then
                                if entry_set_location_detail(entry, combo_detail, "mapCombo") then
                                    detail = combo_detail
                                end
                            end
                        end
                        entry_add_detail(
                            entry,
                            WBLeaders.map_source_label,
                            detail
                        )
                        results.map_matches = results.map_matches + 1
                    end
                end
            end
        end
    end
end

local function collect_map_pins(results)
    for i = 1, #MAP_DISPLAYS do
        collect_map_display(results, MAP_DISPLAYS[i])
    end
end

local function collect_manual_entries(results)
    ensure_manual_state()
    for i = 1, #WBLeaders.manual_entries do
        local manual = WBLeaders.manual_entries[i]
        if type(manual) == "table" and manual.key and results.low_cr_filtered_lookup[manual.key] ~= true then
            local entry = get_or_create_entry(results, manual.key, manual.name)
            entry_add_detail(entry, WBLeaders.manual_source_label, nil)
            results.manual_matches = results.manual_matches + 1
        end
    end
end

function WBLeaders.Collect(opts)
    opts = type(opts) == "table" and opts or {}
    local include_realmrank = opts.include_realmrank ~= false
    local results = {
        entries = {},
        by_key = {},
        next_order = 1,
        min_open_members = WBLeaders.GetMinMembers(),
        open_matches = 0,
        open_min_filtered = 0,
        map_matches = 0,
        manual_matches = 0,
        collected_uptime_s = nil,
        refresh_requested = false,
        refresh_status = nil,
        low_cr_filter_enabled = (current_player_cr() or 0) >= 16,
        low_cr_filtered = 0,
        low_cr_filtered_lookup = {},
        open_seen_lookup = {},
        open_tracked_below_min = 0
    }

    if opts.request_open_party ~= false then
        results.refresh_requested, results.refresh_status = request_open_party_refresh()
    end

    collect_open_lists(results, opts.include_world)
    collect_map_pins(results)
    collect_manual_entries(results)
    if include_realmrank then
        enrich_entries_from_realmrank(results)
        remove_low_cr_enriched_entries(results)
    end

    table.sort(results.entries, function(a, b)
        local an = string.lower(tostring(a.name or ""))
        local bn = string.lower(tostring(b.name or ""))
        if an == bn then
            return (a.first_source_order or 0) < (b.first_source_order or 0)
        end
        return an < bn
    end)

    results.collected_uptime_s = current_uptime_seconds()
    WBLeaders.last_results = results
    WBLeaders.last_entries = results.entries
    WBLeaders.last_by_key = results.by_key

    return results
end

function WBLeaders.GetLastResults()
    return WBLeaders.last_results
end

function WBLeaders.IsKnownLeader(name_raw)
    local key = normalize_name(name_raw)
    if not key then
        return false
    end

    ensure_manual_state()
    if WBLeaders.manual_by_key[key] then
        return true
    end

    local last_results = WBLeaders.last_results
    return type(last_results) == "table" and
        type(last_results.by_key) == "table" and
        last_results.by_key[key] ~= nil
end

function WBLeaders.GetNotifyConfigured()
    return AutoBand and AutoBand.saved and AutoBand.saved.wbleader_notify_enabled == true
end

function WBLeaders.GetNotifyEnabled()
    return wbleader_features_enabled() and WBLeaders.GetNotifyConfigured()
end

local function notify_status_text()
    local configured = WBLeaders.GetNotifyConfigured()
    if configured and not wbleader_features_enabled() then
        return "true (inactive while WB features are disabled)"
    end
    return tostring(configured)
end

local function ensure_notify_seen_keys()
    if type(WBLeaders.notify_user_seen_added_keys) ~= "table" then
        WBLeaders.notify_user_seen_added_keys = {}
    end
    return WBLeaders.notify_user_seen_added_keys
end

local function ensure_notify_missing_counts()
    if type(WBLeaders.notify_missing_counts_by_key) ~= "table" then
        WBLeaders.notify_missing_counts_by_key = {}
    end
    return WBLeaders.notify_missing_counts_by_key
end

function WBLeaders.SetNotifyEnabled(enabled)
    AutoBand.saved = AutoBand.saved or {}
    AutoBand.saved.wbleader_notify_enabled = enabled == true
    if AutoBand.saved.wbleader_notify_enabled then
        if wbleader_features_enabled() then
            WBLeaders.notify_baseline_results = WBLeaders.Collect({
                request_open_party = false,
                include_realmrank = true
            })
        else
            WBLeaders.notify_baseline_results = {}
        end
        WBLeaders.notify_user_seen_added_keys = {}
        WBLeaders.notify_missing_counts_by_key = {}
    end
    return AutoBand.saved.wbleader_notify_enabled
end

function WBLeaders.MarkUserSeenName(name_raw)
    local key = normalize_name(name_raw)
    if key then
        ensure_notify_seen_keys()[key] = true
        return true
    end
    return false
end

function WBLeaders.MarkUserSeenResults(results)
    WBLeaders.notify_baseline_results = results
    WBLeaders.notify_user_seen_added_keys = {}
    WBLeaders.notify_missing_counts_by_key = {}
end

function WBLeaders.AddManualLeader(name_raw)
    local key, display_name = normalize_name(name_raw)
    if not key then
        return false, "usage: /ab wblead add <name>"
    end

    ensure_manual_state()
    local verification = WBLeaders.VerifyPlayer(display_name)
    local manual = WBLeaders.manual_by_key[key]
    if manual then
        manual.name = display_name
        return true, display_name, false, verification
    end

    manual = {
        key = key,
        name = display_name
    }
    WBLeaders.manual_by_key[key] = manual
    WBLeaders.manual_entries[#WBLeaders.manual_entries + 1] = manual
    return true, display_name, true, verification
end

function WBLeaders.RemoveManualLeader(name_raw)
    local key, display_name = normalize_name(name_raw)
    if not key then
        return false, "usage: /ab wblead remove <name>"
    end

    ensure_manual_state()
    local manual = WBLeaders.manual_by_key[key]
    if not manual then
        return false, "Manual WB lead not found: " .. tostring(display_name)
    end

    WBLeaders.manual_by_key[key] = nil
    for i = #WBLeaders.manual_entries, 1, -1 do
        if WBLeaders.manual_entries[i] == manual or WBLeaders.manual_entries[i].key == key then
            table.remove(WBLeaders.manual_entries, i)
            break
        end
    end
    return true, manual.name or display_name
end

function WBLeaders.ClearManualLeaders()
    ensure_manual_state()
    local count = #WBLeaders.manual_entries
    WBLeaders.manual_entries = {}
    WBLeaders.manual_by_key = {}
    return count
end

local function formatted_leader_label(entry, opts)
    opts = type(opts) == "table" and opts or {}
    local crown_icon = entry.crown_icon or WBLeaders.default_crown_icon
    local name = player_link_text(entry.name or "unknown", crown_color_for_icon(crown_icon))
    local parts = {}

    if entry.leader_cr then
        parts[#parts + 1] = "CR " .. tostring(entry.leader_cr)
    end
    if entry.leader_rr then
        parts[#parts + 1] = "RR " .. tostring(entry.leader_rr)
    end

    local rank_text = nil
    if #parts > 0 then
        rank_text = muted_text("(" .. table.concat(parts, ", ") .. ")")
    end

    local label_parts = {}
    if not opts.omit_crown_icon then
        label_parts[#label_parts + 1] = crown_icon
    end
    if entry.career_icon then
        label_parts[#label_parts + 1] = entry.career_icon
    end
    label_parts[#label_parts + 1] = name
    if rank_text then
        label_parts[#label_parts + 1] = rank_text
    end
    return table.concat(label_parts, " ")
end

local function formatted_source_text(sources)
    if type(sources) ~= "table" or #sources == 0 then
        return muted_text("[unknown source]")
    end

    return muted_text("[" .. table.concat(sources, ", ") .. "]")
end

local function count_entries_with_source(entries, source)
    local count = 0
    for i = 1, #(entries or {}) do
        local entry = entries[i]
        if type(entry) == "table" and type(entry.source_lookup) == "table" and entry.source_lookup[source] then
            count = count + 1
        end
    end
    return count
end

local function entry_is_background_source(entry)
    local lookup = entry and entry.source_lookup
    return type(lookup) == "table" and
        (lookup[WBLeaders.open_source_label] == true or lookup[WBLeaders.map_source_label] == true)
end

local function entry_is_map_only_source(entry)
    local lookup = entry and entry.source_lookup
    return type(lookup) == "table" and
        lookup[WBLeaders.map_source_label] == true and
        lookup[WBLeaders.open_source_label] ~= true
end

local function entry_open_member_count(entry)
    local count = tonumber(entry and entry.open_member_count)
    if count then
        return math.floor(count)
    end
    return nil
end

local function entry_is_below_min_open(entry)
    return type(entry) == "table" and entry.open_below_min == true
end

local function collect_background_entries_by_key(results)
    local by_key = {}
    local order = {}
    local entries = type(results) == "table" and results.entries or nil
    for i = 1, #(entries or {}) do
        local entry = entries[i]
        if type(entry) == "table" and entry.key and entry_is_background_source(entry) then
            by_key[entry.key] = entry
            order[#order + 1] = entry.key
        end
    end
    return by_key, order
end

local function append_changed_entries(target, source_by_key, source_order, other_by_key, suppress_added_by_key)
    for i = 1, #(source_order or {}) do
        local key = source_order[i]
        if source_by_key[key] and not other_by_key[key] then
            if suppress_added_by_key and suppress_added_by_key[key] then
                suppress_added_by_key[key] = nil
            else
                target[#target + 1] = source_by_key[key]
            end
        end
    end
end

local function collect_possible_swap_pairs(added, removed)
    local swap_pairs = {}
    local added_swap_by_key = {}
    local removed_swap_by_key = {}
    local used_removed_by_key = {}
    for i = 1, #(added or {}) do
        local added_entry = added[i]
        local added_count = entry_open_member_count(added_entry)
        if added_entry and added_entry.key and added_count and not entry_is_below_min_open(added_entry) then
            local best_removed = nil
            local best_delta = nil
            for j = 1, #(removed or {}) do
                local removed_entry = removed[j]
                local removed_count = entry_open_member_count(removed_entry)
                if removed_entry and removed_entry.key and removed_entry.key ~= added_entry.key and
                    not used_removed_by_key[removed_entry.key] and removed_count and
                    not entry_is_below_min_open(removed_entry)
                then
                    local delta = math.abs(added_count - removed_count)
                    if delta <= WBLeaders.notify_swap_member_delta and (not best_delta or delta < best_delta) then
                        best_removed = removed_entry
                        best_delta = delta
                    end
                end
            end

            if best_removed and best_removed.key then
                used_removed_by_key[best_removed.key] = true
                added_swap_by_key[added_entry.key] = true
                removed_swap_by_key[best_removed.key] = true
                swap_pairs[#swap_pairs + 1] = {
                    removed = best_removed,
                    added = added_entry
                }
            end
        end
    end
    return swap_pairs, added_swap_by_key, removed_swap_by_key
end

function WBLeaders.NotifyBackgroundChanges(previous_results, current_results)
    if not WBLeaders.GetNotifyEnabled() then
        return false
    end
    local baseline_results = WBLeaders.notify_baseline_results or previous_results
    if type(baseline_results) ~= "table" or type(baseline_results.entries) ~= "table" then
        WBLeaders.notify_baseline_results = current_results
        WBLeaders.notify_missing_counts_by_key = {}
        return false
    end
    if type(current_results) ~= "table" or type(current_results.entries) ~= "table" then
        return false
    end

    local previous_by_key, previous_order = collect_background_entries_by_key(baseline_results)
    local current_by_key, current_order = collect_background_entries_by_key(current_results)
    local added = {}
    local removed = {}
    local suppress_added_by_key = ensure_notify_seen_keys()
    local missing_counts = ensure_notify_missing_counts()
    append_changed_entries(added, current_by_key, current_order, previous_by_key, suppress_added_by_key)

    local next_baseline_entries = {}
    local next_baseline_lookup = {}
    for i = 1, #current_order do
        local key = current_order[i]
        local entry = current_by_key[key]
        if entry then
            next_baseline_entries[#next_baseline_entries + 1] = entry
            next_baseline_lookup[key] = true
            missing_counts[key] = nil
        end
    end

    for i = 1, #previous_order do
        local key = previous_order[i]
        local entry = previous_by_key[key]
        if entry and not current_by_key[key] then
            if entry_is_map_only_source(entry) then
                local missing_count = (tonumber(missing_counts[key]) or 0) + 1
                if missing_count >= WBLeaders.notify_remove_missing_cycles then
                    removed[#removed + 1] = entry
                    missing_counts[key] = nil
                    suppress_added_by_key[key] = nil
                else
                    missing_counts[key] = missing_count
                    if not next_baseline_lookup[key] then
                        next_baseline_entries[#next_baseline_entries + 1] = entry
                        next_baseline_lookup[key] = true
                    end
                end
            else
                removed[#removed + 1] = entry
                missing_counts[key] = nil
                suppress_added_by_key[key] = nil
            end
        end
    end
    WBLeaders.notify_baseline_results = { entries = next_baseline_entries }
    if #added == 0 and #removed == 0 then
        return false
    end

    local swap_pairs, added_swap_by_key, removed_swap_by_key = collect_possible_swap_pairs(added, removed)

    local wbleads_tag = "[" .. muted_text("wbleads") .. "]"
    local function format_change_entry(entry, opts)
        if type(entry) == "table" and type(WBLeaders.FormatEntry) == "function" then
            return WBLeaders.FormatEntry(entry, opts)
        end
        return tostring(entry or "unknown")
    end

    local function print_entry_change(entry, verb, note)
        local suffix = "."
        if note and note ~= "" then
            suffix = " (" .. tostring(note) .. ")."
        end
        AB_util.print(wbleads_tag .. " " .. format_change_entry(entry, { omit_crown_icon = true }) .. " " .. verb .. suffix)
    end

    local function print_swap_pair(pair)
        AB_util.print(
            wbleads_tag .. " swap: " ..
            format_change_entry(pair and pair.removed, { omit_sources = true, omit_crown_icon = true }) .. " -> " ..
            format_change_entry(pair and pair.added, { omit_sources = true, omit_crown_icon = true }) .. "."
        )
    end

    for i = 1, #swap_pairs do
        print_swap_pair(swap_pairs[i])
    end

    for i = 1, #added do
        if not added_swap_by_key[added[i] and added[i].key] then
            print_entry_change(added[i], "listed as WB lead")
        end
    end
    for i = 1, #removed do
        local note = nil
        if entry_is_map_only_source(removed[i]) then
            note = "no longer on map"
        end
        if not removed_swap_by_key[removed[i] and removed[i].key] then
            print_entry_change(removed[i], "no longer listed as WB lead", note)
        end
    end
    return true
end

function WBLeaders.FormatEntry(entry, opts)
    if type(entry) ~= "table" then
        return ""
    end
    opts = type(opts) == "table" and opts or {}
    local name = formatted_leader_label(entry, opts)
    local detail = nil
    if type(entry.details) == "table" and #entry.details > 0 then
        detail = table.concat(entry.details, "; ")
    end
    local source_text = ""
    if not opts.omit_sources then
        source_text = formatted_source_text(entry.sources)
    end
    if detail and detail ~= "" then
        if source_text ~= "" then
            return tostring(name) .. " - " .. detail .. " " .. source_text
        end
        return tostring(name) .. " - " .. detail
    end
    if source_text == "" then
        return tostring(name)
    end
    return tostring(name) .. " " .. source_text
end

function WBLeaders.PrintResults(results)
    results = type(results) == "table" and results or WBLeaders.Collect()
    local total = #(results.entries or {})
    local open_count = count_entries_with_source(results.entries, WBLeaders.open_source_label)
    local map_count = count_entries_with_source(results.entries, WBLeaders.map_source_label)
    local manual_count = count_entries_with_source(results.entries, WBLeaders.manual_source_label)
    local parts = {
        "openwb " .. tostring(open_count),
        "crowns on map " .. tostring(map_count)
    }
    if manual_count > 0 then
        parts[#parts + 1] = "manual " .. tostring(manual_count)
    end
    local status = results.refresh_status == "cached" and " [cached; refresh incomplete]" or ""
    AB_util.print("WB leads known: " .. tostring(total) .. " (" .. table.concat(parts, ", ") .. ")." .. status)

    if total == 0 then
        AB_util.print("No WB leaders found. Open the map to include map crowns.")
        return
    end

    for i = 1, total do
        AB_util.print("  " .. WBLeaders.FormatEntry(results.entries[i]))
    end
end

-- Listing requests are asynchronous. These listeners exist only while a refresh
-- is pending, including manual requests with warband automation disabled.
local REFRESH_EVENTS = {
    { name = "SOCIAL_OPENPARTY_UPDATED", handler = "AutoBand.WBLeaders.OnNearbyUpdated", key = "nearby" },
    { name = "SOCIAL_OPENPARTY_WORLD_UPDATED", handler = "AutoBand.WBLeaders.OnWorldUpdated", key = "world" }
}
local REFRESH_TIMEOUT = 5
local REFRESH_INTERVAL = 2

local function stop_refresh_listeners(pending)
    if not pending.listeners then return end
    for _, listener in ipairs(pending.listeners) do
        pcall(UnregisterEventHandler, listener.id, listener.handler)
    end
    pending.listeners = nil
end

function WBLeaders.CancelRefresh()
    local pending = WBLeaders.pending_refresh
    if pending then
        stop_refresh_listeners(pending)
        WBLeaders.pending_refresh = nil
        AutoBand.clear_combat_resume_deferred("wbleaders_background_refresh")
    end
end

local function request_world_refresh()
    local interest = GameData and GameData.OpenPartyInterest and GameData.OpenPartyInterest.NOT_SET
    local level = current_player_cr()
    local tier = level and math.max(1, math.min(4, math.ceil(level / 10)))
    if type(SendOpenPartyWorldSearch) ~= "function" or interest == nil or not tier then
        return false
    end
    -- Same Any-interest values as the stock window; no UI or party settings writes.
    return pcall(SendOpenPartyWorldSearch, tier, interest, -1, -1, -1, -1)
end

local function complete_refresh(pending)
    stop_refresh_listeners(pending)
    WBLeaders.pending_refresh = nil
    AutoBand.clear_combat_resume_deferred("wbleaders_background_refresh")
    local fresh = pending.got_nearby and pending.got_world
    local results = WBLeaders.Collect({
        request_open_party = false,
        include_world = pending.got_world == true,
        include_realmrank = pending.include_realmrank
    })
    results.refresh_requested = pending.requested == true
    results.refresh_status = fresh and "refreshed" or "cached"
    if pending.print_results then
        WBLeaders.PrintResults(results)
        WBLeaders.MarkUserSeenResults(results)
    elseif pending.notify and (fresh or pending.cached_only) then
        WBLeaders.NotifyBackgroundChanges(pending.previous_results, results)
    end
end

local function start_refresh(pending)
    pending.delay = nil
    pending.starting = true
    pending.listeners = {}
    local events = SystemData and SystemData.Events
    for _, event in ipairs(REFRESH_EVENTS) do
        local id = events and events[event.name]
        if id and type(RegisterEventHandler) == "function" and type(UnregisterEventHandler) == "function" and
           pcall(RegisterEventHandler, id, event.handler) then
            pending.listeners[#pending.listeners + 1] = { id = id, handler = event.handler }
            pending["wait_" .. event.key] = true
        end
    end
    pending.cached_only = #pending.listeners == 0
    WBLeaders.last_refresh_request_s = current_uptime_seconds()
    local nearby = request_open_party_refresh()
    local world = request_world_refresh()
    pending.requested = nearby or world
    if not nearby then pending.wait_nearby = nil end
    if not world then pending.wait_world = nil end
    pending.starting = nil
end

local function refresh_combat_ready(pending, elapsed)
    if pending.print_results then return true end
    local player = GameData and GameData.Player
    if player and (player.inCombat == true or player.isInCombat == true) then
        AutoBand.mark_combat_resume_deferred("wbleaders_background_refresh")
        return false
    end
    return AutoBand.is_combat_resume_ready("wbleaders_background_refresh", elapsed)
end

function WBLeaders.UpdateRefresh(elapsed)
    local pending = WBLeaders.pending_refresh
    if not pending or pending.starting then
        return
    end
    if not pending.print_results and
       (not wbleader_features_enabled() or not AutoBand.is_wbleader_background_tracking_enabled()) then
        WBLeaders.CancelRefresh()
        return
    end
    elapsed = math.max(0, tonumber(elapsed) or 0)
    if pending.delay then
        if not refresh_combat_ready(pending, elapsed) then return end
        pending.delay = pending.delay - elapsed
        if pending.delay > 0 then return end
        start_refresh(pending)
        elapsed = 0
    end
    pending.elapsed = pending.elapsed + elapsed
    if pending.wait_nearby or pending.wait_world then
        if pending.elapsed < REFRESH_TIMEOUT then return end
        if not pending.print_results then
            WBLeaders.CancelRefresh()
            return
        end
    end
    stop_refresh_listeners(pending)
    if not refresh_combat_ready(pending, elapsed) then return end
    complete_refresh(pending)
end

function WBLeaders.OnNearbyUpdated()
    local pending = WBLeaders.pending_refresh
    if pending and pending.wait_nearby then
        pending.wait_nearby = nil
        pending.got_nearby = true
        WBLeaders.UpdateRefresh(0)
    end
end

function WBLeaders.OnWorldUpdated()
    local pending = WBLeaders.pending_refresh
    if pending and pending.wait_world then
        pending.wait_world = nil
        pending.got_world = true
        WBLeaders.UpdateRefresh(0)
    end
end

function WBLeaders.Refresh(opts)
    opts = opts or {}
    local pending = WBLeaders.pending_refresh
    if pending then
        pending.print_results = pending.print_results or opts.print_results == true
        pending.include_realmrank = pending.include_realmrank or opts.include_realmrank ~= false
        return true
    end
    pending = {
        elapsed = 0,
        delay = 0,
        print_results = opts.print_results == true,
        notify = opts.notify == true,
        include_realmrank = opts.include_realmrank ~= false,
        previous_results = WBLeaders.last_results
    }
    WBLeaders.pending_refresh = pending
    local now = current_uptime_seconds()
    local previous = WBLeaders.last_refresh_request_s
    if now and previous and now >= previous and now - previous < REFRESH_INTERVAL then
        pending.delay = REFRESH_INTERVAL - (now - previous)
    end
    WBLeaders.UpdateRefresh(0)
    return true
end

function AutoBand.cmd_wbleaders(args)
    local action = args and args[1] and string.lower(tostring(args[1])) or nil
    if action == "add" then
        local ok, name_or_message, added, verification = WBLeaders.AddManualLeader(join_args(args, 2))
        if not ok then
            AB_util.print(name_or_message)
            return
        end
        WBLeaders.Collect({ request_open_party = false })
        local suffix = " (unconfirmed; using manual entry)"
        if verification and verification.confirmed then
            suffix = " (confirmed via " .. tostring(verification.source) .. ")"
        end
        if added then
            AB_util.print("Added manual WB lead: " .. tostring(name_or_message) .. suffix)
        else
            AB_util.print("Updated manual WB lead: " .. tostring(name_or_message) .. suffix)
        end
        WBLeaders.MarkUserSeenName(name_or_message)
        return
    elseif action == "remove" or action == "rm" or action == "delete" or action == "del" then
        local ok, name_or_message = WBLeaders.RemoveManualLeader(join_args(args, 2))
        if not ok then
            AB_util.print(name_or_message)
            return
        end
        WBLeaders.Collect({ request_open_party = false })
        AB_util.print("Removed manual WB lead: " .. tostring(name_or_message))
        return
    elseif action == "clear" then
        local count = WBLeaders.ClearManualLeaders()
        WBLeaders.Collect({ request_open_party = false })
        AB_util.print("Cleared manual WB leads: " .. tostring(count))
        return
    elseif action == "min" or action == "minimum" or action == "minmembers" then
        local min_arg = args and args[2]
        if min_arg == nil then
            AB_util.print("WB lead open-list minimum members: " .. tostring(WBLeaders.GetMinMembers()))
            return
        end
        local min_text = string.lower(tostring(min_arg))
        if min_text == "reset" or min_text == "default" then
            min_arg = WBLeaders.default_min_members
        end
        local ok_min, min_or_message = WBLeaders.SetMinMembers(min_arg)
        if not ok_min then
            AB_util.print(min_or_message)
            return
        end
        WBLeaders.Collect({ request_open_party = false })
        AB_util.print("WB lead open-list minimum members set to: " .. tostring(min_or_message))
        if type(AutoBand.refresh_settings_ui) == "function" then
            AutoBand.refresh_settings_ui()
        end
        return
    elseif action == "notify" or action == "notifications" then
        local notify_arg = args and args[2]
        if notify_arg == nil then
            AB_util.print("WB lead change notifications: " .. notify_status_text())
            return
        end
        local notify_text = string.lower(tostring(notify_arg))
        local next_state = nil
        if notify_text == "on" or notify_text == "true" or notify_text == "1" or
           notify_text == "enable" or notify_text == "enabled" then
            next_state = true
        elseif notify_text == "off" or notify_text == "false" or notify_text == "0" or
               notify_text == "disable" or notify_text == "disabled" then
            next_state = false
        end
        if next_state == nil then
            AB_util.print("usage: /ab wblead notify <on|off>")
            return
        end
        WBLeaders.SetNotifyEnabled(next_state)
        AB_util.print("WB lead change notifications: " .. notify_status_text())
        if type(AutoBand.refresh_settings_ui) == "function" then
            AutoBand.refresh_settings_ui()
        end
        return
    elseif action == "debug" or action == "dump" then
        local ok_debug, debug_message = WBLeaders.DebugOpenList(join_args(args, 2))
        if not ok_debug and debug_message then
            AB_util.print(debug_message)
        end
        return
    end

    WBLeaders.Refresh({ print_results = true })
end

function WBLeaders.RegisterCommands(cmd_table)
    if type(cmd_table) ~= "table" then
        return
    end
    cmd_table["wbleads"] = {
        f = AutoBand.cmd_wbleaders,
        help = WBLeaders.command_help,
        print_id = WBLeaders.command_print_id
    }
    cmd_table["wbleaders"] = { f = AutoBand.cmd_wbleaders, help = "" }
    cmd_table["wblead"] = { f = AutoBand.cmd_wbleaders, help = "" }
end

AutoBand.command_definition_hooks = AutoBand.command_definition_hooks or {}
if WBLeaders.command_registration_hook_installed ~= true then
    table.insert(AutoBand.command_definition_hooks, function(cmd_table)
        WBLeaders.RegisterCommands(cmd_table)
    end)
    WBLeaders.command_registration_hook_installed = true
end
