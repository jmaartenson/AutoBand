-- AutoBand Realm tab: realm stats, warband leaders, Enemy markgroups and realm-rank
-- data, each action next to its settings. Everything that needs CSV/Enemy data is gated early
-- by read-only checks (AutoBandWindowCommon); recovery and cleanup controls (Use CSV,
-- Refresh now, turning a monitor off, removing a monitored group, clearing the
-- default group) always stay available.
AutoBandWindowRealm = {}

AutoBandWindowRealm.name = "AutoBandWindowRealmTab"

local C = AutoBandWindowCommon
local P = AutoBandWindowRealm.name
local refreshing = false

-- Markgroup choices rebuild on Show, Refresh list and monitor membership changes.
AutoBandWindowRealm.choices = {}
AutoBandWindowRealm.selected_key = nil
local monitored_choice_keys = {}

local function saved(key)
    return AutoBand.saved[key] == true
end

local function selected_choice()
    for _, choice in ipairs(AutoBandWindowRealm.choices) do
        if choice.key == AutoBandWindowRealm.selected_key then
            return choice
        end
    end
    return nil
end

local function is_monitored(key)
    return key ~= nil and type(AutoBand.online_monitor_groups) == "table" and AutoBand.online_monitor_groups[key] ~= nil
end

local function monitor_choices_changed()
    for key in pairs(monitored_choice_keys) do
        if not is_monitored(key) then return true end
    end
    if type(AutoBand.online_monitor_groups) == "table" then
        for key in pairs(AutoBand.online_monitor_groups) do
            if not monitored_choice_keys[key] then return true end
        end
    end
    return false
end

-- Header status (small font, left-aligned) starts 16 after the "Enemy markgroups"
-- header (XML anchor) and uses the rest of the row to x 576; it is shortened to fit
-- its width - 4 by measurement. Initialize sizes the header to its text.
local GROUP_HEADER_TEXT, GROUP_HEADER_FALLBACK_W, GROUP_HEADER_MAX_W = "Enemy markgroups", 176, 276
local GROUP_ROW_W, GROUP_STATUS_GAP = 552, 16
local GROUP_STATUS_FIT = { max_w = 356, fallback_chars = 40, cache = {} }

