-- AB_scoreboard.lua
-- Scoreboard probe/report helpers, rendering, and slash-command registration.

AutoBand.ScoreboardProbe = AutoBand.ScoreboardProbe or {}
local ScoreboardProbe = AutoBand.ScoreboardProbe

-- Keep wording/icons/sample data together so scoreboard iteration stays inside
-- this module instead of leaking presentation-only edits back into AutoBand.lua.
ScoreboardProbe.command_help = "[sample] [wb|warband|popup] preview current WB top 3 and confirm sending it to /wb"
ScoreboardProbe.command_print_id = 82.25
ScoreboardProbe.stat_definitions = {
    { label = "Damage", stat_key = "damagedealt", secondary_stat_key = "killDamage", secondary_mode = "damage_kill", prefix_icon = "<icon41002>" },
    { label = "Protection", stat_key = "protection", prefix_icon = "<icon41000>" },
    { label = "Healing", stat_key = "healingdealt", secondary_stat_key = "resurrectionsDone", secondary_mode = "resurrections", prefix_icon = "<icon41005>" }
}
ScoreboardProbe.header_themes = {
    [AB_const.DWARFS] = { subject = "The Karaz Throng", tail = "marks this throng's champions", tally_subject = "throng", kill_singular = "kill", kill_plural = "kills" },
    [AB_const.EMPIRE] = { subject = "Sigmar's Host", tail = "hails this warband's champions", tally_subject = "warband", kill_singular = "kill", kill_plural = "kills" },
    [AB_const.HIGHELVES] = { subject = "The Phoenix Host", tail = "hails this warhost's champions", tally_subject = "warhost", kill_singular = "kill", kill_plural = "kills" },
    [AB_const.CHAOS] = { subject = "The Blood Host", tail = "claims this warhost's champions", tally_subject = "warhost", kill_singular = "skull", kill_plural = "skulls" },
    [AB_const.DARKELVES] = { subject = "Naggaroth's Host", tail = "claims this raiding host's champions", tally_subject = "raiding host", kill_singular = "trophy", kill_plural = "trophies" },
    [AB_const.GREENSKINS] = { subject = "Da WAAAGH", tail = "shows who leads dis WAAAGH", tally_subject = "WAAAGH", kill_singular = "krump", kill_plural = "krumps" },
    ["default"] = { subject = "These champions", tail = "stand foremost", tally_subject = "warband", kill_singular = "kill", kill_plural = "kills" }
}
ScoreboardProbe.sample_rows = {
    { name = "Jappi", role = AB_const.RDPS, career_icon = "<icon20194>", groupkills = 42, damagedealt = 468000, killDamage = 324000, protection = 0, healingdealt = 0, resurrectionsDone = 0 },
    { name = "Lethyel", role = AB_const.TANK, career_icon = "<icon20190>", groupkills = 17, damagedealt = 115500, killDamage = 81000, protection = 24000, healingdealt = 0, resurrectionsDone = 0 },
    { name = "Jaazz", role = AB_const.RDPS, career_icon = "<icon20194>", groupkills = 9, damagedealt = 57000, killDamage = 0, protection = 0, healingdealt = 0, resurrectionsDone = 0 },
    { name = "Hamlar", role = AB_const.RDPS, career_icon = "<icon20187>", groupkills = 3, damagedealt = 0, killDamage = 0, protection = 25500, healingdealt = 0, resurrectionsDone = 0 },
    { name = "Haldrin", role = AB_const.HEALER, career_icon = "<icon20199>", groupkills = 6, damagedealt = 0, killDamage = 0, protection = 16500, healingdealt = 139500, resurrectionsDone = 8 },
    { name = "Clyde", role = AB_const.HEALER, career_icon = "<icon20199>", groupkills = 2, damagedealt = 0, killDamage = 0, protection = 0, healingdealt = 93000, resurrectionsDone = 0 },
    { name = "Mrswinter", role = AB_const.HEALER, career_icon = "<icon20199>", groupkills = 1, damagedealt = 0, killDamage = 0, protection = 0, healingdealt = 63000, resurrectionsDone = 2 }
}
ScoreboardProbe.role_colors = {
    [AB_const.TANK] = { 150, 190, 255 },
    [AB_const.HEALER] = { 190, 255, 100 },
    [AB_const.MDPS] = { 255, 190, 100 },
    [AB_const.RDPS] = { 255, 190, 100 }
}

