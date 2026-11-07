AutoBandWindow = {}

AutoBandWindow.name = "AutoBandWindow"
AutoBandWindow.mapicon_name = "AutoBandMapIcon"
AutoBandWindow.warband_disabled_label_name = AutoBandWindow.name .. "WarbandDisabledLabel"

AutoBandWindow.SelectedTab = AB_const.TABS_TOOLS

-- Original tabs in their original order (Tools opens by default), plus Realm.
-- `page` is the AutoBand.reset_settings_page key.
AutoBandWindow.Tabs = {}
AutoBandWindow.Tabs[AB_const.TABS_TEMPLATE] = { button = "AutoBandWindowTabsTemplate", label = "Templates", page = "templates", module = AutoBandWindowTemplate }
AutoBandWindow.Tabs[AB_const.TABS_TOOLS] = { button = "AutoBandWindowTabsTools", label = "Tools", page = "tools", module = AutoBandWindowTools }
AutoBandWindow.Tabs[AB_const.TABS_CONFIG] = { button = "AutoBandWindowTabsConfig", label = "Config", page = "config", module = AutoBandWindowConfig }
AutoBandWindow.Tabs[AB_const.TABS_REALM] = { button = "AutoBandWindowTabsRealm", label = "Realm", page = "realm", module = AutoBandWindowRealm }

-- Window size per tab: 600 wide; height = 134 + 4 + content + 6 + 72 footer
-- (content heights come from the page XML layout).
AutoBandWindow.WIDTH = 600
AutoBandWindow.PAGE_HEIGHTS = {
    [AB_const.TABS_TEMPLATE] = 980,
    [AB_const.TABS_TOOLS] = 885,
    [AB_const.TABS_CONFIG] = 1042,
    [AB_const.TABS_REALM] = 763,
}

-- Shell footer controls (hidden on Templates, which has its original footer).
local FOOTER = { "PageDefaultsButton", "PresetLabel", "VersionLabel" }

local C = AutoBandWindowCommon
local PM_CHECK = AutoBandWindow.name .. "PmBlockCheckBox"
local PM_LABEL = AutoBandWindow.name .. "PmBlockLabel"
local WB_CHECK = AutoBandWindow.name .. "WarbandCheckBox"
local WB_LABEL = AutoBandWindow.name .. "WarbandLabel"
local PRESET_LABEL = AutoBandWindow.name .. "PresetLabel"

local function is_warband_disabled()
    return type(AutoBand) == "table"
        and type(AutoBand.is_warband_enabled) == "function"
        and not AutoBand.is_warband_enabled()
end

local function window_exists(name)
    if type(DoesWindowExist) ~= "function" then
        return true
    end
    local ok, exists = pcall(DoesWindowExist, name)
    return ok and exists == true
end

function AutoBandWindow.showing()
    return WindowGetShowing(AutoBandWindow.name)
end

function AutoBandWindow.RefreshWarbandEnabledState()
    local disabled = is_warband_disabled()
    local title_label_name = AutoBandWindow.name .. "TitleBarText"
    if not window_exists(title_label_name) or not window_exists(AutoBandWindow.warband_disabled_label_name) then
        return false
    end
    LabelSetText(title_label_name, disabled and L"AutoBand - WB OFF" or L"AutoBand")
    LabelSetText(AutoBandWindow.warband_disabled_label_name, L"WB OFF")
    LabelSetTextColor(AutoBandWindow.warband_disabled_label_name, 255, 128, 64)
    WindowSetShowing(AutoBandWindow.warband_disabled_label_name, disabled)
    return true
end

-- Global strip: Block AutoBand PMs and Warband features, on every page.
function AutoBandWindow.RefreshGlobalStrip()
    if not window_exists(PM_CHECK) or not AutoBandWindow.showing() then
        return false
    end
    local blocking = AutoBand.is_pm_block_active()
    C.check(PM_CHECK, blocking)
    C.label(PM_LABEL, "Block AutoBand PMs", blocking and C.WARN or C.TEXT)
    C.check(WB_CHECK, not is_warband_disabled())
    C.label(WB_LABEL, "Warband features", C.TEXT)
    AutoBandWindow.RefreshWarbandEnabledState()
    return true
