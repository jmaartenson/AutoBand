-- AB_zonevote.lua
-- ZoneVote readycheck integration and active-zone vote helpers.

AutoBand.zone_vote_config = {
    default_timer_seconds = 60,
    start_notice_delay_seconds = 2,
    prompt_sound = 330,
    order_ram_icon = 29964,
    destruction_ram_icon = 29965,
    answer_sounds = { 5073, 5042, 5013, 5120, 5050, 5042 },
    answer_colors = {
        { r = 0, g = 255, b = 255 },
        { r = 255, g = 0, b = 255 },
        { r = 255, g = 255, b = 0 },
        { r = 0, g = 255, b = 0 },
        { r = 125, g = 125, b = 255 },
        { r = 255, g = 255, b = 255 },
    },
}

-- SoR 2.0 keeps its live zones private. Observe Chat independently: claiming
-- SOR_STATUS/SOR_F in ror_PacketHandling would take packets away from SoR.
-- The older client still supplies OpenZones/KEEP_IDs; leave that path intact.
local zonevote_sor_zones = {}
local zonevote_sor_time = 0
local ZONEVOTE_SOR_LIFETIME = 10 -- RoR_SoR 2.0.0 ZONE_LIFETIME.

local function zonevote_legacy_sor()
    return type(RoR_SoR) == "table" and type(RoR_SoR.OpenZones) == "table"
end

local function zonevote_sor_zone_names()
    if zonevote_legacy_sor() then
        return RoR_SoR.ZoneNames
    end
    return type(RoR_SoR_Static) == "table" and RoR_SoR_Static.ZoneNames or nil
end

local function zonevote_sor_wanted(zone)
    local settings = type(RoR_SoR) == "table" and RoR_SoR.Settings
    if type(settings) ~= "table" then return false end
    if zone.fort then return settings.ShowForts == true end
    if zone.tier == 1 then return settings.ShowT1 == true end
    return settings.ShowT4 == true
end

local function zonevote_sor_zone(zone_id)
    local zone = zonevote_sor_zones[zone_id]
    if zone and (zone.expires <= zonevote_sor_time or not zonevote_sor_wanted(zone)) then
        zonevote_sor_zones[zone_id] = nil
        return nil
    end
    return zone
end

function AutoBand.zonevote_reset_sor()
    zonevote_sor_zones = {}
    zonevote_sor_time = 0
end

function AutoBand.zonevote_update_sor(elapsed)
    -- Only advance a clock per frame; prune the bounded zone set on reads.
    if elapsed > 0 then zonevote_sor_time = zonevote_sor_time + elapsed end
end

local function zonevote_sor_packet(text)
    local fort = string.sub(text, 1, 6) == "SOR_F:"
    if not fort and string.sub(text, 1, 11) ~= "SOR_STATUS:" then return end
    if type(RoR_SoR_Static) ~= "table" or type(RoR_SoR_Json) ~= "table"
        or type(RoR_SoR_Json.Decode) ~= "function" then return end

    local zone_id = tonumber(string.match(text, '"zoneId"%s*:%s*(%d+)'))
    local names = zonevote_sor_zone_names()
    -- Only native campaign/fort ids can occupy cache slots. Cities and pairing
    -- panels are not vote destinations, and SOR_STATUS is not a fort feed.
    if not zone_id or type(names) ~= "table" or not names[zone_id] then return end
    local is_fort = type(RoR_SoR_Static.Forts) == "table" and RoR_SoR_Static.Forts[zone_id] ~= nil
    if fort ~= is_fort then return end

    local zone = zonevote_sor_zone(zone_id)
    if zone and zone.raw == text then
        zone.expires = zonevote_sor_time + ZONEVOTE_SOR_LIFETIME
        return
    end
    local body_at = string.find(text, "{", 1, true)
    if not body_at then return end
    local ok, data = pcall(RoR_SoR_Json.Decode, text, body_at)
    if not ok or type(data) ~= "table" or data.zoneId ~= zone_id then return end

    local tier = data.tier
    local keeps = nil
    if fort then
        if type(data.attackers) ~= "table" or type(data.defenders) ~= "table"
            or type(data.stage) ~= "number" or type(data.timeRemaining) ~= "number" then return end
        tier = 5 -- Native fortress row sort tier.
    else
        if type(tier) ~= "number" or tier < 1 or tier > 4 or tier ~= math.floor(tier)
            or type(data.objectives) ~= "table" then return end
        if tier > 1 then
            if type(data.keeps) ~= "table" then return end
            keeps = {}
            for index = 1, 2 do
                local keep = data.keeps[index]
                if type(keep) ~= "table" or type(keep.realm) ~= "number"
                    or type(keep.rank) ~= "number" then return end
                keeps[index] = { realm = keep.realm, rank = keep.rank }
            end
        end
    end
    local next_zone = { tier = tier, fort = fort, keeps = keeps,
        raw = text, expires = zonevote_sor_time + ZONEVOTE_SOR_LIFETIME }
    if zonevote_sor_wanted(next_zone) then
        zonevote_sor_zones[zone_id] = next_zone
    else
        zonevote_sor_zones[zone_id] = nil
    end
end

function AutoBand.OnZoneVoteChatLogUpdated(update_type, filter_type)
    if not AutoBand.is_warband_enabled() or zonevote_legacy_sor() then return end
    if not (SystemData and SystemData.TextLogUpdate and SystemData.ChatLogFilters)
        or update_type ~= SystemData.TextLogUpdate.ADDED
        or filter_type ~= SystemData.ChatLogFilters.CHANNEL_9 then return end
    local count = TextLogGetNumEntries("Chat")
    if count <= 0 then return end
    local _, entry_filter, text = TextLogGetEntry("Chat", count - 1)
    if entry_filter ~= filter_type then return end
    if type(text) ~= "string" then
        local ok, plain = pcall(tostring, text)
        if not ok then return end
        text = plain
    end
    zonevote_sor_packet(text)
end

function AutoBand.zonevote_set_sor_tracking(enabled)
    if enabled then
        if AutoBand.zonevote_sor_chat_event == nil and type(TextLogGetUpdateEventId) == "function"
            and type(RegisterEventHandler) == "function" then
            local event = TextLogGetUpdateEventId("Chat")
            if event ~= nil then
                RegisterEventHandler(event, "AutoBand.OnZoneVoteChatLogUpdated")
                AutoBand.zonevote_sor_chat_event = event
            end
        end
    else
        if AutoBand.zonevote_sor_chat_event ~= nil and type(UnregisterEventHandler) == "function" then
            UnregisterEventHandler(AutoBand.zonevote_sor_chat_event, "AutoBand.OnZoneVoteChatLogUpdated")
        end
        AutoBand.zonevote_sor_chat_event = nil
        AutoBand.zonevote_reset_sor()
    end
end

local ZONEVOTE_LABEL_RULES = {
    -- Tier 1
    { ids = { 100, 106 }, tier = 1, label = "Nordland" },
    { ids = { 6, 11 }, tier = 1, faction_label = {
        [AB_const.ORDER] = "Ekrund",
        [AB_const.DESTRUCTION] = "Mount Bloodhorn",
    } },
    { ids = { 200, 206 }, tier = 1, label = "Blighted Isle" },

    -- Tier 2
    { ids = { 101, 107 }, tier = 2, faction_label = {
        [AB_const.ORDER] = "TC",
        [AB_const.DESTRUCTION] = "Ostland",
    } },
    { ids = { 7, 1 }, tier = 2, label = "BV / Marshes" },
    { ids = { 201, 207 }, tier = 2, label = "SL / Ellyrion" },

    -- Tier 3
    { ids = { 102, 108 }, tier = 3, faction_label = {
        [AB_const.ORDER] = "High Pass",
        [AB_const.DESTRUCTION] = "Talabecland",
    } },
    { ids = { 2, 8 }, tier = 3, label = "Badlands / BFP" },
    { ids = { 202, 208 }, tier = 3, label = "Avelorn / Saphery" },

    -- Tier 4 Dwarf/Greenskin
    { ids = { 9 }, tier = 4, label = "KV" },
    { ids = { 5 }, tier = 4, label = "TM" },
    { ids = { 3 }, tier = 4, label = "BC" },
}

local ZONEVOTE_LABEL_BY_ZONE_ID = {}
for _, rule in ipairs(ZONEVOTE_LABEL_RULES) do
    if type(rule.ids) == "table" then
        for _, zone_id in ipairs(rule.ids) do
            ZONEVOTE_LABEL_BY_ZONE_ID[zone_id] = rule
        end
    end
