-- AutoBand Tools tab (default): Manage Players, Manual Search for Players (with
-- advertising options and auto-search), and Organize, in the original order.
AutoBandWindowTools = {}

AutoBandWindowTools.name = "AutoBandWindowToolsTab"

local C = AutoBandWindowCommon
local P = AutoBandWindowTools.name
local refreshing = false

AutoBandWindowTools.tools_data = {
    [AB_const.KICK_OFFLINE] = { button = "KickOfflineCheckBox", label = "KickOfflineLabel", func_kick = AutoBand.cmd_kick_toofar, func_print = AutoBand.cmd_list_offline },
    [AB_const.KICK_ZONE] = { button = "KickZoneCheckBox", label = "KickZoneLabel", func_kick = AutoBand.cmd_kick_notinzone, func_print = AutoBand.cmd_list_zone },
    [AB_const.KICK_RANK] = { button = "KickRankCheckBox", label = "KickRankLabel", func_kick = AutoBand.cmd_kick_rank, func_print = AutoBand.cmd_list_rank },
}

-- Purpose combo: "(none)" first, then purposes sorted by display name.
AutoBandWindowTools.purpose_keys = {}

local function search_channel_joined(channel_name)
    if type(AB_util) ~= "table" or type(AB_util.get_chat_channel) ~= "function" then
        return true
    end
    if channel_name == "LFG" then
        return AB_util.get_chat_channel(AB_util.LFG_CHANNEL_KEY) ~= nil
    end
    return AB_util.get_chat_channel(AB_util.REGION_CHANNEL_KEY) ~= nil
end

local function warband_enabled()
    return AutoBand.is_warband_enabled() == true
end

local function is_leader()
    return AutoBand.is_wb_leader() == true
end

local function is_leader_or_assistant()
    return AutoBand.is_wb_leader() == true or AutoBand.is_assistant() == true or AutoBand.debugon == true
end

local function in_warband()
    if type(AutoBand.is_in_active_warband) == "function" then
        return AutoBand.is_in_active_warband() == true
    end
    return AutoBand.inWarband == true
end

local function kick_filters(create)
    if type(AutoBand.saved.kick_func_enabled) ~= "table" then
        if not create then
            return {}
        end
        AutoBand.saved.kick_func_enabled = {}
    end
    return AutoBand.saved.kick_func_enabled
end

local function any_kick_filter()
    for fid in pairs(AutoBandWindowTools.tools_data) do
        if kick_filters()[fid] == true then
            return true
        end
    end
    return false
end

local WB_OFF = "Warband features are off."