end

local function preset_name()
    local name = AutoBand.template_active_key
    if (name == nil or name == "") and type(AutoBand.saved) == "table" then
        name = AutoBand.saved.active_template_selection
    end
    if name == nil or name == "" then
        name = AB_const.EMPTY_TEMPLATE
    end
    return tostring(name)
end

-- "(modified)" is shown only for a named saved preset: <Automatic> is not a saved
-- preset, so the footer never flags it (display only; the real dirty flags and Save
-- availability are left as they are).
local function preset_shows_modified()
    local modified = AutoBand.template_settings_dirty == true or
        (type(AutoBandWindowTemplate) == "table" and AutoBandWindowTemplate.modified == true)
    return modified and preset_name() ~= AB_const.EMPTY_TEMPLATE
end

-- The footer label is 264 wide (font_clear_small); long template names are shortened
-- with "..." until the measured text fits 256 (C.fit_text: cached, bounded). Without
-- text measuring the name is cut to 16 characters. The tooltip shows the full text.
local PRESET_FIT = { max_w = 256, fallback_chars = 16, cache = {} }
local PRESET_W, VERSION_W = 264, 80

local function fitted_preset_text(name, suffix)
    return C.fit_text(PRESET_LABEL, "Preset: ", name, suffix, PRESET_FIT)
end

function AutoBandWindow.RefreshPresetLabel()
    if not window_exists(PRESET_LABEL) or not AutoBandWindow.showing() then
        return false
    end
    local modified = preset_shows_modified()
    local suffix = modified and " (modified)" or ""
    C.label(PRESET_LABEL, fitted_preset_text(preset_name(), suffix), modified and C.WARN or C.DIM)
    C.match_text_height(PRESET_LABEL, PRESET_W)
    return true
end

function AutoBandWindow.Initialize()
    AutoBandWindow.RefreshWarbandEnabledState()
    for _, tab in ipairs(AutoBandWindow.Tabs) do
        ButtonSetText(tab.button, towstring(tab.label))
    end
    ButtonSetCheckButtonFlag(PM_CHECK, true)
    ButtonSetCheckButtonFlag(WB_CHECK, true)
    ButtonSetText(AutoBandWindow.name .. "PageDefaultsButton", L"Restore Defaults")
    LabelSetText(AutoBandWindow.name .. "VersionLabel", L"v" .. towstring(AB_const.VERSION))
    C.match_text_height(AutoBandWindow.name .. "VersionLabel", VERSION_W)
    WindowSetShowing(AutoBandWindow.mapicon_name, AutoBand.saved.displayicon == true)
    AutoBandWindow.show_selected_tab()
end

function AutoBandWindow.Hide()
    WindowSetShowing(AutoBandWindow.name, false)
end

function AutoBandWindow.Show()
    WindowSetShowing(AutoBandWindow.name, true)
    AutoBandWindow.show_selected_tab()
end

-- Fit the window to the tab while keeping its top edge where it is: re-anchor the
-- top-left corner to Root at the current position (screen pixels / window scale,
-- verified natively), then set the new height.
function AutoBandWindow.ApplyTabHeight()
    local height = AutoBandWindow.PAGE_HEIGHTS[AutoBandWindow.SelectedTab] or AutoBandWindow.PAGE_HEIGHTS[AB_const.TABS_TOOLS]
    if type(WindowGetDimensions) == "function" then
        local ok_dim, _, current = pcall(WindowGetDimensions, AutoBandWindow.name)
        if ok_dim and tonumber(current) == height then
            return
        end
    end
    if type(WindowGetScreenPosition) == "function" and type(WindowGetScale) == "function" then
        local ok_pos, x, y = pcall(WindowGetScreenPosition, AutoBandWindow.name)
        local ok_scale, scale = pcall(WindowGetScale, AutoBandWindow.name)
        scale = tonumber(scale)
        if ok_pos and ok_scale and tonumber(x) and tonumber(y) and scale and scale > 0 then
            WindowClearAnchors(AutoBandWindow.name)
            WindowAddAnchor(AutoBandWindow.name, "topleft", "Root", "topleft", tonumber(x) / scale, tonumber(y) / scale)
        end
    end
    WindowSetDimensions(AutoBandWindow.name, AutoBandWindow.WIDTH, height)