local function fit_group_header()
    local w = C.natural_text_size(P .. "GroupsHeader", GROUP_HEADER_TEXT, #GROUP_HEADER_TEXT)
    w = w and math.ceil(w) or GROUP_HEADER_FALLBACK_W
    if w < 1 or w > GROUP_HEADER_MAX_W then
        w = GROUP_HEADER_FALLBACK_W
    end
    WindowSetDimensions(P .. "GroupsHeader", w, 24)
    local status_w = GROUP_ROW_W - w - GROUP_STATUS_GAP
    WindowSetDimensions(P .. "GroupStatusLabel", status_w, 20)
    if GROUP_STATUS_FIT.max_w ~= status_w - 4 then
        GROUP_STATUS_FIT.max_w = status_w - 4
        GROUP_STATUS_FIT.cache = {} -- fitted texts were for the old width
    end
    return w, status_w
end
AutoBandWindowRealm.fit_group_header = fit_group_header
AutoBandWindowRealm.group_status_fit = GROUP_STATUS_FIT

local function default_key()
    local key = AutoBand.saved.online_markgroup_default_key
    if type(key) == "string" and key ~= "" then
        return string.lower(key)
    end
    return nil
end

-- Rebuild the markgroup combo from metadata (no member traversal), keeping the
-- selection by key. The first entry is the "<Choose group>" placeholder (selected_key
-- nil: never a group, never a default); the saved default group is pre-selected. The
-- clear fires OnSelChanged(0), which the guard ignores.
local CHOOSE_GROUP = "<Choose group>"
function AutoBandWindowRealm.RebuildGroupChoices()
    local choices = {}
    if type(AutoBand.get_online_markgroup_choices) == "function" then
        choices = AutoBand.get_online_markgroup_choices() or {}
    end
    AutoBandWindowRealm.choices = choices
    refreshing = true
    ComboBoxClearMenuItems(P .. "GroupComboBox")
    ComboBoxAddMenuItem(P .. "GroupComboBox", towstring(CHOOSE_GROUP))
    -- first build (nothing selected yet): show the saved default group if listed
    if AutoBandWindowRealm.selected_key == nil then
        AutoBandWindowRealm.selected_key = default_key()
    end
    local selected_index = 1
    local selected_key = nil
    monitored_choice_keys = {}
    for i, choice in ipairs(choices) do
        local text = tostring(choice.name_s or choice.key)
        if choice.monitored then
            monitored_choice_keys[choice.key] = true
            text = "[M] " .. text
        end
        if not choice.available then
            text = text .. " (unavailable)"
        end
        ComboBoxAddMenuItem(P .. "GroupComboBox", towstring(text))
        if choice.key == AutoBandWindowRealm.selected_key then
            selected_index, selected_key = i + 1, choice.key
        end
    end
    AutoBandWindowRealm.selected_key = selected_key
    ComboBoxSetSelectedMenuItem(P .. "GroupComboBox", selected_index)
    refreshing = false
end

-- Text links for chat-only actions: unskinned labels in link blue (brighter on hover),
-- dim while unavailable (the reason is in the tooltip; handlers re-check their gates);
-- each is exactly as wide as its measured text. The dim "|" between two links sits
-- centred in a fixed 24-wide label (XML), so it has visible space on both sides.
local LINK, LINK_HOVER = C.LINK, C.LINK_HOVER
local LINK_TEXT = {
    StatsLink = "Realmstats", StatsBreakdownLink = "Breakdown", WBLeadersLink = "List WB leaders",
    GroupRefreshLink = "Refresh list", GroupListLink = "List monitors", GroupCheckLink = "Check now",
}
local LINK_SEPS = { "StatsLinkSep", "GroupListLinkSep" }
local link_state = {}

local function size_to_text(name, plain)
    LabelSetText(P .. name, towstring(plain))
    local w = C.natural_text_size(P .. name, nil, #plain)
    WindowSetDimensions(P .. name, w and math.ceil(w) or #plain * 8, 26)
end

local function set_link(name, enabled)
    link_state[name] = enabled == true
    local rgb = enabled and LINK or C.DIM
    LabelSetTextColor(P .. name, rgb[1], rgb[2], rgb[3])
end

function AutoBandWindowRealm.link_enabled(name)
    return link_state[name] == true
end

local function refresh_groups()
    if monitor_choices_changed() then
        AutoBandWindowRealm.RebuildGroupChoices()
    end
    local choice = selected_choice()
    local key = choice and choice.key or nil
    local monitored = is_monitored(key)
    local is_default = key ~= nil and key == default_key()
    local online_ok, _, online_reason = C.online_gate()
    local enemy_loaded = type(AutoBand.has_online_enemy_templates) == "function" and AutoBand.has_online_enemy_templates() == true
    local can_set = choice ~= nil and choice.available == true and online_ok == true
    C.check(P .. "MonitorCheckBox", monitored)
    C.check(P .. "DefaultGroupCheckBox", is_default)
    -- removing/clearing always works; adding/setting needs Enemy + fresh CSV
    C.enable_check(P .. "MonitorCheckBox", P .. "MonitorLabel", monitored or can_set)
    C.enable_check(P .. "DefaultGroupCheckBox", P .. "DefaultGroupLabel", is_default or can_set)
    set_link("GroupCheckLink", can_set)
    local count = tonumber(AutoBand.get_online_monitor_count and AutoBand.get_online_monitor_count()) or 0
    -- header status: short and measured to fit; the full text (and any pause
    -- reason) is in its tooltip
    local status, short
    local rgb = C.DIM
    if not enemy_loaded then
        status = "Enemy not loaded: " .. tostring(count) .. " monitor(s) inactive."
        short = "Enemy not loaded"
        rgb = C.WARN
    elseif not online_ok then
        status = "Monitoring " .. tostring(count) .. " group(s); paused: " .. tostring(online_reason)
        short = "Paused (" .. tostring(count) .. ")"
        rgb = C.WARN
    else
        status = "Monitoring " .. tostring(count) .. " group(s)."
        short = "Monitoring " .. tostring(count) .. (count == 1 and " group" or " groups")
    end
    -- name the saved default group so it is visible without selecting it
    local default_name = nil
    local saved_default = default_key()
    if saved_default then
        default_name = tostring(AutoBand.saved.online_markgroup_default_name or saved_default)
        local listed = false
        for _, entry in ipairs(AutoBandWindowRealm.choices) do
            if entry.key == saved_default and entry.available then
                listed = true
            end
        end
        if not listed then
            default_name = default_name .. " (unavailable)"
        end
    end
    if default_name then
        status = status .. " Default: " .. default_name .. "."
        short = short .. " - Default: " .. default_name
    end
    AutoBandWindowRealm.group_status_full = status
    C.label(P .. "GroupStatusLabel", C.fit_text(P .. "GroupStatusLabel", "", short, "", GROUP_STATUS_FIT), rgb)
end

-- Realm reports: gated by the read-only stats check (the link dims, the tooltip gives
-- the reason and the handler re-checks).
local ACTIONS = {}

function ACTIONS.StatsButton()
    local ok, _, reason = C.stats_gate()
    return ok == true, reason
end
ACTIONS.StatsBreakdownButton = ACTIONS.StatsButton

-- Right-click on Realmstats: online monitor names need monitors, Enemy and fresh CSV.
function ACTIONS.StatsOnline()
    local ok, reason = ACTIONS.StatsButton()
    if not ok then
        return false, reason
    end
    if (tonumber(AutoBand.get_online_monitor_count and AutoBand.get_online_monitor_count()) or 0) <= 0 then
        return false, "No monitored groups."
    end
    local online_ok, _, online_reason = C.online_gate()
    return online_ok == true, online_reason
end

function AutoBandWindowRealm.RefreshActionButtons()
    set_link("StatsLink", ACTIONS.StatsButton() == true)
    set_link("StatsBreakdownLink", ACTIONS.StatsBreakdownButton() == true)
end

local function stats_ready(action)
    if ACTIONS[action]() then
        return true
    end
    AutoBandWindowRealm.RefreshActionButtons()
    return false
end

function AutoBandWindowRealm.OnStatsButton()
    if stats_ready("StatsButton") then
        AutoBand.cmd_stats({})
    end
end

function AutoBandWindowRealm.OnStatsButtonRightClick()
    if stats_ready("StatsOnline") and type(AutoBand.cmd_online) == "function" then
        AutoBand.cmd_online({})
    end
end

function AutoBandWindowRealm.OnStatsBreakdownButton()
    if stats_ready("StatsBreakdownButton") then
        AutoBand.cmd_stats({ "breakdown" })
    end
end

function AutoBandWindowRealm.OnStatsBreakdownButtonRightClick()
    if stats_ready("StatsBreakdownButton") then
        AutoBand.cmd_stats({ "breakdown", "detailed" })
    end
end

function AutoBandWindowRealm.OnWBLeadersButton()
    AutoBand.cmd_wbleaders({})
end

local function refresh_edit(opts)
    if opts.refresh_text_changed then
        C.set_edit(P .. "RefreshEditBox", tostring(AutoBand.saved.realmrank_refresh_seconds or ""))
    end
end

function AutoBandWindowRealm.Refresh(opts)
    opts = opts or {}
    C.check(P .. "RRLookupCheckBox", saved("realmrank_lookup_enabled"))
    local status, rgb = C.csv_status_text()
    C.label(P .. "RRStatusLabel", status, rgb)
    refresh_edit(opts)
    -- stats: turning off always works; turning on needs usable stats data
    local stats_ok = C.stats_gate()
    C.check(P .. "StatsMonitorCheckBox", saved("realmstats_enabled"))
    C.enable_check(P .. "StatsMonitorCheckBox", P .. "StatsMonitorLabel", stats_ok == true or saved("realmstats_enabled"))
    C.label(P .. "ThresholdValueLabel", tostring(AutoBand.saved.realmstats_shift_threshold_percent or "") .. "%")
    C.check(P .. "WBLeadNotifyCheckBox", saved("wbleader_notify_enabled"))
    local min_members = AutoBand.saved.wbleader_min_members
    if type(AutoBand.WBLeaders) == "table" and type(AutoBand.WBLeaders.GetMinMembers) == "function" then
        min_members = AutoBand.WBLeaders.GetMinMembers()
    end
    C.label(P .. "WBLeadMinValueLabel", tostring(min_members))
    C.check(P .. "WBLeaderTellAlertCheckBox", saved("wbleader_tell_alert_enabled"))
    AutoBandWindowRealm.RefreshActionButtons()
    refresh_groups()
end

function AutoBandWindowRealm.Initialize()
    C.label(P .. "StatsHeader", "Realm stats", C.HEADER)
    C.label(P .. "LeadersHeader", "WB leaders", C.HEADER)
    C.label(P .. "GroupsHeader", GROUP_HEADER_TEXT, C.HEADER)
    fit_group_header()
    C.label(P .. "DataHeader", "Realm-rank data", C.HEADER)
    C.label(P .. "RRLookupLabel", "Use realm-rank CSV", C.TEXT)
    C.label(P .. "RefreshLabel", "Refresh (seconds)", C.TEXT)
    ButtonSetText(P .. "RefreshApplyButton", L"Apply")
    ButtonSetText(P .. "RefreshNowButton", L"Refresh now")
    C.label(P .. "StatsMonitorLabel", "Report population shifts", C.TEXT)
    C.label(P .. "ThresholdLabel", "Threshold", C.TEXT)
    C.label(P .. "WBLeadNotifyLabel", "Notify on leader changes", C.TEXT)
    C.label(P .. "WBLeadMinLabel", "Minimum WB size", C.TEXT)
    C.label(P .. "WBLeaderTellAlertLabel", "WB-Leader Tell Alerts", C.TEXT)
    C.label(P .. "GroupLabel", "Group", C.TEXT)
    C.label(P .. "MonitorLabel", "Monitor this group", C.TEXT)
    C.label(P .. "DefaultGroupLabel", "Default for /ab online", C.TEXT)
    for name, text in pairs(LINK_TEXT) do
        size_to_text(name, text)
    end
    for _, name in ipairs(LINK_SEPS) do
        C.label(P .. name, "|", C.DIM)
    end
    set_link("WBLeadersLink", true)
    set_link("GroupRefreshLink", true)
    set_link("GroupListLink", true)
    C.init_checks(P, { "RRLookup", "StatsMonitor", "WBLeadNotify", "WBLeaderTellAlert", "Monitor", "DefaultGroup" })
end

function AutoBandWindowRealm.Show()
    AutoBandWindowRealm.RebuildGroupChoices()
    AutoBandWindowRealm.Refresh({ refresh_text_changed = true })
    WindowSetShowing(P, true)
end

function AutoBandWindowRealm.Hide()
    WindowSetShowing(P, false)
end

local function pressed(box)
    return ButtonGetPressedFlag(P .. box) == true
end

-- Realm-rank data -----------------------------------------------------------------------
function AutoBandWindowRealm.OnRRLookupCheckBox()
    AutoBand.set_realmrank_lookup_enabled(pressed("RRLookupCheckBox"), { skip_gui_refresh = true })
    AutoBandWindowRealm.Refresh({})
end

function AutoBandWindowRealm.OnRefreshApply()
    local value = C.parse_whole(C.edit_text(P .. "RefreshEditBox"))
    local ok = value ~= nil and AutoBand.set_realmrank_refresh_seconds(value) == true
    if not ok then
        local rr_const = AutoBand._realmrank_module and AutoBand._realmrank_module.const or {}
        AB_util.print("[Error] Refresh interval must be a whole number of seconds from " ..
            tostring(rr_const.REALMRANK_REFRESH_MIN_SECONDS or 60) .. " to " .. tostring(rr_const.REALMRANK_REFRESH_MAX_SECONDS or 1800) .. ".")
        return
    end
    refresh_edit({ refresh_text_changed = true })
end

function AutoBandWindowRealm.OnRefreshEscape()
    refresh_edit({ refresh_text_changed = true })
end

-- Explicit recovery action: loads the CSV now (as /ab csvrefresh).
function AutoBandWindowRealm.OnRefreshNow()
    AutoBand.cmd_rrrefresh({})
    AutoBandWindowRealm.Refresh({})
end

-- Realm stats ---------------------------------------------------------------------------------
function AutoBandWindowRealm.OnStatsMonitorCheckBox()
    local want = pressed("StatsMonitorCheckBox")
    if want and (C.disabled(P .. "StatsMonitorCheckBox") or not C.stats_gate()) then
        -- refused before any activation; the setter would refuse as well
        AutoBandWindowRealm.Refresh({})
        return
    end
    AutoBand.set_realmstats_enabled(want, { skip_gui_refresh = true })
    AutoBandWindowRealm.Refresh({})
end

local function step_threshold(delta)
    local current = tonumber(AutoBand.saved.realmstats_shift_threshold_percent) or 0
    if current ~= current then
        current = 0
    end
    AutoBand.set_realmstats_shift_threshold_percent(current + delta, { skip_gui_refresh = true })
    AutoBandWindowRealm.Refresh({})
end

function AutoBandWindowRealm.OnThresholdPlus() step_threshold(1) end
function AutoBandWindowRealm.OnThresholdMinus() step_threshold(-1) end

-- Warband leaders ---------------------------------------------------------------------------------
function AutoBandWindowRealm.OnWBLeadNotifyCheckBox()
    if type(AutoBand.WBLeaders) == "table" and type(AutoBand.WBLeaders.SetNotifyEnabled) == "function" then
        AutoBand.WBLeaders.SetNotifyEnabled(pressed("WBLeadNotifyCheckBox"))
    end
    AutoBandWindowRealm.Refresh({})
end

local function step_wblead_min(delta)
    if type(AutoBand.WBLeaders) == "table" and type(AutoBand.WBLeaders.SetMinMembers) == "function" then
        AutoBand.WBLeaders.SetMinMembers(AutoBand.WBLeaders.GetMinMembers() + delta)
    end
    AutoBandWindowRealm.Refresh({})
end

function AutoBandWindowRealm.OnWBLeadMinPlus() step_wblead_min(1) end
function AutoBandWindowRealm.OnWBLeadMinMinus() step_wblead_min(-1) end

function AutoBandWindowRealm.OnWBLeaderTellAlertCheckBox()
    AutoBand.set_wbleader_tell_alert_enabled(pressed("WBLeaderTellAlertCheckBox"), { skip_gui_refresh = true })
    AutoBandWindowRealm.Refresh({})
end

-- Enemy markgroups ------------------------------------------------------------------------------------
function AutoBandWindowRealm.OnGroupChanged()
    if refreshing then
        return
    end
    local index = ComboBoxGetSelectedMenuItem(P .. "GroupComboBox")
    if index == 1 then
        AutoBandWindowRealm.selected_key = nil -- "<Choose group>"
    else
        local choice = type(index) == "number" and AutoBandWindowRealm.choices[index - 1] or nil
        if choice then
            AutoBandWindowRealm.selected_key = choice.key
        end
    end
    refresh_groups()
end

function AutoBandWindowRealm.OnGroupRefresh()
    AutoBandWindowRealm.RebuildGroupChoices()
    refresh_groups()
end

function AutoBandWindowRealm.OnMonitorCheckBox()
    local choice = selected_choice()
    if not choice then
        refresh_groups()
        return
    end
    if is_monitored(choice.key) then
        AutoBand.set_online_monitor_group(choice.key, false)
    elseif choice.available and C.online_gate() then
        AutoBand.set_online_monitor_group(choice.key, true)
    end
    refresh_groups()
end

function AutoBandWindowRealm.OnDefaultGroupCheckBox()
    local choice = selected_choice()
    if not choice then
        refresh_groups()
        return
    end
    if choice.key == default_key() then
        AutoBand.set_online_default_group(nil)
    elseif choice.available and C.online_gate() then
        AutoBand.set_online_default_group(choice.key)
    end
    refresh_groups()
end

function AutoBandWindowRealm.OnGroupList()
    if type(AutoBand.print_online_monitor_summary) == "function" then
        AutoBand.print_online_monitor_summary()
    end
end

function AutoBandWindowRealm.OnGroupCheck()
    local choice = selected_choice()
    if not choice or not choice.available or not C.online_gate() then
        refresh_groups()
        return
    end
    AutoBand.check_online_markgroup(choice.key)
end

local LABEL_TARGETS = {
    RRLookupLabel = "RRLookup", StatsMonitorLabel = "StatsMonitor", WBLeadNotifyLabel = "WBLeadNotify",
    WBLeaderTellAlertLabel = "WBLeaderTellAlert", MonitorLabel = "Monitor", DefaultGroupLabel = "DefaultGroup",
}

function AutoBandWindowRealm.OnLabelClick()
    local base = LABEL_TARGETS[C.control(P) or ""]
    if base then
        C.label_toggle(P .. base .. "CheckBox", AutoBandWindowRealm["On" .. base .. "CheckBox"])
    end
end

-- Tooltips -------------------------------------------------------------------------------------------------
local function with_reason(text, ok, reason)
    if not ok then
        return text .. "\nUnavailable: " .. tostring(reason)
    end
    return text
end

local function monitor_row(key, entry)
    if type(entry) == "table" then
        if type(entry.name_s) == "string" then return entry.name_s end
        if type(entry.name) == "string" then return entry.name end
    end
    if type(key) == "string" then return key end
end

local function leader_row(_, entry)
    if type(entry) == "table" and type(entry.name) == "string" then return entry.name end
end

local TOOLTIPS = {
    RRLookup = function() return "Uses rank data from the poller CSV." end,
    RRStatus = function()
        local text, _, reason = C.csv_status_text()
        return reason or text
    end,
    Refresh = function()
        local rr_const = AutoBand._realmrank_module and AutoBand._realmrank_module.const or {}
        return "Seconds between reloads (" .. tostring(rr_const.REALMRANK_REFRESH_MIN_SECONDS or 60) .. "-" ..
            tostring(rr_const.REALMRANK_REFRESH_MAX_SECONDS or 1800) .. ")."
    end,
    RefreshNow = function() return "Reloads rank data now." end,
    StatsMonitor = function()
        local text = "Reports population changes over the threshold."
        if not saved("realmstats_enabled") then
            local ok, _, reason = C.stats_gate()
            text = with_reason(text, ok, reason)
        end
        return text
    end,
    Threshold = function() return "Shift % that triggers a report." end,
    WBLeadNotify = function()
        local text = "Prints when WB leaders change."
        if AutoBand.is_warband_enabled() ~= true then
            text = text .. "\nInactive while warband features are off."
        end
        return text
    end,
    WBLeadMin = function() return "Smallest warband counted." end,
    WBLeaderTellAlert = function() return "Highlights tells from WB leaders while you lead." end,
    Group = function() return "Monitored groups come first, marked [M]." end,
    -- section headings
    StatsHeader = function() return "Online population from the realm-rank CSV." end,
    LeadersHeader = function() return "Tracks open warbands and their leaders." end,
    GroupsHeader = function() return "Online checks for Enemy addon mark groups." end,
    DataHeader = function() return "Rank data CSV written by the poller." end,
    Monitor = function()
        local choice = selected_choice()
        local text = "Watches when this group's members are online."
        if not choice then
            return text .. "\nUnavailable: Choose a group."
        end
        if not is_monitored(choice.key) then
            local ok, _, reason = C.online_gate()
            if not choice.available then
                ok, reason = false, "Enemy no longer lists this group."
            end
            text = with_reason(text, ok, reason)
        end
        return text
    end,
    DefaultGroup = function()
        local choice = selected_choice()
        local text = "Default group for online checks."
        if not choice then
            return text .. "\nUnavailable: Choose a group."
        end
        if choice.key ~= default_key() then
            local ok, _, reason = C.online_gate()
            if not choice.available then
                ok, reason = false, "Enemy no longer lists this group."
            end
            text = with_reason(text, ok, reason)
        end
        return text
    end,
    GroupList = function()
        return C.small_list_tooltip("Lists monitored groups.", AutoBand.online_monitor_groups, monitor_row)
    end,
    GroupCheck = function()
        local choice = selected_choice()
        local ok, _, reason = C.online_gate()
        if choice and not choice.available then
            ok, reason = false, "Enemy no longer lists this group."
        elseif not choice then
            ok, reason = false, "Choose a group."
        end
        return with_reason("Shows who in the group is online.", ok, reason)
    end,
    GroupRefresh = function() return "Reloads group names." end,
    Stats = function()
        local ok, reason = ACTIONS.StatsButton()
        return with_reason("Shows realm population.\nRight-click: monitored names online.", ok, reason)
    end,
    StatsBreakdown = function()
        local ok, reason = ACTIONS.StatsButton()
        return with_reason("Population by tier.\nRight-click: with careers.", ok, reason)
    end,
    WBLeaders = function()
        local entries = type(AutoBand.WBLeaders) == "table" and AutoBand.WBLeaders.last_entries or nil
        return C.small_list_tooltip("Lists warband leaders.", entries, leader_row, "WB leaders (last check):")
    end,
}

local function tooltip_for(control)
    if control == nil then
        return nil
    end
    local base = string.gsub(control, "DisabledHover$", "")
    base = string.gsub(base, "CheckBox$", "")
    base = string.gsub(base, "ComboBox$", "")
    base = string.gsub(base, "EditBox$", "")
    base = string.gsub(base, "ValueLabel$", "")
    base = string.gsub(base, "StatusLabel$", "Status")
    base = string.gsub(base, "Label$", "")
    base = string.gsub(base, "Link$", "")
    base = string.gsub(base, "ApplyButton$", "")
    base = string.gsub(base, "Button$", "")
    base = string.gsub(base, "^ButtonPlus", "")
    base = string.gsub(base, "^ButtonMinus", "")
    local text = TOOLTIPS[base]
    if base == "GroupStatus" then
        return AutoBandWindowRealm.group_status_full
    end
    if text == nil then
        return nil
    end
    return text()
end

function AutoBandWindowRealm.OnControlMouseOver()
    C.show_tooltip(tooltip_for(C.control(P)))
end

function AutoBandWindowRealm.OnControlMouseOverEnd()
    C.hide_tooltip()
end

function AutoBandWindowRealm.OnLinkMouseOver()
    local control = C.control(P)
    if control and link_state[control] then
        LabelSetTextColor(P .. control, LINK_HOVER[1], LINK_HOVER[2], LINK_HOVER[3])
    end
    C.show_tooltip(tooltip_for(control))
end

function AutoBandWindowRealm.OnLinkMouseOverEnd()
    local control = C.control(P)
    if control and link_state[control] ~= nil then
        set_link(control, link_state[control])
    end
    C.hide_tooltip()
end