-- Selected manual-search channels; greyed (not joined) channels are skipped.
local function selected_search_channels()
    local args = {}
    local skipped = {}
    local function add(box, arg, channel)
        if ButtonGetPressedFlag(P .. box) ~= true then
            return
        end
        if channel and not search_channel_joined(channel) then
            skipped[#skipped + 1] = C.channel_reason(channel)
            return
        end
        args[#args + 1] = arg
    end
    add("SearchRoleChan1CheckBox", "region", "Region")
    add("SearchRoleChanT4CheckBox", "t4", nil)
    add("SearchRoleChan5CheckBox", "lfg", "LFG")
    return args, skipped
end

-- Cheap availability per action (no previews, reports, CSV or queue work). Each one
-- mirrors the permission the core command applies, so a disabled button and the
-- command agree; the handlers re-check before doing anything.
local ACTIONS = {}
-- Purpose can always be browsed; this predicate controls applying a choice.
function ACTIONS.PurposeComboBox()
    if not warband_enabled() then return false, WB_OFF end
    if not in_warband() or not is_leader() then return false, "Requires the warband leader." end
    return true
end
ACTIONS.PurposeLabel = ACTIONS.PurposeComboBox

function ACTIONS.FormWarbandButton()
    -- /ab form turns Warband features back on first, so in a warband with them off
    -- the button stays available as the documented re-enable shortcut.
    if in_warband() and warband_enabled() then
        return false, "Already in a warband."
    end
    local party_active = type(AutoBand.is_party_active_safe) == "function" and AutoBand.is_party_active_safe() == true
    if party_active and not (GameData and GameData.Player and GameData.Player.isGroupLeader == true) then
        return false, "Party leader only."
    end
    return true
end

function ACTIONS.OrganizeButton()
    if not warband_enabled() then
        return false, WB_OFF
    end
    if not is_leader_or_assistant() then
        return false, "Leader or assistant only."
    end
    return true
end

-- Right-click: distance organize is leader-only (assistants get normal Organize).
function ACTIONS.OrganizeDistance()
    local ok, reason = ACTIONS.OrganizeButton()
    if not ok then
        return false, reason
    end
    if not (is_leader() or AutoBand.debugon == true) then
        return false, "Distance organize is leader only."
    end
    return true
end

-- Local preview works for everyone; only sending to /wb needs leader/assistant.
function ACTIONS.ScoreboardButton()
    if type(RoRGroupScoreboard) ~= "table" or type(RoRGroupScoreboard.playersDataRaw) ~= "table" then
        return false, "No scoreboard data."
    end
    if not in_warband() then
        return false, "Not in a warband."
    end
    return true
end

function ACTIONS.ZoneVoteButton()
    if not warband_enabled() then
        return false, WB_OFF
    end
    if not is_leader_or_assistant() then
        return false, "Leader or assistant only."
    end
    if type(ror_votewindow) ~= "table" or type(ror_votewindow.CreateCheck) ~= "function" then
        return false, "Vote window unavailable."
    end
    if ror_votewindow.IsVoteStarted == true then
        return false, "A vote is running."
    end
    return true
end

-- Leaders and members alike may search (as /ab searchroles).
function ACTIONS.SearchRoleButton()
    if not warband_enabled() then
        return false, WB_OFF
    end
    local args, skipped = selected_search_channels()
    if #args == 0 then
        if #skipped > 0 then
            return false, table.concat(skipped, "\n")
        end
        return false, "Check a channel."
    end
    if not in_warband() and AutoBand.saved.autoform_search_enabled ~= true then
        return false, "Not in a warband (or turn on Autoform)."
    end
    return true
end

function ACTIONS.PrintButton()
    if not any_kick_filter() then
        return false, "Check a kick option."
    end
    return true
end

function ACTIONS.KickButton()
    if not warband_enabled() then
        return false, WB_OFF
    end
    if not is_leader() then
        return false, "Leader only."
    end
    if not any_kick_filter() then
        return false, "Check a kick option."
    end
    return true
end


local GATED_BUTTONS = { "FormWarbandButton", "OrganizeButton", "ScoreboardButton", "ZoneVoteButton", "SearchRoleButton",
    "PrintButton", "KickButton" }

local PURPOSE_TEXT_STATES = { 0, 1, 3, 4 } -- NORMAL, PRESSED, HIGHLIGHTED, PRESSED_HIGHLIGHTED
local PURPOSE_TEXT_NORMAL = { 255, 255, 255 }
local PURPOSE_TEXT_HIGHLIGHT = { 250, 213, 63 }
local PURPOSE_TEXT_READONLY = { 195, 200, 205 }

local function refresh_purpose_text(editable)
    local button = P .. "PurposeComboBoxSelectedButton"
    if type(ButtonSetTextColor) ~= "function" or type(DoesWindowExist) ~= "function" or not DoesWindowExist(button) then
        return
    end
    for _, state in ipairs(PURPOSE_TEXT_STATES) do
        local rgb = PURPOSE_TEXT_READONLY
        if editable then rgb = state == 0 and PURPOSE_TEXT_NORMAL or PURPOSE_TEXT_HIGHLIGHT end
        ButtonSetTextColor(button, state, rgb[1], rgb[2], rgb[3])
    end
end

-- Disabled buttons keep a transparent overlay so the reason stays hoverable.
function AutoBandWindowTools.RefreshActionButtons()
    for _, button in ipairs(GATED_BUTTONS) do
        local ok = ACTIONS[button]()
        ButtonSetDisabledFlag(P .. button, ok ~= true)
        WindowSetShowing(P .. button .. "DisabledHover", ok ~= true)
    end
    local purpose_editable = ACTIONS.PurposeComboBox() == true
    ComboBoxSetDisabledFlag(P .. "PurposeComboBox", false)
    local rgb = purpose_editable and C.TEXT or C.DIM
    LabelSetTextColor(P .. "PurposeLabel", rgb[1], rgb[2], rgb[3])
    refresh_purpose_text(purpose_editable)
end

-- Handler gate: re-check before any work; when unavailable only refresh the buttons
-- (the disabled state and tooltip already say why, so nothing is printed).
local BUTTON_OF = { OrganizeDistance = "OrganizeButton" }

local function ready(action)
    if ACTIONS[action]() then
        return true
    end
    local button = BUTTON_OF[action] or action
    local ok = ACTIONS[button]()
    ButtonSetDisabledFlag(P .. button, ok ~= true)
    WindowSetShowing(P .. button .. "DisabledHover", ok ~= true)
    return false
end

-- Region/LFG are greyed out while not joined (pressed state is kept).
-- Region/LFG manual search and the Region auto-search are greyed out while the
-- channel is not joined (pressed state kept). Auto search stays switchable off.
function AutoBandWindowTools.RefreshSearchChannelControls()
    local region = search_channel_joined("Region")
    C.enable_check(P .. "SearchRoleChan1CheckBox", P .. "SearchRoleChan1Label", region)
    C.enable_check(P .. "SearchRoleChan5CheckBox", P .. "SearchRoleChan5Label", search_channel_joined("LFG"))
    C.enable_check(P .. "AutoSearchCheckBox", P .. "AutoSearchLabel", region or AutoBand.saved.autonote_enabled == true)
end

local function refresh_purpose()
    local index = 1
    for i, key in ipairs(AutoBandWindowTools.purpose_keys) do
        if key == AutoBand.current_purpose then
            index = i + 1
        end
    end
    ComboBoxSetSelectedMenuItem(P .. "PurposeComboBox", index)
end

function AutoBandWindowTools.Initialize()
    C.label(P .. "KickLabel", "Manage Players", C.HEADER)
    C.label(P .. "SearchRoleLabel", "Manual Search for Players", C.HEADER)
    C.label(P .. "OrganizeHeader", "Organize", C.HEADER)
    ButtonSetText(P .. "PrintButton", L"Print")
    ButtonSetText(P .. "KickButton", L"Kick")
    ButtonSetText(P .. "ZoneVoteButton", L"ZoneVote")
    C.init_info_link(P .. "ArrivalLink", "(Arrivals)", 20)
    C.label(P .. "SearchRoleChan1Label", "Region")
    C.label(P .. "SearchRoleChanT4Label", "/t4", C.TEXT)
    C.label(P .. "SearchRoleChan5Label", "LFG")
    C.label(P .. "PurposeLabel", "Purpose", C.TEXT)
    C.label(P .. "DiscordReqLabel", "Append \"Discord req\"", C.TEXT)
    C.label(P .. "NoMicLabel", "No mic")
    C.label(P .. "AutoFormSearchLabel", "Autoform WB on search if needed", C.TEXT)
    ButtonSetText(P .. "SearchRoleButton", L"Manual Search")
    ButtonSetText(P .. "FormWarbandButton", L"Form WB")
    C.label(P .. "AutoSearchLabel", "Auto Search in Region (5 mins)")
    C.label(P .. "AutoPartyNoteLabel", "Auto Update /partynote for WB", C.TEXT)
    ButtonSetText(P .. "OrganizeButton", L"Organize WB")
    ButtonSetText(P .. "ScoreboardButton", L"AB Scoreboard")
    C.label(P .. "NotifyBuffsLabel", "Notify WB after Organize", C.TEXT)
    C.label(P .. "PrintRoleLabel", "Print Role Assignments", C.TEXT)
    C.label(P .. "ArrivalTagsLabel", "Arrival tags", C.TEXT)
    local arrival_label_width = C.natural_text_size(P .. "ArrivalTagsLabel", nil, #"Arrival tags")
    WindowSetDimensions(P .. "ArrivalTagsLabel", arrival_label_width and math.ceil(arrival_label_width) or 99, 26)
    C.label(P .. "KickOfflineLabel", "Too far", C.TEXT)
    C.label(P .. "KickRankLabel", "Low rank", C.TEXT)
    C.label(P .. "KickZoneLabel", "Not in leader's / assistants' zone", C.TEXT)
    for _, func in pairs(AutoBandWindowTools.tools_data) do
        ButtonSetCheckButtonFlag(P .. func.button, true)
    end
    C.init_checks(P, { "SearchRoleChan1", "SearchRoleChanT4", "SearchRoleChan5", "DiscordReq", "NoMic", "AutoFormSearch",
        "AutoSearch", "AutoPartyNote", "NotifyBuffs", "PrintRole", "ArrivalTags" })
    AutoBandWindowTools.ResetSearchChannels()

    -- static purpose list (never rebuilt on refresh)
    local entries = {}
    for key, info in pairs(AB_const.WARBAND_PURPOSES) do
        entries[#entries + 1] = { key = key, display = tostring(info.display or key) }
    end
    table.sort(entries, function(a, b) return a.display < b.display end)
    refreshing = true
    ComboBoxClearMenuItems(P .. "PurposeComboBox")
    ComboBoxAddMenuItem(P .. "PurposeComboBox", L"(none)")
    AutoBandWindowTools.purpose_keys = {}
    for i, entry in ipairs(entries) do
        ComboBoxAddMenuItem(P .. "PurposeComboBox", towstring(entry.display))
        AutoBandWindowTools.purpose_keys[i] = entry.key
    end
    refreshing = false
end

function AutoBandWindowTools.ResetSearchChannels()
    C.check(P .. "SearchRoleChan1CheckBox", true)
    C.check(P .. "SearchRoleChanT4CheckBox", false)
    C.check(P .. "SearchRoleChan5CheckBox", false)
end

-- Page defaults also put the temporary channel selection back to Region only.
function AutoBandWindowTools.BeforePageDefaults()
    AutoBandWindowTools.ResetSearchChannels()
end

local function saved(key)
    return AutoBand.saved[key] == true
end

-- "uses <template>" sits right-aligned on the Organize header row (270 wide, small
-- font); long names are shortened until the measured text fits 262.
local USES_FIT = { max_w = 262, fallback_chars = 24, cache = {} }

local function default_preset_name()
    local name = AutoBand.saved.default_template
    if name == nil or name == "" then
        name = AB_const.EMPTY_TEMPLATE
    end
    return tostring(name)
end

function AutoBandWindowTools.Refresh(_opts)
    refreshing = true
    for fid, func in pairs(AutoBandWindowTools.tools_data) do
        C.check(P .. func.button, kick_filters()[fid] == true)
    end
    refresh_purpose()
    C.check(P .. "DiscordReqCheckBox", saved("search_discord_req_enabled"))
    C.check(P .. "NoMicCheckBox", saved("search_no_mic_enabled"))
    C.enable_check(P .. "NoMicCheckBox", P .. "NoMicLabel", saved("search_discord_req_enabled"))
    C.check(P .. "AutoFormSearchCheckBox", saved("autoform_search_enabled"))
    C.check(P .. "AutoSearchCheckBox", saved("autonote_enabled"))
    C.check(P .. "AutoPartyNoteCheckBox", saved("autopartynote_enabled"))
    C.check(P .. "NotifyBuffsCheckBox", saved("notify_buffs_enabled"))
    C.check(P .. "PrintRoleCheckBox", saved("printrole_enabled"))
    C.check(P .. "ArrivalTagsCheckBox", saved("print_arrival_notify_tags_enabled"))
    local tags_rgb = saved("printrole_enabled") and C.TEXT or C.DIM
    LabelSetTextColor(P .. "ArrivalTagsLabel", tags_rgb[1], tags_rgb[2], tags_rgb[3])
    C.label(P .. "OrganizeUsesLabel", C.fit_text(P .. "OrganizeUsesLabel", "uses ", default_preset_name(), "", USES_FIT), C.DIM)
    AutoBandWindowTools.RefreshSearchChannelControls()
    AutoBandWindowTools.RefreshActionButtons()
    refreshing = false
end

function AutoBandWindowTools.Show()
    AutoBandWindowTools.Refresh({})
    WindowSetShowing(AutoBandWindowTools.name, true)
end

function AutoBandWindowTools.Hide()
    WindowSetShowing(AutoBandWindowTools.name, false)
end

-- Kick-check filters (global, not saved in presets) ---------------------------
local function set_kick_filter(fid)
    kick_filters(true)[fid] = ButtonGetPressedFlag(P .. AutoBandWindowTools.tools_data[fid].button) == true
    AutoBandWindowTools.RefreshActionButtons()
end

function AutoBandWindowTools.OnKickOfflineCheckBox() set_kick_filter(AB_const.KICK_OFFLINE) end
function AutoBandWindowTools.OnKickZoneCheckBox() set_kick_filter(AB_const.KICK_ZONE) end
function AutoBandWindowTools.OnKickRankCheckBox() set_kick_filter(AB_const.KICK_RANK) end
function AutoBandWindowTools.OnClickKickOfflineLabel() C.label_toggle(P .. "KickOfflineCheckBox", AutoBandWindowTools.OnKickOfflineCheckBox) end
function AutoBandWindowTools.OnClickKickZoneLabel() C.label_toggle(P .. "KickZoneCheckBox", AutoBandWindowTools.OnKickZoneCheckBox) end
function AutoBandWindowTools.OnClickKickRankLabel() C.label_toggle(P .. "KickRankCheckBox", AutoBandWindowTools.OnKickRankCheckBox) end

local function run_checked(kind)
    for fid, data in pairs(AutoBandWindowTools.tools_data) do
        if kick_filters()[fid] == true then
            data[kind]()
        end
    end
end

function AutoBandWindowTools.OnPrintButton()
    if not ready("PrintButton") then
        return
    end
    AB_util.print("Warband Report ")
    run_checked("func_print")
end

function AutoBandWindowTools.OnKickButton()
    if not ready("KickButton") then
        return
    end
    run_checked("func_kick")
end

-- Search channels: temporary selection, only toggles the box.
function AutoBandWindowTools.OnSearchChannelToggled()
    AutoBandWindowTools.RefreshActionButtons()
end

local function toggle_box(box)
    if C.disabled(P .. box) then
        return
    end
    ButtonSetPressedFlag(P .. box, not ButtonGetPressedFlag(P .. box))
    AutoBandWindowTools.RefreshActionButtons()
end
function AutoBandWindowTools.OnClickSearchRoleChan1Label() toggle_box("SearchRoleChan1CheckBox") end
function AutoBandWindowTools.OnClickSearchRoleChanT4Label() toggle_box("SearchRoleChanT4CheckBox") end
function AutoBandWindowTools.OnClickSearchRoleChan5Label() toggle_box("SearchRoleChan5CheckBox") end

function AutoBandWindowTools.OnSearchRoleButton()
    AutoBandWindowTools.RefreshSearchChannelControls()
    if not ready("SearchRoleButton") then
        return
    end
    AutoBand.cmd_search_roles((selected_search_channels()))
end

function AutoBandWindowTools.OnPurposeChanged()
    if refreshing then
        return
    end
    if not ACTIONS.PurposeComboBox() then
        -- Allow browsing, but restore the current value without running a command.
        refreshing = true
        refresh_purpose()
        refreshing = false
        refresh_purpose_text(false)
        return
    end
    local index = ComboBoxGetSelectedMenuItem(P .. "PurposeComboBox")
    if type(index) ~= "number" or index < 1 then
        return
    end
    local key = AutoBandWindowTools.purpose_keys[index - 1]
    AutoBand.cmd_set_purpose({ key or "clear" })
    -- show what the core accepted (a non-leader is refused and snaps back)
    refreshing = true
    refresh_purpose()
    refreshing = false
    refresh_purpose_text(true)
end

-- Warband actions ----------------------------------------------------------------
function AutoBandWindowTools.OnFormWarbandButton()
    if ready("FormWarbandButton") then
        AutoBand.cmd_form({})
    end
end

function AutoBandWindowTools.OnOrganizeButton()
    if ready("OrganizeButton") then
        AutoBand.cmd_organize({})
    end
end

function AutoBandWindowTools.OnOrganizeButtonRightClick()
    if ready("OrganizeDistance") then
        AutoBand.cmd_organize({ "distance" })
    end
end

function AutoBandWindowTools.OnScoreboardButton()
    if ready("ScoreboardButton") and type(AutoBand.cmd_scoreboard_probe) == "function" then
        AutoBand.cmd_scoreboard_probe({})
    end
end

function AutoBandWindowTools.OnZoneVoteButton()
    if ready("ZoneVoteButton") then
        AutoBand.cmd_zone_vote({})
    end
end

function AutoBandWindowTools.OnArrivalLink() AutoBand.cmd_arrival({}) end

-- Advertising and organize messages -------------------------------------------------
-- Checkboxes bound to a toggling /ab command: run it only when the box and the saved
-- value disagree, then mirror the saved value.
local function toggle_with(box, key, run)
    local want = ButtonGetPressedFlag(P .. box) == true
    if saved(key) ~= want then
        run(want)
    end
    C.check(P .. box, saved(key))
end

function AutoBandWindowTools.OnAutoSearchCheckBox()
    local box = P .. "AutoSearchCheckBox"
    local want = ButtonGetPressedFlag(box) == true
    if C.disabled(box) or (want and not search_channel_joined("Region")) then
        C.check(box, saved("autonote_enabled"))
        AutoBandWindowTools.RefreshSearchChannelControls()
        return
    end
    toggle_with("AutoSearchCheckBox", "autonote_enabled", function() AutoBand.cmd_flag_autonote({}) end)
    AutoBandWindowTools.RefreshSearchChannelControls()
end

function AutoBandWindowTools.OnAutoFormSearchCheckBox()
    toggle_with("AutoFormSearchCheckBox", "autoform_search_enabled", function(want)
        AutoBand.cmd_toggle_autoform_search({ want and "on" or "off" })
    end)
    AutoBandWindowTools.RefreshActionButtons()
end

function AutoBandWindowTools.OnDiscordReqCheckBox()
    local want = ButtonGetPressedFlag(P .. "DiscordReqCheckBox") == true
    if saved("search_discord_req_enabled") ~= want then
        AutoBand.saved.search_discord_req_enabled = want
        AB_util.print("Append \"Discord req\" to searches: " .. tostring(want))
        AutoBand.mark_template_settings_modified()
    end
    AutoBandWindowTools.Refresh({})
end

function AutoBandWindowTools.OnNoMicCheckBox()
    local box = P .. "NoMicCheckBox"
    if C.disabled(box) then
        C.check(box, saved("search_no_mic_enabled"))
        return
    end
    local want = ButtonGetPressedFlag(box) == true
    if saved("search_no_mic_enabled") ~= want then
        AutoBand.saved.search_no_mic_enabled = want
        AB_util.print("Append \"no mic needed\" to searches: " .. tostring(want))
        AutoBand.mark_template_settings_modified()
    end
end

function AutoBandWindowTools.OnAutoPartyNoteCheckBox()
    toggle_with("AutoPartyNoteCheckBox", "autopartynote_enabled", function() AutoBand.cmd_toggle_partynote({}) end)
end

function AutoBandWindowTools.OnNotifyBuffsCheckBox()
    toggle_with("NotifyBuffsCheckBox", "notify_buffs_enabled", function() AutoBand.cmd_toggle_buffnotify({}) end)
end

function AutoBandWindowTools.OnPrintRoleCheckBox()
    toggle_with("PrintRoleCheckBox", "printrole_enabled", function() AutoBand.cmd_flag_printrole({}) end)
    AutoBandWindowTools.Refresh({})
end

function AutoBandWindowTools.OnArrivalTagsCheckBox()
    toggle_with("ArrivalTagsCheckBox", "print_arrival_notify_tags_enabled", function(want)
        AutoBand.cmd_toggle_arrival_notify_tags({ want and "on" or "off" })
    end)
end

local LABEL_TARGETS = {
    DiscordReqLabel = "DiscordReq", NoMicLabel = "NoMic", AutoFormSearchLabel = "AutoFormSearch",
    AutoSearchLabel = "AutoSearch", AutoPartyNoteLabel = "AutoPartyNote", NotifyBuffsLabel = "NotifyBuffs",
    PrintRoleLabel = "PrintRole", ArrivalTagsLabel = "ArrivalTags",
}

function AutoBandWindowTools.OnLabelClick()
    local base = LABEL_TARGETS[C.control(P) or ""]
    if base then
        C.label_toggle(P .. base .. "CheckBox", AutoBandWindowTools["On" .. base .. "CheckBox"])
    end
end

-- Tooltips ---------------------------------------------------------------------------
local function search_preview()
    local fallback = "Posts WB needs in the checked channels."
    if type(AutoBand.build_search_roles_preview_text) ~= "function" then
        return fallback
    end
    -- all checked channels: the preview names the ones that are not joined
    local args = {}
    for _, entry in ipairs({ { "SearchRoleChan1CheckBox", "region" }, { "SearchRoleChanT4CheckBox", "t4" },
        { "SearchRoleChan5CheckBox", "lfg" } }) do
        if ButtonGetPressedFlag(P .. entry[1]) == true then
            args[#args + 1] = entry[2]
        end
    end
    local ok, text = pcall(AutoBand.build_search_roles_preview_text, args, { channel_reason = C.channel_reason })
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return fallback
end

local function scoreboard_preview()
    local fallback = "Previews current WB scoreboard output before sending to /wb."
    if type(AutoBand.build_scoreboard_preview_text) ~= "function" then
        return fallback
    end
    local ok, text = pcall(AutoBand.build_scoreboard_preview_text, {})
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return fallback
end

local function zonevote_preview()
    if type(AutoBand.get_zonevote_entries) ~= "function" then
        return "ZoneVote unavailable in this build."
    end
    local entries, err = AutoBand.get_zonevote_entries()
    if err ~= nil then
        return tostring(err)
    end
    if type(entries) ~= "table" or #entries == 0 then
        return "No active RvR zones found."
    end
    local title = type(AutoBand.get_zonevote_title) == "function" and AutoBand.get_zonevote_title() or "Zone"
    local lines = { "Starts a vote for active zones.", "ZoneVote preview:", tostring(title) }
    if type(AutoBand.build_zonevote_ready_table) == "function" then
        local ready_table = AutoBand.build_zonevote_ready_table(entries, (AutoBand.zone_vote_config or {}).default_timer_seconds)
        local answers = ready_table and ready_table.Answers
        if type(answers) == "table" and #answers > 0 then
            for _, answer in ipairs(answers) do
                lines[#lines + 1] = "- " .. tostring(answer.Name or "")
            end
            return table.concat(lines, "\n")
        end
    end
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = "- " .. tostring(entry.name or ("Zone " .. tostring(entry.zone_id or "?")))
    end
    return table.concat(lines, "\n")
end

local function kick_tooltip()
    if AutoBand.is_pm_block_active() then
        return "Removes the checked members (no reason tells)."
    end
    return "Removes the checked members."
end

local TOOLTIPS = {
    FormWarbandButton = function()
        if AutoBand.is_warband_enabled() ~= true then
            return "Forms a warband from your party.\nAlso turns warband features on."
        end
        return "Forms a warband from your party."
    end,
    OrganizeButton = "Sorts the warband into groups.\nRight-click: keep nearby players together.",
    ScoreboardButton = "Previews the scoreboard.",
    ZoneVoteButton = "Starts a zone vote.",
    ArrivalLink = "Shows the order members joined.",
    SearchRoleButton = "Posts what the warband needs.",
    PrintButton = "Lists the checked members in chat.",
    KickButton = kick_tooltip,
    DiscordReqCheckBox = "Adds \"Discord req.\" to ads.",
    NoMicCheckBox = function()
        local text = "Adds \"(no mic needed)\" to ads."
        if not saved("search_discord_req_enabled") then
            text = text .. "\nNeeds Discord req."
        end
        return text
    end,
    AutoFormSearchCheckBox = "Forms a warband first when you search solo.",
    AutoSearchCheckBox = "Posts needs in Region every 5 minutes while you lead.",
    AutoPartyNoteCheckBox = "Keeps the party note listing needed roles.",
    NotifyBuffsCheckBox = "Announces in /wb when Organize finishes.",
    PrintRoleCheckBox = "Prints role changes in chat.",
    ArrivalTagsCheckBox = function()
        local text = "Adds arrival order to printed roles."
        if not saved("printrole_enabled") then
            text = text .. "\nNo effect while Print Role Assignments is off."
        end
        return text
    end,
    OrganizeUsesLabel = function() return "Default template: " .. default_preset_name() .. "." end,
    PurposeComboBox = "Purpose shown in ads and the party note.",
    PurposeLabel = "Purpose shown in ads and the party note.",
    -- section headings (explicit keys: "KickLabel" must not become "KickCheckBox")
    KickLabel = "Checks members; Print lists them, Kick removes them.",
    SearchRoleLabel = "Posts what the warband needs to chat.",
    OrganizeHeader = "Sorts the warband into groups by role.",
    KickOfflineCheckBox = "Too-far members, except Protect/Promote.",
    KickZoneCheckBox = "Members outside the leader's/assistants' zones.",
    KickRankCheckBox = "Members below the rank requirement.",
    SearchRoleChan1CheckBox = "Manual search posts in Region.",
    SearchRoleChanT4CheckBox = "Manual search posts in /t4.",
    SearchRoleChan5CheckBox = "Manual search posts in LFG.",
}

-- Previews only run for an available action (built on hover, never on refresh).
local PREVIEWS = {
    SearchRoleButton = search_preview,
    ScoreboardButton = scoreboard_preview,
    ZoneVoteButton = zonevote_preview,
}
local CHANNEL_OF = { SearchRoleChan1CheckBox = "Region", SearchRoleChan5CheckBox = "LFG", AutoSearchCheckBox = "Region" }

local function tooltip_for(control)
    if control == nil then
        return nil
    end
    control = string.gsub(control, "DisabledHover$", "")
    if TOOLTIPS[control] == nil then
        control = string.gsub(control, "Label$", "CheckBox")
    end
    local text = TOOLTIPS[control]
    if type(text) == "function" then
        text = text() -- cheap static text only; previews are in PREVIEWS
    end
    if text == nil then
        return nil
    end
    local action = ACTIONS[control]
    if action then
        local ok, reason = action()
        if not ok then
            -- early: no preview builder runs for an unavailable action
            local status = (control == "PurposeComboBox" or control == "PurposeLabel") and "Read-only: " or "Unavailable: "
            return text .. "\n" .. status .. tostring(reason)
        end
        if PREVIEWS[control] then
            text = PREVIEWS[control]()
        end
        return text
    end
    local channel = CHANNEL_OF[control]
    if channel and not search_channel_joined(channel) then
        text = text .. "\nUnavailable: " .. C.channel_reason(channel)
    end
    return text
end

function AutoBandWindowTools.OnControlMouseOver()
    local control = C.control(P)
    if control == "ArrivalLink" then C.set_info_link_hover(P .. control, true) end
    C.show_tooltip(tooltip_for(control))
end

function AutoBandWindowTools.OnControlMouseOverEnd()
    if C.control(P) == "ArrivalLink" then C.set_info_link_hover(P .. "ArrivalLink", false) end
    C.hide_tooltip()
end