end

function AutoBand.zonevote_reset_state()
    AutoBand.zonevote_reset_sor()
    AutoBand.zonevote_debug_enabled = false
    AutoBand.zonevote_last_local_player_id = nil
    AutoBand.zonevote_last_local_player_name_key = nil
    AutoBand.zonevote_timer_seconds = nil
    AutoBand.zonevote_elapsed_seconds = 0
    AutoBand.zonevote_half_reminder_sent = false
    AutoBand.zonevote_last_reminder_skip_trace = nil
    AutoBand.zonevote_start_notice_pending_text = nil
    AutoBand.zonevote_start_notice_elapsed_seconds = 0
    AutoBand.zonevote_result_active = false
    AutoBand.zonevote_result_title = nil
    AutoBand.zonevote_result_answers = nil
    AutoBand.zonevote_local_pending_choice = nil
    AutoBand.zonevote_local_pending_player_id = nil
    AutoBand.zonevote_local_confirmed_player_id = nil
end

function AutoBand.zonevote_extract_open_zone_id(zone_key, zone_value)
    local key_num = tonumber(zone_key)
    if key_num ~= nil then
        return key_num
    end
    return tonumber(zone_value)
end

function AutoBand.zonevote_is_vote_zone(zone_id)
    local zone_num = tonumber(zone_id)
    if zone_num == nil then
        return false
    end

    if zone_num == 161 or zone_num == 162 then
        return false
    end

    return true
end

function AutoBand.zonevote_get_zone_status(zone_id)
    if not zonevote_legacy_sor() then
        return zonevote_sor_zone(tonumber(zone_id))
    end
    if type(RoR_SoR) ~= "table" or type(RoR_SoR.ZoneStatus) ~= "table" then
        return nil
    end

    local zone_num = tonumber(zone_id)
    return RoR_SoR.ZoneStatus[tostring(zone_num)] or RoR_SoR.ZoneStatus[zone_num]
end

function AutoBand.zonevote_get_player_faction_key()
    if AutoBand.faction == AB_const.ORDER or AutoBand.faction == AB_const.DESTRUCTION then
        return AutoBand.faction
    end

    local realm = nil
    if GameData and GameData.Player and tonumber(GameData.Player.realm) ~= nil then
        realm = tonumber(GameData.Player.realm)
    end
    if realm ~= nil and GameData and GameData.Realm then
        if realm == tonumber(GameData.Realm.ORDER) then
            return AB_const.ORDER
        elseif realm == tonumber(GameData.Realm.DESTRUCTION) then
            return AB_const.DESTRUCTION
        end
    end
    return nil
end

function AutoBand.zonevote_get_label_rule(zone_id)
    local zone_num = tonumber(zone_id)
    if zone_num == nil then
        return nil
    end
    return ZONEVOTE_LABEL_BY_ZONE_ID[zone_num]
end

function AutoBand.zonevote_get_rule_label(zone_id)
    local rule = AutoBand.zonevote_get_label_rule(zone_id)
    if type(rule) ~= "table" then
        return nil, nil
    end

    if type(rule.faction_label) == "table" then
        local faction = AutoBand.zonevote_get_player_faction_key()
        local faction_label = rule.faction_label[faction]
        if type(faction_label) == "string" and faction_label ~= "" then
            return faction_label, rule
        end
    end

    if type(rule.label) == "string" and rule.label ~= "" then
        return rule.label, rule
    end

    return nil, rule
end

function AutoBand.zonevote_get_zone_name(zone_id)
    local zone_num = tonumber(zone_id)
    if zone_num == nil then
        return "Zone " .. tostring(zone_id or "?")
    end

    local rule_label, rule = AutoBand.zonevote_get_rule_label(zone_num)
    if rule_label ~= nil then
        return rule_label, rule
    end

    local zone_names = zonevote_sor_zone_names()
    local is_fort = not zonevote_legacy_sor() and type(RoR_SoR_Static) == "table"
        and type(RoR_SoR_Static.Forts) == "table" and RoR_SoR_Static.Forts[zone_num] ~= nil
    if type(zone_names) == "table" and not is_fort then
        local pair = zone_names[zone_num] or zone_names[tostring(zone_num)]
        if type(pair) == "table" and pair[1] ~= nil and pair[2] ~= nil and pair[1] ~= pair[2] then
            local left = AB_util.get_zone_name_sanitized(tonumber(pair[1]))
            local right = AB_util.get_zone_name_sanitized(tonumber(pair[2]))
            if left and right and left ~= "" and right ~= "" and left ~= "Offline" and right ~= "Offline" then
                return left .. " / " .. right, nil
            end
        end
    end

    local name = AB_util.get_zone_name_sanitized(zone_num)
    if name and name ~= "" and name ~= "Offline" then
        return name, nil
    end

    return "Zone " .. tostring(zone_num), nil
end

function AutoBand.zonevote_get_player_realm()
    if GameData and GameData.Player and tonumber(GameData.Player.realm) ~= nil then
        return tonumber(GameData.Player.realm)
    end

    if GameData and GameData.Realm then
        if AutoBand.faction == AB_const.ORDER and tonumber(GameData.Realm.ORDER) ~= nil then
            return tonumber(GameData.Realm.ORDER)
        end
        if AutoBand.faction == AB_const.DESTRUCTION and tonumber(GameData.Realm.DESTRUCTION) ~= nil then
            return tonumber(GameData.Realm.DESTRUCTION)
        end
    end

    if AutoBand.faction == AB_const.ORDER then
        return 1
    end
    if AutoBand.faction == AB_const.DESTRUCTION then
        return 2
    end
    return nil
end

function AutoBand.zonevote_get_ram_icon_token()
    local config = AutoBand.zone_vote_config or {}
    local icon = nil
    local realm = AutoBand.zonevote_get_player_realm()

    if GameData and GameData.Realm then
        if realm == tonumber(GameData.Realm.ORDER) then
            icon = config.order_ram_icon
        elseif realm == tonumber(GameData.Realm.DESTRUCTION) then
            icon = config.destruction_ram_icon
        end
    end

    if icon == nil then
        if AutoBand.faction == AB_const.ORDER then
            icon = config.order_ram_icon
        elseif AutoBand.faction == AB_const.DESTRUCTION then
            icon = config.destruction_ram_icon
        end
    end

    if tonumber(icon) ~= nil then
        return "<icon" .. tostring(tonumber(icon)) .. "> "
    end
    return ""
end

function AutoBand.zonevote_to_plain_text(value)
    if value == nil then
        return ""
    end

    local text = value
    if type(AutoBand.FixString) == "function" then
        local ok_fix, fixed = pcall(AutoBand.FixString, value)
        if ok_fix and fixed ~= nil then
            text = fixed
        end
    elseif type(text) ~= "string" and type(WStringToString) == "function" then
        local ok_wstring, converted = pcall(WStringToString, text)
        if ok_wstring and converted ~= nil then
            text = converted
        end
    end

    local ok_text, text_string = pcall(tostring, text)
    if not ok_text or text_string == nil then
        return ""
    end

    return text_string
end

function AutoBand.zonevote_sanitize_alert_field(value)
    return string.gsub(AutoBand.zonevote_to_plain_text(value), ":", "-")
end

local function zonevote_debug_text(value)
    if value == nil then
        return "nil"
    end

    local ok, text = pcall(tostring, value)
    if ok and text ~= nil then
        return text
    end
    return "<unprintable>"
end

local function zonevote_debug(message)
    if AutoBand.zonevote_debug_enabled ~= true then
        return
    end

    local text = "[zonevote] " .. zonevote_debug_text(message)
    if type(AB_util) == "table" and type(AB_util.print) == "function" then
        AB_util.print(text)
    elseif type(d) == "function" then
        d(text)
    end
end

local function zonevote_trace(message)
    if AutoBand.zonevote_debug_enabled ~= true then
        return
    end

    local text = "[zonevote trace] " .. zonevote_debug_text(message)
    if type(AB_util) == "table" and type(AB_util.print) == "function" then
        AB_util.print(text)
    elseif type(d) == "function" then
        d(text)
    end
end

local function zonevote_trace_clip(value)
    local text = zonevote_debug_text(value)
    if string.len(text) > 180 then
        return string.sub(text, 1, 180) .. "..."
    end
    return text
end