-- Match scoreboard rows against the same normalized player keys used elsewhere
-- in AutoBand after stripping any grammar suffixes the client may add.
function ScoreboardProbe.NormalizeName(name_raw)
    local normalized_input = name_raw
    if WStringsRemoveGrammar then
        local ok_grammar, grammarless = pcall(WStringsRemoveGrammar, normalized_input)
        if ok_grammar and grammarless ~= nil then
            normalized_input = grammarless
        end
    end
    return AutoBand.normalize_wb_player_name(normalized_input)
end

function ScoreboardProbe.FormatNumberWithCommas(value)
    local number_value = tonumber(value) or 0
    number_value = math.floor(number_value)
    local sign = ""
    if number_value < 0 then
        sign = "-"
        number_value = math.abs(number_value)
    end

    local digits = tostring(number_value)
    local first_len = #digits % 3
    if first_len == 0 then
        first_len = 3
    end

    local parts = {}
    parts[#parts + 1] = string.sub(digits, 1, first_len)
    local idx = first_len + 1
    while idx <= #digits do
        parts[#parts + 1] = string.sub(digits, idx, idx + 2)
        idx = idx + 3
    end
    return sign .. table.concat(parts, ",")
end

function ScoreboardProbe.FormatStatValue(value)
    local number_value = tonumber(value) or 0
    local abs_value = math.abs(number_value)
    local sign = ""
    if number_value < 0 then
        sign = "-"
    end

    local function format_compact(divisor, suffix)
        local scaled_tenths = math.floor((abs_value * 10) / divisor + 0.5)
        local whole = math.floor(scaled_tenths / 10)
        local tenth = scaled_tenths % 10
        if tenth == 0 then
            return sign .. tostring(whole) .. suffix
        end
        return sign .. tostring(whole) .. "." .. tostring(tenth) .. suffix
    end

    if abs_value >= 1000000 then
        return format_compact(1000000, "m")
    elseif abs_value >= 1000 then
        return format_compact(1000, "k")
    end

    return ScoreboardProbe.FormatNumberWithCommas(number_value)
end

function ScoreboardProbe.MutedText(text)
    local color = AB_const.COLOR_SILVER or { 192, 192, 192 }
    local r = color[1] or 192
    local g = color[2] or 192
    local b = color[3] or 192

    return string.format(
        "<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">",
        r, g, b, tostring(text or "")
    )
end

function ScoreboardProbe.ResurrectionsText(count_value)
    local count_number = tonumber(count_value) or 0
    count_number = math.floor(count_number)
    if count_number <= 0 then
        return ""
    end

    local suffix = " resses"
    if count_number == 1 then
        suffix = " res"
    end

    return ScoreboardProbe.MutedText("(" .. tostring(count_number) .. suffix .. ")")
end

function ScoreboardProbe.GetRoleColor(role_key)
    return ScoreboardProbe.role_colors[role_key]
end

function ScoreboardProbe.GetKillWord(theme, count_value)
    local count_number = tonumber(count_value) or 0
    if count_number == 1 then
        return theme.kill_singular or "kill"
    end
    return theme.kill_plural or "kills"
end

function ScoreboardProbe.BuildPlayerLink(player_name, rgb_override)
    local name_str = tostring(player_name or "")
    if name_str == "" then
        return ""
    end

    local lead_color_name = (AutoBand.saved and AutoBand.saved.lead_color_name) or AB_const.DEFAULT_LEAD_COLOR_NAME
    local rgb = rgb_override or AB_const.AVAILABLE_COLORS[lead_color_name] or AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME] or AB_const.COLOR_WHITE
    local r = rgb[1] or 255
    local g = rgb[2] or 255
    local b = rgb[3] or 255
    local display_name = "@" .. name_str

    return string.format(
        "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
        name_str, r, g, b, display_name
    )
end

function ScoreboardProbe.BuildGuildLinkRaw()
    if not AutoBand.GetCurrentGuildInfo then
        return nil
    end

    local guild_info = AutoBand.GetCurrentGuildInfo()
    if type(guild_info) ~= "table" or not guild_info.id or not guild_info.name then
        return nil
    end

    local prefix_color_name = (AutoBand.saved and AutoBand.saved.prefix_color_name) or AB_const.DEFAULT_PREFIX_COLOR_NAME
    local color_rgb = AB_const.AVAILABLE_COLORS[prefix_color_name] or AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_PREFIX_COLOR_NAME] or AB_const.COLOR_WHITE
    local r = color_rgb[1] or 255
    local g = color_rgb[2] or 255
    local b = color_rgb[3] or 255

    return string.format(
        "<LINK data=\"GUILD:%s\" text=\"%s\" color=\"%d,%d,%d\">",
        tostring(guild_info.id),
        tostring(guild_info.name),
        r, g, b
    )