end

-- Exactly one page visible; its tab pressed. Page Show() is the page entry: it also
-- loads edit boxes from the saved values.
function AutoBandWindow.show_selected_tab()
    if AutoBandWindow.Tabs[AutoBandWindow.SelectedTab] == nil then
        AutoBandWindow.SelectedTab = AB_const.TABS_TOOLS
    end
    AutoBandWindow.ApplyTabHeight()
    local shell_footer = AutoBandWindow.SelectedTab ~= AB_const.TABS_TEMPLATE
    for _, control in ipairs(FOOTER) do
        WindowSetShowing(AutoBandWindow.name .. control, shell_footer)
    end
    for index, tab in ipairs(AutoBandWindow.Tabs) do
        if index ~= AutoBandWindow.SelectedTab then
            tab.module.Hide()
        end
        ButtonSetPressedFlag(tab.button, index == AutoBandWindow.SelectedTab)
    end
    AutoBandWindow.Tabs[AutoBandWindow.SelectedTab].module.Show()
    AutoBandWindow.RefreshGlobalStrip()
    AutoBandWindow.RefreshPresetLabel()
end

-- Redraw the visible page, strip and footer after a setting changed elsewhere (slash
-- command, preset load, promotion). A hidden window is redrawn on its next Show().
function AutoBandWindow.RefreshVisiblePage(opts)
    if not window_exists(AutoBandWindow.name) or not AutoBandWindow.showing() then
        return false
    end
    AutoBandWindow.RefreshGlobalStrip()
    AutoBandWindow.RefreshPresetLabel()
    local tab = AutoBandWindow.Tabs[AutoBandWindow.SelectedTab]
    if tab and type(tab.module.Refresh) == "function" then
        tab.module.Refresh(type(opts) == "table" and opts or {})
    end
    return true
end

-- CHANNEL_NAMES_UPDATED: only the visible page's channel-gated controls.
function AutoBandWindow.RefreshChannelControls()
    if not window_exists(AutoBandWindow.name) or not AutoBandWindow.showing() then
        return false
    end
    if AutoBandWindow.SelectedTab == AB_const.TABS_TOOLS then
        AutoBandWindowTools.RefreshSearchChannelControls()
        AutoBandWindowTools.RefreshActionButtons()
    end
    return true
end

-- Group/warband/vote lifecycle events: only the visible page's action buttons.
function AutoBandWindow.RefreshActionAvailability()
    if not window_exists(AutoBandWindow.name) or not AutoBandWindow.showing() then
        return false
    end
    if AutoBandWindow.SelectedTab == AB_const.TABS_TOOLS then
        AutoBandWindowTools.RefreshActionButtons()
    elseif AutoBandWindow.SelectedTab == AB_const.TABS_TEMPLATE then
        AutoBandWindowTemplate.RefreshActionButtons()
    elseif AutoBandWindow.SelectedTab == AB_const.TABS_REALM then
        AutoBandWindowRealm.RefreshActionButtons()
    end
    return true
end

function AutoBandWindow.SelectTab(index)
    if AutoBandWindow.Tabs[index] == nil then
        return
    end
    AutoBandWindow.SelectedTab = index
    if AutoBandWindow.showing() then
        AutoBandWindow.show_selected_tab()
    else
        AutoBandWindow.Show()
    end
end

function AutoBandWindow.OnLButtonUpTab()
    AutoBandWindow.SelectTab(WindowGetId(SystemData.ActiveWindow.name))
end

-- Promotion safety popup ("Open Config") lands here.
function AutoBandWindow.ShowConfigTab()
    AutoBandWindow.SelectTab(AB_const.TABS_CONFIG)
end

function AutoBandWindow.toggle_mapicon(value)
    if value == nil then
        AutoBand.saved.displayicon = not WindowGetShowing(AutoBandWindow.mapicon_name)
    else
        AutoBand.saved.displayicon = value == true
    end
    WindowSetShowing(AutoBandWindow.mapicon_name, AutoBand.saved.displayicon == true)