local function zonevote_message_kind(text)
    if string.find(text, "ZoneVote started", 1, true) ~= nil then
        return "start"
    end
    if string.find(text, "ZoneVote reminder", 1, true) ~= nil then
        return "reminder"
    end
    if string.find(text, "ZoneVote results", 1, true) ~= nil then
        return "results"
    end
    return "other"
end

local function zonevote_truthy_flag(value)
    if value == true then
        return true
    end
    if value == false or value == nil then
        return false
    end
    if type(value) == "number" then
        return value ~= 0
    end
    return true
end

function AutoBand.zonevote_send_warband_message(message)
    local text = AutoBand.zonevote_to_plain_text(message)
    local trace_enabled = AutoBand.zonevote_debug_enabled == true
    local kind = trace_enabled and zonevote_message_kind(text) or nil
    if text == "" then
        if trace_enabled then
            zonevote_trace("send " .. kind .. " aborted: empty text")
        end
        return false
    end

    local prefix = ""
    if type(AutoBand.GetFormattedPrefixRaw) == "function" then
        prefix = AutoBand.GetFormattedPrefixRaw(true)
    end

    local command = "/wb " .. prefix .. text
    if trace_enabled then
        zonevote_trace("send " .. kind
            .. " textLen=" .. tostring(string.len(text))
            .. " prefixLen=" .. tostring(string.len(prefix))
            .. " cmdLen=" .. tostring(string.len(command))
            .. " queueBefore=" .. tostring(AutoBand.cmd_queue and #AutoBand.cmd_queue or 0)
            .. " cmd=" .. zonevote_trace_clip(command))
    end
    if type(AutoBand.enqueue_command) == "function" then
        local queued = AutoBand.enqueue_command(command, 1) == true
        if trace_enabled then
            zonevote_trace("send " .. kind
                .. " queued=" .. tostring(queued)
                .. " queueAfter=" .. tostring(AutoBand.cmd_queue and #AutoBand.cmd_queue or 0))
        end
        return queued
    end

    if type(SendChatText) ~= "function" then
        if trace_enabled then
            zonevote_trace("send " .. kind .. " aborted: SendChatText missing")
        end
        return false
    end
    if trace_enabled then
        zonevote_trace("send " .. kind .. " direct SendChatText")
    end
    SendChatText(towstring(command), L"")
    return true
end

function AutoBand.zonevote_build_start_warband_text(ready_table)
    local title = AutoBand.zonevote_to_plain_text(ready_table and ready_table.Title or AutoBand.get_zonevote_title())
    local punctuation = "."
    local last = string.sub(title, -1)
    if last == "." or last == "?" or last == "!" then
        punctuation = ""
    end
    return "ZoneVote started: " .. title .. punctuation .. " Please vote."
end

function AutoBand.zonevote_schedule_start_warband_message(text)
    local message = AutoBand.zonevote_to_plain_text(text)
    if message == "" then
        zonevote_trace("start schedule aborted: empty text")
        return false
    end

    AutoBand.zonevote_start_notice_pending_text = message
    AutoBand.zonevote_start_notice_elapsed_seconds = 0
    zonevote_trace("start scheduled delay="
        .. tostring(tonumber((AutoBand.zone_vote_config or {}).start_notice_delay_seconds) or 0)
        .. " textLen=" .. tostring(string.len(message)))
    return true
end

function AutoBand.zonevote_update_start_warband_message(elapsed)
    if AutoBand.zonevote_start_notice_pending_text == nil then
        return
    end

    local delay = tonumber((AutoBand.zone_vote_config or {}).start_notice_delay_seconds) or 0
    AutoBand.zonevote_start_notice_elapsed_seconds =
        (tonumber(AutoBand.zonevote_start_notice_elapsed_seconds) or 0) + (tonumber(elapsed) or 0)
    if AutoBand.zonevote_start_notice_elapsed_seconds < delay then
        return
    end

    local message = AutoBand.zonevote_start_notice_pending_text
    AutoBand.zonevote_start_notice_pending_text = nil
    zonevote_trace("start delay elapsed="
        .. tostring(AutoBand.zonevote_start_notice_elapsed_seconds)
        .. " sending=true")
    AutoBand.zonevote_send_warband_message(message)
end

function AutoBand.zonevote_get_vote_progress()
    local total = 0
    local cast = 0
    if type(ror_votewindow) == "table" then
        total = tonumber(ror_votewindow.Total_Players) or 0
        cast = tonumber(ror_votewindow.Total_Votes_Casted) or 0
        if total <= 0 and type(ror_votewindow.Players) == "table" then
            for _, row in pairs(ror_votewindow.Players) do
                if type(row) == "table" then
                    for _, player in pairs(row) do
                        if type(player) == "table" then
                            total = total + 1
                        end
                    end
                end
            end
        end
    end

    local remaining = total - cast
    if remaining < 0 then
        remaining = 0
    end
    return cast, total, remaining
end

function AutoBand.zonevote_build_reminder_warband_text()
    local _, total, remaining = AutoBand.zonevote_get_vote_progress()
    if total > 0 and remaining == 1 then
        return "ZoneVote reminder: 1 vote still missing."
    end
    if total > 0 and remaining > 1 then
        return "ZoneVote reminder: " .. tostring(remaining) .. " votes still missing."
    end
    return "ZoneVote reminder: halfway through. Please vote if you haven't yet."
end

function AutoBand.zonevote_build_result_warband_text()
    local answers = AutoBand.zonevote_result_answers or {}
    local counts = {}
    if type(ror_votewindow) == "table" and type(ror_votewindow.Player_Choices) == "table" then
        counts = ror_votewindow.Player_Choices
    end
    local pending_local_choice = nil
    if AutoBand.zonevote_local_choice_pending() == true then
        pending_local_choice = tonumber(AutoBand.zonevote_local_pending_choice)
    end

    local pieces = {}
    for index, answer in ipairs(answers) do
        local count = tonumber(counts[index]) or 0
        if pending_local_choice == index then
            count = count + 1
        end
        if count > 0 then
            pieces[#pieces + 1] = AutoBand.zonevote_to_plain_text(answer and answer.Name or ("Choice " .. tostring(index))) .. " = " .. tostring(count)
        end
    end

    if #pieces == 0 then
        return "ZoneVote results: No votes."
    end
    return "ZoneVote results: " .. table.concat(pieces, "; ")
end

function AutoBand.zonevote_update_warband_reminder(elapsed)
    AutoBand.zonevote_update_start_warband_message(elapsed)

    if AutoBand.zonevote_result_active ~= true or AutoBand.zonevote_half_reminder_sent == true then
        return
    end
    if type(ror_votewindow) == "table"
        and ror_votewindow.IsVoteStarted ~= nil
        and not zonevote_truthy_flag(ror_votewindow.IsVoteStarted)
    then
        if AutoBand.zonevote_last_reminder_skip_trace ~= "inactive" then
            zonevote_trace("reminder skipped: exposed IsVoteStarted="
                .. zonevote_debug_text(ror_votewindow.IsVoteStarted))
            AutoBand.zonevote_last_reminder_skip_trace = "inactive"
        end
        return
    end

    local timer = tonumber(AutoBand.zonevote_timer_seconds) or 0
    if timer <= 0 then
        if AutoBand.zonevote_last_reminder_skip_trace ~= "timer" then
            zonevote_trace("reminder skipped: timer=" .. tostring(timer))
            AutoBand.zonevote_last_reminder_skip_trace = "timer"
        end
        return
    end

    AutoBand.zonevote_elapsed_seconds = (tonumber(AutoBand.zonevote_elapsed_seconds) or 0) + (tonumber(elapsed) or 0)
    if AutoBand.zonevote_elapsed_seconds < (timer / 2) then
        return
    end

    AutoBand.zonevote_half_reminder_sent = true
    local reminder = AutoBand.zonevote_build_reminder_warband_text()
    local cast, total, remaining = AutoBand.zonevote_get_vote_progress()
    zonevote_trace("reminder due elapsed="
        .. tostring(AutoBand.zonevote_elapsed_seconds)
        .. " timer=" .. tostring(timer)
        .. " cast=" .. tostring(cast)
        .. " total=" .. tostring(total)
        .. " remaining=" .. tostring(remaining)
        .. " message=" .. zonevote_debug_text(reminder))
    if reminder ~= nil then
        AutoBand.zonevote_send_warband_message(reminder)
    end
end

function AutoBand.zonevote_get_current_window_title()
    if type(LabelGetText) ~= "function" then
        return nil, "LabelGetText unavailable"
    end

    return AutoBand.zonevote_sanitize_alert_field(LabelGetText("RoR_Window_votewindowText")), nil
end

function AutoBand.zonevote_remember_result_table(ready_table)
    AutoBand.zonevote_result_active = true
    AutoBand.zonevote_result_title = AutoBand.zonevote_sanitize_alert_field(ready_table and ready_table.Title or AutoBand.get_zonevote_title())
    AutoBand.zonevote_result_answers = ready_table and ready_table.Answers or nil
    AutoBand.zonevote_local_pending_choice = nil
    AutoBand.zonevote_local_pending_player_id = nil
    AutoBand.zonevote_local_confirmed_player_id = nil
    AutoBand.zonevote_timer_seconds = tonumber(ready_table and ready_table.Timer) or tonumber((AutoBand.zone_vote_config or {}).default_timer_seconds) or 0
    AutoBand.zonevote_elapsed_seconds = 0
    AutoBand.zonevote_half_reminder_sent = false
    AutoBand.zonevote_last_reminder_skip_trace = nil
    zonevote_debug("remember title=" .. zonevote_debug_text(AutoBand.zonevote_result_title)
        .. " answers=" .. tostring(#(AutoBand.zonevote_result_answers or {})))
end

function AutoBand.zonevote_clear_result_state(reason)
    AutoBand.zonevote_result_active = false
    AutoBand.zonevote_result_title = nil
    AutoBand.zonevote_result_answers = nil
    AutoBand.zonevote_local_pending_choice = nil
    AutoBand.zonevote_local_pending_player_id = nil
    AutoBand.zonevote_local_confirmed_player_id = nil
    AutoBand.zonevote_timer_seconds = nil
    AutoBand.zonevote_elapsed_seconds = 0
    AutoBand.zonevote_half_reminder_sent = false
    AutoBand.zonevote_start_notice_pending_text = nil
    AutoBand.zonevote_start_notice_elapsed_seconds = 0
    if reason ~= nil then
        zonevote_debug("cleared state: " .. zonevote_debug_text(reason))
    end
end

function AutoBand.zonevote_current_title_matches_result_table()
    if AutoBand.zonevote_result_active ~= true or not AutoBand.zonevote_result_title then
        zonevote_debug("title check inactive active=" .. tostring(AutoBand.zonevote_result_active)
            .. " stored=" .. zonevote_debug_text(AutoBand.zonevote_result_title))
        return false
    end

    local current_title, title_err = AutoBand.zonevote_get_current_window_title()
    if title_err ~= nil then
        zonevote_debug("title check accepting without live title: " .. title_err)
        return true
    end

    if current_title == AutoBand.zonevote_result_title then
        zonevote_debug("title check ok stored=" .. zonevote_debug_text(AutoBand.zonevote_result_title)
            .. " current=" .. zonevote_debug_text(current_title))
        return true
    end

    zonevote_debug("title mismatch stored=" .. zonevote_debug_text(AutoBand.zonevote_result_title)
        .. " current=" .. zonevote_debug_text(current_title) .. "; deactivating ZoneVote hooks")
    AutoBand.zonevote_clear_result_state("title mismatch")
    return false
end

function AutoBand.zonevote_is_warband_active_now()
    if type(IsWarBandActive) == "function" then
        local ok_wb, is_active = pcall(IsWarBandActive)
        if ok_wb then
            return zonevote_truthy_flag(is_active)
        end
    end
    return zonevote_truthy_flag(AutoBand.inWarband)
end

function AutoBand.zonevote_close_locally_after_warband_leave()
    if AutoBand.zonevote_result_active ~= true then
        return false
    end
    if AutoBand.zonevote_is_warband_active_now() == true then
        return false
    end
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        return false
    end

    AutoBand.zonevote_clear_result_state("warband inactive; closing local vote window")
    if type(ror_votewindow) == "table" then
        ror_votewindow.Has_Voted = true
        if type(ror_votewindow.AbortVote) == "function" then
            ror_votewindow.AbortVote(nil, 4, 0)
            return true
        end
        ror_votewindow.IsVoteStarted = false
    end
    if type(WindowSetShowing) == "function" then
        WindowSetShowing("RoR_Window_votewindow", false)
    end
    return true
end

function AutoBand.zonevote_player_name_key(name)
    if name == nil then
        return nil
    end

    local value = name
    if type(WStringsRemoveGrammar) == "function" then
        local ok_grammar, no_grammar = pcall(WStringsRemoveGrammar, value)
        if ok_grammar and no_grammar ~= nil then
            value = no_grammar
        end
    end
    if type(AutoBand.FixString) == "function" then
        local ok_fix, fixed = pcall(AutoBand.FixString, value)
        if ok_fix and fixed ~= nil then
            value = fixed
        end
    elseif type(value) ~= "string" and type(WStringToString) == "function" then
        local ok_wstring, converted = pcall(WStringToString, value)
        if ok_wstring and converted ~= nil then
            value = converted
        end
    end

    local ok_text, text = pcall(tostring, value)
    if not ok_text or text == nil or text == "" then
        return nil
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then
        return nil
    end
    return string.lower(text)
end

function AutoBand.zonevote_get_local_player_id()
    if not (GameData and GameData.Player and GameData.Player.name) then
        return nil
    end

    local self_key = AutoBand.zonevote_player_name_key(GameData.Player.name)
    if self_key == nil then
        return nil
    end

    if type(ror_votewindow) ~= "table" or type(ror_votewindow.Players) ~= "table" then
        if AutoBand.zonevote_last_local_player_name_key == self_key then
            return AutoBand.zonevote_last_local_player_id
        end
        return nil
    end

    for _, row in pairs(ror_votewindow.Players) do
        if type(row) == "table" then
            for _, player in pairs(row) do
                if type(player) == "table" and AutoBand.zonevote_player_name_key(player.name) == self_key then
                    local player_id = player.charId or player.characterId or player.id
                    AutoBand.zonevote_last_local_player_id = player_id
                    AutoBand.zonevote_last_local_player_name_key = self_key
                    return player_id
                end
            end
        end
    end

    if AutoBand.zonevote_last_local_player_name_key == self_key then
        return AutoBand.zonevote_last_local_player_id
    end

    return nil
end

function AutoBand.zonevote_get_selected_choice()
    local window_name = "RoR_Window_votewindow"
    if type(WindowGetShowing) == "function"
        and WindowGetShowing(window_name .. "_ChoiceCombo") == true
        and type(ComboBoxGetSelectedMenuItem) == "function"
    then
        return tonumber(ComboBoxGetSelectedMenuItem(window_name .. "_ChoiceCombo"))
    end

    if type(WindowGetId) == "function"
        and SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name
    then
        return tonumber(WindowGetId(SystemData.ActiveWindow.name))
    end

    return nil
end

function AutoBand.zonevote_note_local_select_choice()
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        return
    end
    if type(ror_votewindow) == "table" and ror_votewindow.Has_Voted == true then
        zonevote_debug("select ignored because Has_Voted=true")
        return
    end

    local choice = AutoBand.zonevote_get_selected_choice()
    if choice == nil or choice <= 0 then
        zonevote_debug("select ignored because selected choice was invalid: " .. zonevote_debug_text(choice))
        return
    end

    AutoBand.zonevote_local_pending_choice = choice
    AutoBand.zonevote_local_pending_player_id = AutoBand.zonevote_get_local_player_id()
    zonevote_debug("selected choice=" .. tostring(choice)
        .. " pendingPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_player_id))
end

function AutoBand.zonevote_apply_local_vote_confirmed_ui()
    if type(ror_votewindow) ~= "table" then
        return
    end

    local window_name = "RoR_Window_votewindow"
    ror_votewindow.Has_Voted = true

    if type(WindowSetShowing) == "function" then
        WindowSetShowing(window_name .. "_Choice_Vote_1", false)
        WindowSetShowing(window_name .. "_Choice_Vote_2", false)
        WindowSetShowing(window_name .. "_ChoiceCombo", false)
        local is_leader = GameData and GameData.Player and GameData.Player.isGroupLeader == true
        WindowSetShowing(window_name .. "Close", is_leader or ror_votewindow.Has_Voted)
    end

    if type(WindowSetDimensions) == "function" then
        local player_rows = 0
        if type(ror_votewindow.Players) == "table" then
            player_rows = #ror_votewindow.Players
        end
        WindowSetDimensions(window_name, 350, 77 + (35 * player_rows))
    end
    if type(WindowClearAnchors) == "function" then
        WindowClearAnchors(window_name .. "TimerBar")
    end
    if type(WindowAddAnchor) == "function" then
        WindowAddAnchor(window_name .. "TimerBar", "bottomleft", window_name, "bottomleft", 50, -16)
    end
    zonevote_debug("local vote confirmed; controls hidden")
end

function AutoBand.zonevote_get_choice_count(choice)
    if type(ror_votewindow) ~= "table" or type(ror_votewindow.Player_Choices) ~= "table" then
        return 0
    end
    return tonumber(ror_votewindow.Player_Choices[tonumber(choice)]) or 0
end

function AutoBand.zonevote_get_total_votes_casted()
    if type(ror_votewindow) ~= "table" then
        return 0
    end
    return tonumber(ror_votewindow.Total_Votes_Casted) or 0
end

function AutoBand.zonevote_ids_match(left, right)
    if left == nil or right == nil then
        return false
    end
    return tostring(left) == tostring(right)
end

function AutoBand.zonevote_find_player_vote_slot(player_id)
    if type(ror_votewindow) ~= "table" or type(ror_votewindow.Players) ~= "table" then
        return nil
    end

    for row_key, row in pairs(ror_votewindow.Players) do
        if type(row) == "table" then
            local fallback_slot = 0
            for player_key, player in pairs(row) do
                fallback_slot = fallback_slot + 1
                if type(player) == "table"
                    and (AutoBand.zonevote_ids_match(player_id, player.charId)
                        or AutoBand.zonevote_ids_match(player_id, player.characterId)
                        or AutoBand.zonevote_ids_match(player_id, player.id))
                then
                    local slot = nil
                    if type(ror_votewindow.Vote_Choice) == "table" and type(ror_votewindow.Vote_Choice[row_key]) == "table" then
                        local row_choices = ror_votewindow.Vote_Choice[row_key]
                        slot = row_choices[player_id]
                            or row_choices[tonumber(player_id)]
                            or row_choices[tostring(player_id)]
                            or row_choices[player_key]
                    end
                    return row_key, slot or fallback_slot
                end
            end
        end
    end

    return nil
end

function AutoBand.zonevote_find_local_label_vote_slot()
    if not (GameData and GameData.Player and GameData.Player.name) or type(LabelGetText) ~= "function" then
        return nil
    end

    local self_key = AutoBand.zonevote_player_name_key(GameData.Player.name)
    if self_key == nil then
        return nil
    end

    local window_name = "RoR_Window_votewindowParty"
    for row = 1, 4 do
        for slot = 1, 6 do
            local label_name = window_name .. tostring(row) .. tostring(slot) .. "Name"
            local ok_label, label_text = pcall(LabelGetText, label_name)
            if ok_label and AutoBand.zonevote_player_name_key(label_text) == self_key then
                return row, slot
            end
        end
    end

    return nil
end

function AutoBand.zonevote_find_first_visible_vote_slot()
    local window_name = "RoR_Window_votewindowParty"
    local seen = {}
    for row = 1, 4 do
        for slot = 1, 6 do
            local slot_name = window_name .. tostring(row) .. tostring(slot)
            local is_showing = false
            if type(WindowGetShowing) == "function" then
                local ok_showing, showing = pcall(WindowGetShowing, slot_name)
                is_showing = ok_showing and showing == true
            end
            local name_text = ""
            if type(LabelGetText) == "function" then
                local ok_label, label_value = pcall(LabelGetText, slot_name .. "Name")
                if ok_label and label_value ~= nil then
                    name_text = tostring(label_value)
                end
            end
            if is_showing or name_text ~= "" then
                seen[#seen + 1] = tostring(row) .. tostring(slot) .. "=" .. (name_text ~= "" and name_text or "<blank>")
                if is_showing == true then
                    return row, slot, table.concat(seen, ", ")
                end
            end
        end
    end
    if #seen > 0 then
        zonevote_debug("answer fallback visible-row scan saw: " .. table.concat(seen, ", "))
    else
        zonevote_debug("answer fallback visible-row scan saw no shown/name rows")
    end
    return nil
end

function AutoBand.zonevote_get_answer_label(choice)
    local answer = AutoBand.zonevote_result_answers and AutoBand.zonevote_result_answers[tonumber(choice)] or nil
    if type(answer) ~= "table" then
        return towstring("Choice " .. tostring(choice)), { r = 255, g = 255, b = 255 }, 0
    end

    local color = answer.Color or { r = 255, g = 255, b = 255 }
    local sound = tonumber(answer.Sound) or 0
    if answer.Icon ~= nil then
        return L"<icon" .. towstring(answer.Icon) .. L">", color, sound
    end
    return towstring(answer.Name or ("Choice " .. tostring(choice))), color, sound
end

function AutoBand.zonevote_is_pending_local_echo(player_id, choice)
    local pending_choice = tonumber(AutoBand.zonevote_local_pending_choice)
    local choice_num = tonumber(choice)
    if pending_choice == nil or choice_num == nil or pending_choice ~= choice_num then
        return false
    end
    if AutoBand.zonevote_local_pending_player_id ~= nil then
        return AutoBand.zonevote_ids_match(player_id, AutoBand.zonevote_local_pending_player_id)
    end
    return player_id ~= nil
end

function AutoBand.zonevote_apply_answer_vote_fallback(player_id, choice, count_before, total_before)
    local choice_num = tonumber(choice)
    if AutoBand.zonevote_result_active ~= true or choice_num == nil or choice_num <= 0 then
        return false
    end
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        return false
    end

    local count_after = AutoBand.zonevote_get_choice_count(choice_num)
    if count_after > (tonumber(count_before) or 0) then
        return false
    end

    local row_key, slot = AutoBand.zonevote_find_player_vote_slot(player_id)
    local used_label_slot = false
    local used_first_visible_slot = false
    local visible_scan = nil
    if row_key == nil or slot == nil then
        if AutoBand.zonevote_is_pending_local_echo(player_id, choice_num) ~= true then
            zonevote_debug("answer fallback skipped; no player row for playerId="
                .. zonevote_debug_text(player_id))
            return false
        end
        row_key, slot = AutoBand.zonevote_find_local_label_vote_slot()
        if row_key ~= nil and slot ~= nil then
            used_label_slot = true
        end
    end
    if (row_key == nil or slot == nil)
        and AutoBand.zonevote_is_pending_local_echo(player_id, choice_num) == true
        and AutoBand.zonevote_local_pending_player_id == nil
    then
        row_key, slot, visible_scan = AutoBand.zonevote_find_first_visible_vote_slot()
        if row_key ~= nil and slot ~= nil then
            used_first_visible_slot = true
        end
    end

    if row_key == nil or slot == nil then
        if type(ror_votewindow.Player_Choices) ~= "table" then
            ror_votewindow.Player_Choices = {}
        end
        ror_votewindow.Player_Choices[choice_num] = count_after + 1
        local total_after_no_row = AutoBand.zonevote_get_total_votes_casted()
        if total_after_no_row <= (tonumber(total_before) or 0) then
            ror_votewindow.Total_Votes_Casted = total_after_no_row + 1
        end
        zonevote_debug("answer fallback counted local echo without row playerId="
            .. zonevote_debug_text(player_id)
            .. " choice=" .. tostring(choice_num)
            .. " count=" .. tostring(ror_votewindow.Player_Choices[choice_num]))
        return true
    end
    if used_label_slot == true then
        zonevote_debug("answer fallback using local label row="
            .. zonevote_debug_text(row_key)
            .. " slot=" .. zonevote_debug_text(slot))
    end
    if used_first_visible_slot == true then
        zonevote_debug("answer fallback using first visible local row="
            .. zonevote_debug_text(row_key)
            .. " slot=" .. zonevote_debug_text(slot)
            .. " seen=" .. zonevote_debug_text(visible_scan))
    end

    if type(ror_votewindow.Player_Choices) ~= "table" then
        ror_votewindow.Player_Choices = {}
    end
    ror_votewindow.Player_Choices[choice_num] = count_after + 1
    local total_after = AutoBand.zonevote_get_total_votes_casted()
    if total_after <= (tonumber(total_before) or 0) then
        ror_votewindow.Total_Votes_Casted = total_after + 1
    end

    local window_name = "RoR_Window_votewindowParty" .. tostring(row_key) .. tostring(slot)
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(window_name .. "Flash", true)
    end
    local start_animation = _G and _G.AnimatedImageStartAnimation
    if type(start_animation) == "function" then
        start_animation(window_name .. "Flash", 0, false, true, 0)
    end

    local label, color, sound = AutoBand.zonevote_get_answer_label(choice_num)
    if type(LabelSetTextColor) == "function" then
        LabelSetTextColor(window_name .. "Choice", color.r or 255, color.g or 255, color.b or 255)
    end
    if type(WindowSetTintColor) == "function" then
        WindowSetTintColor(window_name, 255, 255, 255)
    end
    if type(LabelSetText) == "function" then
        LabelSetText(window_name .. "Choice", label)
    end
    if type(PlaySound) == "function" then
        PlaySound(sound)
    end

    zonevote_debug("answer fallback filled playerId=" .. zonevote_debug_text(player_id)
        .. " choice=" .. tostring(choice_num)
        .. " row=" .. zonevote_debug_text(row_key)
        .. " slot=" .. zonevote_debug_text(slot)
        .. " count=" .. tostring(ror_votewindow.Player_Choices[choice_num]))
    return true
end

function AutoBand.zonevote_send_selected_choice()
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        zonevote_debug("SelectChoice not handled by ZoneVote; falling back to stock")
        return false
    end
    if type(ror_votewindow) == "table" and ror_votewindow.Has_Voted == true then
        zonevote_debug("SelectChoice not handled because Has_Voted=true; falling back to stock")
        return false
    end
    if type(SendChatText) ~= "function" or not (ChatSettings and ChatSettings.Channels and ChatSettings.Channels[0]) then
        zonevote_debug("SelectChoice cannot send answer; falling back to stock")
        return false
    end

    AutoBand.zonevote_note_local_select_choice()
    local choice = tonumber(AutoBand.zonevote_local_pending_choice)
    if choice == nil or choice <= 0 then
        zonevote_debug("SelectChoice has no pending choice after capture; falling back to stock")
        return false
    end

    SendChatText(L"]readycheck answer " .. towstring(choice), ChatSettings.Channels[0].serverCmd)
    zonevote_debug("sent answer choice=" .. tostring(choice)
        .. " pendingPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_player_id))
    return true
end

function AutoBand.zonevote_note_answer_vote(player_id, choice)
    zonevote_debug("answer echo playerId=" .. zonevote_debug_text(player_id)
        .. " choice=" .. zonevote_debug_text(choice)
        .. " pendingChoice=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_choice)
        .. " pendingPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_player_id))
    if AutoBand.zonevote_result_active ~= true or AutoBand.zonevote_local_pending_choice == nil then
        return
    end
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        zonevote_debug("answer echo ignored because current title no longer matches ZoneVote")
        return
    end
    local pending_player_id = AutoBand.zonevote_local_pending_player_id
    if pending_player_id == nil then
        pending_player_id = AutoBand.zonevote_get_local_player_id()
        if pending_player_id ~= nil then
            AutoBand.zonevote_local_pending_player_id = pending_player_id
            zonevote_debug("answer echo refreshed pending player id="
                .. zonevote_debug_text(pending_player_id))
        end
    end
    if pending_player_id == nil then
        if player_id == nil or tonumber(choice) ~= tonumber(AutoBand.zonevote_local_pending_choice) then
            zonevote_debug("answer echo ignored because pending player id is unknown and echoed choice did not match")
            return
        end
        pending_player_id = player_id
        AutoBand.zonevote_local_pending_player_id = player_id
        zonevote_debug("answer echo inferred local player id=" .. zonevote_debug_text(player_id)
            .. " from matching pending choice")
    end
    if tostring(player_id) ~= tostring(pending_player_id) then
        zonevote_debug("answer echo ignored because pending player id did not match")
        return
    end

    AutoBand.zonevote_local_confirmed_player_id = pending_player_id
    if GameData and GameData.Player and GameData.Player.name then
        AutoBand.zonevote_last_local_player_id = pending_player_id
        AutoBand.zonevote_last_local_player_name_key = AutoBand.zonevote_player_name_key(GameData.Player.name)
    end
    AutoBand.zonevote_local_pending_choice = nil
    AutoBand.zonevote_local_pending_player_id = nil
    AutoBand.zonevote_apply_local_vote_confirmed_ui()
end

function AutoBand.zonevote_local_choice_pending()
    if AutoBand.zonevote_local_pending_choice == nil then
        return false
    end
    return true
end

local function zonevote_debug_choice_counts_text()
    if type(ror_votewindow) ~= "table" or type(ror_votewindow.Player_Choices) ~= "table" then
        return "none"
    end

    local pieces = {}
    local answers = AutoBand.zonevote_result_answers or {}
    for index, _ in ipairs(answers) do
        pieces[#pieces + 1] = tostring(index) .. "=" .. tostring(tonumber(ror_votewindow.Player_Choices[index]) or 0)
    end
    if #pieces == 0 then
        for index, count in pairs(ror_votewindow.Player_Choices) do
            pieces[#pieces + 1] = tostring(index) .. "=" .. tostring(count)
        end
    end
    if #pieces == 0 then
        return "none"
    end
    return table.concat(pieces, ", ")
end

local function zonevote_print_debug_state()
    local current_title, title_err = AutoBand.zonevote_get_current_window_title()
    local selected_choice = AutoBand.zonevote_get_selected_choice()
    local local_player_id = AutoBand.zonevote_get_local_player_id()
    local has_voted = nil
    local is_started = nil
    if type(ror_votewindow) == "table" then
        has_voted = ror_votewindow.Has_Voted
        is_started = ror_votewindow.IsVoteStarted
    end

    AB_util.print("[zonevote] debug trace: " .. tostring(AutoBand.zonevote_debug_enabled == true))
    AB_util.print("[zonevote] active=" .. tostring(AutoBand.zonevote_result_active == true)
        .. " started=" .. tostring(is_started)
        .. " hasVoted=" .. tostring(has_voted))
    AB_util.print("[zonevote] storedTitle=" .. zonevote_debug_text(AutoBand.zonevote_result_title)
        .. " currentTitle=" .. zonevote_debug_text(current_title)
        .. " titleErr=" .. zonevote_debug_text(title_err))
    AB_util.print("[zonevote] selected=" .. zonevote_debug_text(selected_choice)
        .. " pendingChoice=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_choice)
        .. " pendingPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_player_id)
        .. " confirmedPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_local_confirmed_player_id)
        .. " lastPlayerId=" .. zonevote_debug_text(AutoBand.zonevote_last_local_player_id)
        .. " localPlayerId=" .. zonevote_debug_text(local_player_id))
    AB_util.print("[zonevote] Player_Choices: " .. zonevote_debug_choice_counts_text())
end

local function cmd_zone_vote_debug(args)
    local mode = nil
    if type(args) == "table" and args[2] ~= nil then
        mode = string.lower(tostring(args[2]))
    end

    if mode == "on" or mode == "1" or mode == "true" then
        AutoBand.zonevote_debug_enabled = true
        AB_util.print("[zonevote] debug trace enabled")
    elseif mode == "off" or mode == "0" or mode == "false" then
        AutoBand.zonevote_debug_enabled = false
        AB_util.print("[zonevote] debug trace disabled")
    elseif mode ~= nil and mode ~= "state" and mode ~= "status" then
        AB_util.print("[zonevote] usage: /ab zonevote debug [on|off]")
    end

    zonevote_print_debug_state()
end

function AutoBand.zonevote_build_result_announcement_text()
    local lines = {
        AutoBand.zonevote_sanitize_alert_field(AutoBand.zonevote_result_title or AutoBand.get_zonevote_title()),
        "Results",
    }
    local answers = AutoBand.zonevote_result_answers or {}
    local counts = {}
    if type(ror_votewindow) == "table" and type(ror_votewindow.Player_Choices) == "table" then
        counts = ror_votewindow.Player_Choices
    end
    local pending_local_choice = nil
    if AutoBand.zonevote_local_choice_pending() == true then
        pending_local_choice = tonumber(AutoBand.zonevote_local_pending_choice)
    end

    local any_votes = false
    for index, answer in ipairs(answers) do
        local count = tonumber(counts[index]) or 0
        if pending_local_choice == index then
            count = count + 1
        end
        if count > 0 then
            lines[#lines + 1] = AutoBand.zonevote_sanitize_alert_field(answer and answer.Name or ("Choice " .. tostring(index))) .. " = " .. tostring(count)
            any_votes = true
        end
    end

    if any_votes ~= true then
        lines[#lines + 1] = "No votes"
    end

    return table.concat(lines, "\n")
end

local function zonevote_debug_result_text(text)
    local result = tostring(text or "")
    result = string.gsub(result, "\n", " | ")
    return result
end

function AutoBand.zonevote_build_choice_tooltip_text()
    local answers = AutoBand.zonevote_result_answers or {}
    if #answers == 0 then
        return nil
    end

    local lines = { "ZoneVote options" }
    for index, answer in ipairs(answers) do
        lines[#lines + 1] = tostring(index) .. ". " .. AutoBand.zonevote_sanitize_alert_field(answer and answer.Name or ("Choice " .. tostring(index)))
    end
    return table.concat(lines, "\n")
end

function AutoBand.zonevote_choice_combo_tooltip()
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        return
    end
    if type(Tooltips) ~= "table" or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end

    local text = AutoBand.zonevote_build_choice_tooltip_text()
    if text == nil or text == "" then
        return
    end

    local window_name = "RoR_Window_votewindow_ChoiceCombo"
    if SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name then
        window_name = SystemData.MouseOverWindow.name
    end
    local anchor = { Point = "left", RelativeTo = "CursorWindow", RelativePoint = "left", XOffset = 18, YOffset = 0 }
    Tooltips.CreateTextOnlyTooltip(window_name)
    Tooltips.SetTooltipText(1, 1, towstring(text))
    if type(Tooltips.SetTooltipColorDef) == "function" then
        Tooltips.SetTooltipColorDef(1, 1, Tooltips.COLOR_HEADING)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor)
end

function AutoBand.zonevote_choice_combo_tooltip_end()
    if type(Tooltips) ~= "table" or type(Tooltips.DestroyTooltip) ~= "function" then
        return
    end

    local window_name = "RoR_Window_votewindow_ChoiceCombo"
    if SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name then
        window_name = SystemData.MouseOverWindow.name
    end
    Tooltips.DestroyTooltip(window_name)
end

function AutoBand.zonevote_install_choice_tooltip_hook()
    if AutoBand.zonevote_choice_tooltip_hooked == true then
        return true
    end
    if type(WindowRegisterCoreEventHandler) ~= "function" then
        return false
    end
    if type(DoesWindowExist) == "function" and DoesWindowExist("RoR_Window_votewindow_ChoiceCombo") ~= true then
        return false
    end

    WindowRegisterCoreEventHandler("RoR_Window_votewindow_ChoiceCombo", "OnMouseOver", "AutoBand.zonevote_choice_combo_tooltip")
    WindowRegisterCoreEventHandler("RoR_Window_votewindow_ChoiceCombo", "OnMouseOverEnd", "AutoBand.zonevote_choice_combo_tooltip_end")
    AutoBand.zonevote_choice_tooltip_hooked = true
    return true
end

function AutoBand.zonevote_send_result_announcement()
    if AutoBand.zonevote_current_title_matches_result_table() ~= true then
        return false
    end
    if not (GameData and GameData.Player and GameData.Player.isGroupLeader == true) then
        return false
    end
    if type(SendChatText) ~= "function" or not (ChatSettings and ChatSettings.Channels and ChatSettings.Channels[0]) then
        return false
    end

    local text = AutoBand.zonevote_build_result_announcement_text()
    local wb_text = AutoBand.zonevote_build_result_warband_text()
    zonevote_debug("announcing results counts=" .. zonevote_debug_choice_counts_text()
        .. " pendingChoice=" .. zonevote_debug_text(AutoBand.zonevote_local_pending_choice)
        .. " text=" .. zonevote_debug_result_text(text))
    local wb_sent = AutoBand.zonevote_send_warband_message(wb_text)
    zonevote_trace("result wbSent=" .. tostring(wb_sent)
        .. " wbLen=" .. tostring(string.len(tostring(wb_text or "")))
        .. " abortLen=" .. tostring(string.len(tostring(text or ""))))
    AutoBand.zonevote_clear_result_state("announced results")
    SendChatText(L"]readycheck abort " .. towstring(text) .. L":4:0", ChatSettings.Channels[0].serverCmd)
    return true
end

function AutoBand.zonevote_install_local_choice_hooks()
    if type(ror_votewindow) ~= "table" then
        return false
    end

    if type(ror_votewindow.SelectChoice) == "function" and ror_votewindow.AutoBandZoneVoteSelectChoiceHooked ~= true then
        ror_votewindow.AutoBandZoneVoteOriginalSelectChoice = ror_votewindow.SelectChoice
        ror_votewindow.AutoBandZoneVoteSelectChoiceHooked = true
        ror_votewindow.SelectChoice = function()
            if type(AutoBand.zonevote_send_selected_choice) == "function"
                and AutoBand.zonevote_send_selected_choice() == true
            then
                return
            end
            return ror_votewindow.AutoBandZoneVoteOriginalSelectChoice()
        end
    end

    if type(ror_votewindow.AnswerVote) == "function" and ror_votewindow.AutoBandZoneVoteAnswerVoteHooked ~= true then
        ror_votewindow.AutoBandZoneVoteOriginalAnswerVote = ror_votewindow.AnswerVote
        ror_votewindow.AutoBandZoneVoteAnswerVoteHooked = true
        ror_votewindow.AnswerVote = function(player_id, choice)
            local count_before = AutoBand.zonevote_get_choice_count(choice)
            local total_before = AutoBand.zonevote_get_total_votes_casted()
            local result = ror_votewindow.AutoBandZoneVoteOriginalAnswerVote(player_id, choice)
            if type(AutoBand.zonevote_apply_answer_vote_fallback) == "function" then
                AutoBand.zonevote_apply_answer_vote_fallback(player_id, choice, count_before, total_before)
            end
            if type(AutoBand.zonevote_note_answer_vote) == "function" then
                AutoBand.zonevote_note_answer_vote(player_id, choice)
            end
            return result
        end
    end

    return true
end

function AutoBand.zonevote_install_result_close_hook()
    if type(ror_votewindow) ~= "table" or type(ror_votewindow.Close) ~= "function" then
        return false
    end
    if ror_votewindow.AutoBandZoneVoteCloseHooked == true then
        return true
    end

    ror_votewindow.AutoBandZoneVoteOriginalClose = ror_votewindow.Close
    ror_votewindow.AutoBandZoneVoteCloseHooked = true
    ror_votewindow.Close = function(stats)
        if type(AutoBand.zonevote_close_locally_after_warband_leave) == "function"
            and AutoBand.zonevote_close_locally_after_warband_leave() == true
        then
            return
        end
        if stats == true and type(AutoBand.zonevote_send_result_announcement) == "function" and AutoBand.zonevote_send_result_announcement() == true then
            return
        end
        local result = ror_votewindow.AutoBandZoneVoteOriginalClose(stats)
        -- the vote ended: ZoneVote may be available again in an open settings window
        if type(AutoBand.refresh_settings_actions) == "function" then
            AutoBand.refresh_settings_actions()
        end
        return result
    end
    return true
end

function AutoBand.get_zonevote_title()
    local race = nil
    if AutoBand.raceDetermined == true and AutoBand.race ~= nil then
        race = AutoBand.race
    elseif GameData and GameData.Player and GameData.Player.career
        and GameData.Player.career.line ~= nil
        and AB_const and type(AB_const.CAREERLINE_RACEMAP) == "table"
    then
        race = AB_const.CAREERLINE_RACEMAP[GameData.Player.career.line]
    end

    if race == AB_const.DWARFS then
        return "Grudge calls! Where to?"
    elseif race == AB_const.EMPIRE then
        return "For Sigmar, where to?"
    elseif race == AB_const.HIGHELVES then
        return "For Ulthuan, where to?"
    elseif race == AB_const.CHAOS then
        return "For Chaos, where to?"
    elseif race == AB_const.DARKELVES then
        return "For Naggaroth, where to?"
    elseif race == AB_const.GREENSKINS then
        return "WAAAGH! Where to?"
    end
    return "Zone"
end

function AutoBand.zonevote_get_zone_id_candidates(zone_id)
    local zone_num = tonumber(zone_id)
    local candidates = {}
    local seen = {}

    local function add_candidate(candidate)
        local candidate_num = tonumber(candidate)
        if candidate_num ~= nil and seen[candidate_num] ~= true then
            table.insert(candidates, candidate_num)
            seen[candidate_num] = true
        end
    end

    add_candidate(zone_num)
    local zone_names = zonevote_sor_zone_names()
    if type(zone_names) == "table" then
        local pair = zone_names[zone_num] or zone_names[tostring(zone_num)]
        if type(pair) == "table" then
            add_candidate(pair[1])
            add_candidate(pair[2])
        end
    end

    return candidates
end

function AutoBand.zonevote_zone_has_friendly_ranked_keep(zone_id)
    local legacy = zonevote_legacy_sor()
    if legacy and type(RoR_SoR.KEEP_IDs) ~= "table" then
        return false
    end
    if not legacy then
        local zone = zonevote_sor_zone(tonumber(zone_id))
        if not zone or zone.fort or zone.tier == 1 then return false end
    end

    local player_realm = AutoBand.zonevote_get_player_realm()
    if player_realm == nil then
        return false
    end

    local candidates = AutoBand.zonevote_get_zone_id_candidates(zone_id)
    for _, candidate_id in ipairs(candidates) do
        local keeps
        if legacy then
            keeps = RoR_SoR.KEEP_IDs[tostring(candidate_id)] or RoR_SoR.KEEP_IDs[candidate_id]
        else
            local zone = zonevote_sor_zone(candidate_id)
            keeps = zone and zone.keeps
        end
        if type(keeps) == "table" then
            for _, keep_data in pairs(keeps) do
                if type(keep_data) == "table" then
                    local owner = tonumber(keep_data.Owner or keep_data.owner or keep_data.Realm or keep_data.realm)
                    local rank = tonumber(keep_data.Rank or keep_data.rank or keep_data.KeepRank or keep_data.keepRank)
                    if owner == player_realm and rank ~= nil and rank >= 2 then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function AutoBand.get_zonevote_entries()
    local entries = {}
    local open_zones
    if zonevote_legacy_sor() then
        open_zones = RoR_SoR.OpenZones
    else
        open_zones = zonevote_sor_zones
        for zone_id in pairs(open_zones) do zonevote_sor_zone(zone_id) end
        if next(open_zones) == nil then
            return entries, "Active-zone data is unavailable. Wait for a campaign update, then retry."
        end
    end

    local seen = {}
    for zone_key, zone_value in pairs(open_zones) do
        local zone_id = AutoBand.zonevote_extract_open_zone_id(zone_key, zone_value)
        if zone_id ~= nil and seen[zone_id] ~= true and AutoBand.zonevote_is_vote_zone(zone_id) then
            local status = AutoBand.zonevote_get_zone_status(zone_id)
            local tier = 0
            if type(status) == "table" then
                tier = tonumber(status.Tier) or tonumber(status.tier) or 0
            end
            local zone_name, label_rule = AutoBand.zonevote_get_zone_name(zone_id)
            if tier == 0 and type(label_rule) == "table" and tonumber(label_rule.tier) ~= nil then
                tier = tonumber(label_rule.tier) or 0
            end
            table.insert(entries, {
                zone_id = zone_id,
                name = zone_name,
                tier = tier,
                siege_ready = AutoBand.zonevote_zone_has_friendly_ranked_keep(zone_id)
            })
            seen[zone_id] = true
        end
    end

    table.sort(entries, function(left, right)
        local left_tier = tonumber(left.tier) or 0
        local right_tier = tonumber(right.tier) or 0
        if left_tier ~= right_tier then
            return left_tier > right_tier
        end
        return tostring(left.name or "") < tostring(right.name or "")
    end)

    return entries, nil
end

function AutoBand.build_zonevote_ready_table(entries, timer_seconds)
    local config = AutoBand.zone_vote_config or {}
    local timer = tonumber(timer_seconds) or tonumber(config.default_timer_seconds) or 60
    timer = math.floor(timer)
    if timer < 5 then
        timer = 5
    elseif timer > 300 then
        timer = 300
    end

    local answer_sounds = config.answer_sounds or {}
    local answer_colors = config.answer_colors or {}
    local answers = {}
    local answer_index = 0
    local function add_answer(name)
        answer_index = answer_index + 1
        local color = answer_colors[1] or { r = 255, g = 255, b = 255 }
        if #answer_colors > 0 then
            color = answer_colors[((answer_index - 1) % #answer_colors) + 1]
        end
        local sound = 216
        if #answer_sounds > 0 then
            sound = answer_sounds[((answer_index - 1) % #answer_sounds) + 1]
        end
        answers[answer_index] = {
            Name = tostring(name or ("Zone " .. tostring(answer_index))),
            Sound = sound or 216,
            Color = { r = color.r, g = color.g, b = color.b },
        }
    end

    for _, entry in ipairs(entries or {}) do
        local base_name = tostring(entry.name or ("Zone " .. tostring(entry.zone_id or "?")))
        add_answer(base_name)
        if entry.siege_ready == true then
            add_answer(AutoBand.zonevote_get_ram_icon_token() .. base_name)
        end
    end

    return {
        Title = AutoBand.get_zonevote_title(),
        Timer = timer,
        Sound = tonumber(config.prompt_sound) or 0,
        Answers = answers,
    }
end

function AutoBand.cmd_zone_vote(args)
    if type(args) == "table" and args[1] ~= nil and string.lower(tostring(args[1])) == "debug" then
        cmd_zone_vote_debug(args)
        return
    end

    if not AutoBand.require_warband_features_enabled("starting a zone vote") then
        return
    end

    if not (AutoBand.is_wb_leader() or AutoBand.is_assistant() or AutoBand.debugon) then
        AB_util.print("[error] You need to be a wb leader or assistant")
        return
    end

    if type(ror_votewindow) ~= "table" or type(ror_votewindow.CreateCheck) ~= "function" then
        AB_util.print("[Error] Readycheck API unavailable. Update or restart the RoR client, then retry.")
        return
    end

    if ror_votewindow.IsVoteStarted == true then
        AB_util.print("[Error] A readycheck or vote is already running.")
        return
    end

    local entries, err = AutoBand.get_zonevote_entries()
    if err ~= nil then
        AB_util.print("[Error] " .. tostring(err))
        return
    end
    if #entries == 0 then
        AB_util.print("[Error] No active RvR zones found.")
        return
    end

    local timer = tonumber((AutoBand.zone_vote_config or {}).default_timer_seconds) or 60
    if args and args[1] ~= nil then
        timer = tonumber(args[1]) or timer
    end

    local ready_table = AutoBand.build_zonevote_ready_table(entries, timer)
    zonevote_trace("start built entries=" .. tostring(#entries)
        .. " answers=" .. tostring(#(ready_table.Answers or {}))
        .. " timer=" .. tostring(ready_table.Timer)
        .. " title=" .. zonevote_debug_text(ready_table.Title))
    AutoBand.zonevote_install_result_close_hook()
    AutoBand.zonevote_install_local_choice_hooks()
    AutoBand.zonevote_install_choice_tooltip_hook()
    AutoBand.zonevote_remember_result_table(ready_table)
    ror_votewindow.CreateCheck(ready_table)
    zonevote_trace("after CreateCheck exposed IsVoteStarted="
        .. zonevote_debug_text(ror_votewindow.IsVoteStarted)
        .. " total=" .. zonevote_debug_text(ror_votewindow.Total_Players)
        .. " cast=" .. zonevote_debug_text(ror_votewindow.Total_Votes_Casted))
    local start_scheduled = AutoBand.zonevote_schedule_start_warband_message(AutoBand.zonevote_build_start_warband_text(ready_table))
    zonevote_trace("start scheduled=" .. tostring(start_scheduled))

    local names = {}
    for i, answer in ipairs(ready_table.Answers or {}) do
        names[i] = tostring(answer.Name or ("Choice " .. tostring(i)))
    end
    AB_util.print("Zone vote started for " .. tostring(#entries) .. " active zone(s): " .. table.concat(names, ", "))
end

local function zonevote_register_commands(cmd_table)
    if type(cmd_table) ~= "table" then
        return
    end

    cmd_table["zonevote"] = {
        f = AutoBand.cmd_zone_vote,
        help = "[seconds|debug] start active-zone vote or print vote debug state",
        print_id = 51.7
    }
    cmd_table["zv"] = { f = AutoBand.cmd_zone_vote, help = "" }
end

AutoBand.command_definition_hooks = AutoBand.command_definition_hooks or {}
if AutoBand.zonevote_command_registration_hook_installed ~= true then
    table.insert(AutoBand.command_definition_hooks, function(cmd_table)
        zonevote_register_commands(cmd_table)
    end)
    AutoBand.zonevote_command_registration_hook_installed = true
end