end

function ScoreboardProbe.ResolveCareerIcon(career_line, scoreboard_career_icon)
    if career_line and AB_const.CAREERLINE_ICON_MAP and AB_const.CAREERLINE_ICON_MAP[career_line] then
        return AB_const.CAREERLINE_ICON_MAP[career_line]
    end

    local icon_id = tonumber(scoreboard_career_icon)
    if icon_id and icon_id > 0 then
        return "<icon" .. tostring(icon_id) .. ">"
    end

    return ""
end

function ScoreboardProbe.BuildHeaderText(rows)
    local theme = nil
    if AutoBand.raceDetermined and AutoBand.race then
        theme = ScoreboardProbe.header_themes[AutoBand.race]
    end
    if type(theme) ~= "table" then
        theme = ScoreboardProbe.header_themes["default"]
    end

    local subject = theme.subject or "These champions"
    local guild_link_raw = ScoreboardProbe.BuildGuildLinkRaw()
    if guild_link_raw and guild_link_raw ~= "" then
        subject = subject .. " & " .. guild_link_raw
    end

    local tail = theme.tail or "stand foremost"
    -- Avoid title-style punctuation here so the header reads as one sentence.
    tail = string.gsub(tail, "%s*:%s*$", "")
    local tally_subject = theme.tally_subject or "warband"
    local warband_kills = 0
    if type(rows) == "table" then
        -- RoRGroupScoreboard has per-player rows only, so the highest current
        -- group-kill count is the best lightweight cue for the warband header.
        for i = 1, #rows do
            local kill_count = tonumber(rows[i].groupkills) or 0
            if kill_count > warband_kills then
                warband_kills = kill_count
            end
        end
    end
    return subject .. " " .. tail .. " with the " .. tally_subject .. " at " .. tostring(warband_kills) .. " " .. ScoreboardProbe.GetKillWord(theme, warband_kills) .. "."
end

function ScoreboardProbe.BuildLiveWb()
    local raw_wbdata = GetBattlegroupMemberData and GetBattlegroupMemberData() or nil
    if type(raw_wbdata) ~= "table" then
        return nil, "Not in an active warband."
    end

    local wb_obj = AB_wb:new()
    local ok_load, err = pcall(function()
        wb_obj:load_from_wbdata(raw_wbdata)
    end)
    if not ok_load then
        return nil, "[Error] Failed to read current warband roster: " .. tostring(err)
    end

    if tonumber(wb_obj.player_count) == nil or wb_obj.player_count <= 0 then
        return nil, "Not in an active warband."
    end

    return wb_obj, nil
end