end

-- Global strip handlers ----------------------------------------------------------
function AutoBandWindow.OnPmBlockCheckBox()
    AutoBand.set_block_outgoing_pms(ButtonGetPressedFlag(PM_CHECK) == true)
    AutoBandWindow.RefreshGlobalStrip()
end

function AutoBandWindow.OnClickPmBlockLabel()
    C.label_toggle(PM_CHECK, AutoBandWindow.OnPmBlockCheckBox)
end

function AutoBandWindow.OnPmBlockMouseOver()
    C.show_tooltip("Stops AutoBand's outgoing PMs. Enable if its tells trigger mutes.")
end

function AutoBandWindow.OnWarbandCheckBox()
    AutoBand.set_warband_enabled(ButtonGetPressedFlag(WB_CHECK) == true)
    AutoBandWindow.RefreshVisiblePage()
end

function AutoBandWindow.OnClickWarbandLabel()
    C.label_toggle(WB_CHECK, AutoBandWindow.OnWarbandCheckBox)
end

function AutoBandWindow.OnWarbandMouseOver()
    C.show_tooltip("Turns on auto-kick, organizing and adverts.")
end

function AutoBandWindow.OnStripMouseOverEnd()
    C.hide_tooltip()
end

function AutoBandWindow.OnWarbandDisabledMouseOver()
    if not is_warband_disabled() then
        return
    end
    C.show_tooltip("Warband features are off. Right-click for the menu.")
end

function AutoBandWindow.OnWarbandDisabledMouseOverEnd()
    C.hide_tooltip()
end

function AutoBandWindow.OnWarbandDisabledRightClick()
    if not is_warband_disabled() then
        return
    end
    C.hide_tooltip()
    if type(AutoBand) == "table" and type(AutoBand.HandleIconRightClick) == "function" then
        AutoBand.HandleIconRightClick({ include_open_window = false })
    end
end

-- Footer ----------------------------------------------------------------------------
function AutoBandWindow.OnPageDefaults()
    local tab = AutoBandWindow.Tabs[AutoBandWindow.SelectedTab]
    if not tab then
        return
    end
    if type(tab.module.BeforePageDefaults) == "function" then
        tab.module.BeforePageDefaults()
    end
    AutoBand.reset_settings_page(tab.page)
    AutoBandWindow.RefreshVisiblePage({ prefix_text_changed = true, distance_changed = true, refresh_text_changed = true })
end

local PAGE_DEFAULTS_TIPS = {
    tools = "settings",
    config = "settings",
    realm = "settings (not markgroups)",
}

function AutoBandWindow.OnPageDefaultsMouseOver()
    local tab = AutoBandWindow.Tabs[AutoBandWindow.SelectedTab]
    local scope = tab and PAGE_DEFAULTS_TIPS[tab.page] or "this page"
    C.show_tooltip("Resets this tab's " .. scope .. ".")
end

function AutoBandWindow.OnPresetLabelClick()
    AutoBandWindow.SelectTab(AB_const.TABS_TEMPLATE)
end

function AutoBandWindow.OnPresetLabelMouseOver()
    C.show_tooltip("Opens Templates; preset " .. preset_name() .. (preset_shows_modified() and " (modified)" or "") .. ".")
end

-- Tabs and version: one short line each.
local TAB_TIPS = {
    templates = "Layouts, role caps and placement.",
    tools = "Kick, search and organize.",
    config = "Composition, auto-kick, social and chat.",
    realm = "Realm stats, WB leaders, markgroups, rank data.",
}

function AutoBandWindow.OnTabMouseOver()
    local name = C.active_window()
    for _, tab in ipairs(AutoBandWindow.Tabs) do
        if tab.button == name then
            C.show_tooltip(TAB_TIPS[tab.page])
        end
    end
end

function AutoBandWindow.OnVersionMouseOver()
    C.show_tooltip("AutoBand version.")
end

function AutoBandWindow.OnFooterMouseOverEnd()
    C.hide_tooltip()
end