function ScoreboardProbe.BuildSampleRows()
    local rows = {}
    for i = 1, #ScoreboardProbe.sample_rows do
        local sample_row = ScoreboardProbe.sample_rows[i]
        rows[#rows + 1] = {
            name = sample_row.name,
            player_link = ScoreboardProbe.BuildPlayerLink(sample_row.name, ScoreboardProbe.GetRoleColor(sample_row.role)),
            career_icon = sample_row.career_icon or "",
            groupkills = tonumber(sample_row.groupkills) or 0,
            damagedealt = tonumber(sample_row.damagedealt) or 0,
            killDamage = tonumber(sample_row.killDamage) or 0,
            protection = tonumber(sample_row.protection) or 0,
            healingdealt = tonumber(sample_row.healingdealt) or 0,
            resurrectionsDone = tonumber(sample_row.resurrectionsDone) or 0
        }
    end
    return rows
end

function ScoreboardProbe.BuildRows(wb_obj)
    local raw = RoRGroupScoreboard and RoRGroupScoreboard.playersDataRaw
    if type(raw) ~= "table" then
        return nil, "RoRGroupScoreboard data not available."
    end

    local wb_members_by_key = {}
    local wb_member_count = 0
    wb_obj:foreach_player(function(_gid, player)
        if not player or not player.name then
            return
        end
        local key, display_name = ScoreboardProbe.NormalizeName(player.name)
        if not key or not display_name or display_name == "" then
            return
        end
        if not wb_members_by_key[key] then
            wb_member_count = wb_member_count + 1
        end
        wb_members_by_key[key] = {
            display_name = display_name,
            career_line = player.careerLine,
            role = player.role
        }
    end)

    if wb_member_count <= 0 then
        return nil, "Current warband roster is empty."
    end

    -- The raw scoreboard table can contain stale or out-of-band rows. Only keep
    -- entries that join cleanly to the current live warband snapshot.
    local rows = {}
    for _, score_row in pairs(raw) do
        if score_row and score_row.name then
            local key = ScoreboardProbe.NormalizeName(score_row.name)
            local live_member = key and wb_members_by_key[key] or nil
            if live_member then
                rows[#rows + 1] = {
                    name = live_member.display_name,
                    player_link = ScoreboardProbe.BuildPlayerLink(live_member.display_name, ScoreboardProbe.GetRoleColor(live_member.role)),
                    career_icon = ScoreboardProbe.ResolveCareerIcon(live_member.career_line, score_row.careerIcon),
                    groupkills = tonumber(score_row.groupkills) or 0,
                    damagedealt = tonumber(score_row.damagedealt) or 0,
                    killDamage = tonumber(score_row.killDamage) or 0,
                    protection = tonumber(score_row.protection) or 0,
                    healingdealt = tonumber(score_row.healingdealt) or 0,
                    resurrectionsDone = tonumber(score_row.resurrectionsDone) or 0
                }
            end
        end
    end

    if #rows <= 0 then
        return nil, "No current warband members matched RoRGroupScoreboard rows."
    end

    return rows, nil
end

function ScoreboardProbe.BuildTopLine(rows, stat_label, stat_key, secondary_stat_key, secondary_mode, prefix_icon)
    local sortable = {}
    for i = 1, #rows do
        sortable[i] = rows[i]
    end

    table.sort(sortable, function(a, b)
        local a_value = tonumber(a[stat_key]) or 0
        local b_value = tonumber(b[stat_key]) or 0
        if a_value ~= b_value then
            return a_value > b_value
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    local top_parts = {}
    local max_entries = math.min(3, #sortable)
    local top_value = tonumber(sortable[1] and sortable[1][stat_key]) or 0
    for i = 1, max_entries do
        local row = sortable[i]
        local row_value = tonumber(row[stat_key]) or 0
        -- Trim weak tails so one tiny row does not make the summary line noisy.
        if i > 1 and top_value > 0 and row_value < (top_value * 0.1) then
            break
        end
        local icon = row.career_icon or ""
        local link = row.player_link or tostring(row.name)
        local icon_prefix = ""
        if icon ~= "" then
            icon_prefix = icon .. " "
        end
        local value_text = ScoreboardProbe.FormatStatValue(row_value)
        if secondary_stat_key and secondary_mode == "damage_kill" then
            local secondary_value = tonumber(row[secondary_stat_key]) or 0
            local kill_pct = 0
            if row_value > 0 then
                kill_pct = math.floor(((secondary_value * 100) / row_value) + 0.5)
            end
            value_text = value_text .. " / " .. ScoreboardProbe.MutedText(ScoreboardProbe.FormatStatValue(secondary_value)) .. " " .. ScoreboardProbe.MutedText("(" .. tostring(kill_pct) .. "%)")
        elseif secondary_stat_key and secondary_mode == "resurrections" then
            local rez_text = ScoreboardProbe.ResurrectionsText(row[secondary_stat_key])
            if rez_text ~= "" then
                value_text = value_text .. " " .. rez_text
            end
        end
        local place_prefix = tostring(i) .. ")"
        top_parts[#top_parts + 1] = place_prefix .. " " .. icon_prefix .. link .. " " .. value_text
    end

    local label_prefix = prefix_icon or ""
    if label_prefix ~= "" then
        label_prefix = label_prefix .. " "
    end

    return label_prefix .. stat_label .. ": " .. table.concat(top_parts, " - ")
end

function ScoreboardProbe.BuildReportLines(rows)
    local lines = {}
    lines[#lines + 1] = ScoreboardProbe.BuildHeaderText(rows)
    for _, stat_def in ipairs(ScoreboardProbe.stat_definitions) do
        lines[#lines + 1] = ScoreboardProbe.BuildTopLine(
            rows,
            stat_def.label,
            stat_def.stat_key,
            stat_def.secondary_stat_key,
            stat_def.secondary_mode,
            stat_def.prefix_icon
        )
    end
    return lines
end

function ScoreboardProbe.BuildBroadcastCommands(lines)
    local commands = {}
    if type(lines) ~= "table" then
        return commands
    end
    for i = 1, #lines do
        commands[#commands + 1] = "/wb " .. tostring(lines[i] or "")
    end
    return commands
end

function ScoreboardProbe.BuildPreviewLines(commands)
    local lines = {}
    if type(commands) ~= "table" then
        return lines
    end
    for i = 1, #commands do
        local line = tostring(commands[i] or "")
        line = string.gsub(line, "^/wb%s+", "")
        line = string.gsub(line, '%<LINK[^>]-text="([^"]*)"[^>]*%>', "%1")
        lines[#lines + 1] = line
    end
    return lines
end

function ScoreboardProbe.CanSendToWarband()
    if type(AutoBand) ~= "table" then
        return false
    end

    if type(AutoBand.is_wb_leader) == "function" then
        local ok_leader, is_leader = pcall(AutoBand.is_wb_leader)
        if ok_leader and is_leader == true then
            return true
        end
    end

    if type(AutoBand.is_assistant) == "function" then
        local ok_assistant, is_assistant = pcall(AutoBand.is_assistant)
        if ok_assistant and is_assistant == true then
            return true
        end
    end

    return false
end

function ScoreboardProbe.BuildRowsForOptions(options)
    if type(options) ~= "table" then
        options = {}
    end

    if options.use_sample then
        return ScoreboardProbe.BuildSampleRows(), nil
    end

    local wb_obj, wb_err = ScoreboardProbe.BuildLiveWb()
    if not wb_obj then
        return nil, wb_err or "Not in an active warband."
    end

    local rows, rows_err = ScoreboardProbe.BuildRows(wb_obj)
    if not rows then
        return nil, rows_err or "No RoRGroupScoreboard data for current warband members."
    end

    return rows, nil
end

function ScoreboardProbe.BuildBroadcastCommandsForArgs(args)
    local options = ScoreboardProbe.ParseArgs(args)
    if options.invalid_arg ~= nil then
        return nil, "Usage: /ab scoreboard [sample] [wb|warband|popup]", "usage"
    end

    local rows, rows_err = ScoreboardProbe.BuildRowsForOptions(options)
    if not rows then
        return nil, rows_err, "unavailable"
    end

    local lines = ScoreboardProbe.BuildReportLines(rows)
    return ScoreboardProbe.BuildBroadcastCommands(lines), nil, nil
end

function ScoreboardProbe.BuildTooltipPreviewText(args)
    local commands, err = ScoreboardProbe.BuildBroadcastCommandsForArgs(args)
    if type(commands) ~= "table" or #commands == 0 then
        return "Scoreboard preview unavailable:\n" .. tostring(err or "No scoreboard output available.")
    end

    local lines = {}
    if ScoreboardProbe.CanSendToWarband() then
        lines[#lines + 1] = "Scoreboard preview:"
    else
        lines[#lines + 1] = "Scoreboard preview (local only):"
        lines[#lines + 1] = "Only WB leader/assistant can send to /wb."
    end

    local preview_lines = ScoreboardProbe.BuildPreviewLines(commands)
    for i = 1, #preview_lines do
        lines[#lines + 1] = preview_lines[i]
    end
    return table.concat(lines, "\n")
end

function ScoreboardProbe.ShowBroadcastCommandsPreview(commands)
    if type(AutoBandWindowScoreboardPreview) == "table"
        and type(AutoBandWindowScoreboardPreview.ShowModal) == "function"
    then
        local ok_show, shown = pcall(AutoBandWindowScoreboardPreview.ShowModal, commands)
        if ok_show and shown == true then
            return true
        end
    end

    AB_util.print("[Error] Scoreboard preview window is unavailable. Try /reloadui.")
    return false
end

function ScoreboardProbe.ParseArgs(args)
    local options = {
        use_sample = false,
        invalid_arg = nil
    }

    if type(args) ~= "table" then
        return options
    end

    for i = 1, #args do
        local raw_arg = tostring(args[i] or "")
        local arg = string.lower(raw_arg)
        if arg == "sample" then
            options.use_sample = true
        elseif raw_arg ~= "" and arg ~= "wb" and arg ~= "warband" and arg ~= "popup" then
            options.invalid_arg = raw_arg
            break
        end
    end

    return options
end

function ScoreboardProbe.PrintUsage()
    AB_util.print("Usage: /ab scoreboard [sample] [wb|warband|popup]")
end

function ScoreboardProbe.RunCommand(args)
    local commands, err, reason = ScoreboardProbe.BuildBroadcastCommandsForArgs(args)
    if not commands then
        if reason ~= "usage" and type(err) == "string" and err ~= "" then
            AB_util.print(err)
            return
        end
        ScoreboardProbe.PrintUsage()
        return
    end

    ScoreboardProbe.ShowBroadcastCommandsPreview(commands)
end

function AutoBand.cmd_scoreboard_probe(args)
    ScoreboardProbe.RunCommand(args)
end

function AutoBand.cmd_scoreboard_probe_wb(args)
    AutoBand.cmd_scoreboard_probe(args)
end

function AutoBand.build_scoreboard_preview_text(args)
    return ScoreboardProbe.BuildTooltipPreviewText(args)
end

function ScoreboardProbe.RegisterCommands(cmd_table)
    if type(cmd_table) ~= "table" then
        return
    end

    cmd_table["scoreboard"] = {
        f = AutoBand.cmd_scoreboard_probe,
        help = ScoreboardProbe.command_help,
        print_id = ScoreboardProbe.command_print_id
    }
    cmd_table["wbscore"] = {
        f = AutoBand.cmd_scoreboard_probe_wb,
        help = ""
    }
end

AutoBand.command_definition_hooks = AutoBand.command_definition_hooks or {}
if ScoreboardProbe.command_registration_hook_installed ~= true then
    table.insert(AutoBand.command_definition_hooks, function(cmd_table)
        ScoreboardProbe.RegisterCommands(cmd_table)
    end)
    ScoreboardProbe.command_registration_hook_installed = true
end
