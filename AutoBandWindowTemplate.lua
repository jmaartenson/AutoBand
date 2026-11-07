-- AutoBand Templates tab: templates and the four-group layout, Warband Role
-- Composition (the cap values), Placement and Organize (with the icon options),
-- with the original Save / Delete / Apply footer.
AutoBandWindowTemplate = {}

AutoBandWindowTemplate.name = "AutoBandWindowTemplateTab"
AutoBandWindowTemplate.combobox_name = AutoBandWindowTemplate.name .. "ComboBox"
AutoBandWindowTemplate.applybutton_name = AutoBandWindowTemplate.name .. "ApplyButton"
AutoBandWindowTemplate.orgbutton_name = AutoBandWindowTemplate.name .. "OrgButton"
AutoBandWindowTemplate.orgselectedbutton_name = AutoBandWindowTemplate.name .. "OrgSelectedButton"
AutoBandWindowTemplate.deletebutton_name = AutoBandWindowTemplate.name .. "DeleteButton"
AutoBandWindowTemplate.savebutton_name = AutoBandWindowTemplate.name .. "SaveButton"
AutoBandWindowTemplate.defaultcheckbox_name = AutoBandWindowTemplate.name .. "DefaultCheckBox"
AutoBandWindowTemplate.rightclicktemplatecheckbox_name = AutoBandWindowTemplate.name .. "RightClickTemplateMenuCheckBox"

AutoBandWindowTemplate.group_roles = {}
AutoBandWindowTemplate.group_checkbox = {}
AutoBandWindowTemplate.modified = false
AutoBandWindowTemplate.combo_items = {}
AutoBandWindowTemplate.role_limit_warning_text = nil
AutoBandWindowTemplate.role_limit_warning_flags = { tank = false, healer = false, dps = false }

local C = AutoBandWindowCommon
local P = AutoBandWindowTemplate.name
local refreshing = false
local refresh_placement -- defined with the placement handlers below

-- Layout grid geometry (page coordinates; window y = page y + 134): four columns 138
-- wide from x 24, slots 120 wide centred in them (x 33 + 138n). Under the template
-- dropdown row: captions 74-98, six slots of 26 from 98, include checkboxes centred in
-- the 28 row from 254 (y 257), then 8 padding. The layout summary (RolesLabel) sits
-- right-aligned on the Warband Role Composition header row.
AutoBandWindowTemplate.GRID = { x = 33, col = 138, caption_y = 74, first_row_y = 98, box_y = 257, row = 26, slot_w = 120, slot_h = 24 }

-- Organizer focus (Aggregate spreads this role across groups), see AB_template.
AutoBandWindowTemplate.focus_roles = {
    { role = AB_const.HEALER, label = "Healer" },
    { role = AB_const.TANK, label = "Tank" },
    { role = AB_const.MDPS, label = "mDPS" },
    { role = AB_const.RDPS, label = "rDPS" },
}
AutoBandWindowTemplate.algo_modes = {
    { mode = AB_const.MODE_SPREAD, label = "Spread" },
    { mode = AB_const.MODE_AGGREGATE, label = "Aggregate" },
}

local TEMPLATE_LABEL_NORMAL = C.DIM   -- header status: small, dim
local TEMPLATE_LABEL_WARNING = C.WARN -- amber while the layout goes over a cap

local function template_get_tooltip_window_name()
    if SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name then
        return SystemData.ActiveWindow.name
    end
    if SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name then
        return SystemData.MouseOverWindow.name
    end
    return nil
end

local function template_get_tooltip_font_linespacing()
    if type(WindowUtils) == "table" and tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING) ~= nil then
        return tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
    end
    return 20
end

local function template_apply_small_tooltip_font()
    if type(LabelSetFont) ~= "function" then
        return
    end
    local linespacing = template_get_tooltip_font_linespacing()
    LabelSetFont("DefaultTooltipRow1Col1Text", "font_clear_small", linespacing)
    LabelSetFont("DefaultTooltipRow1Col2Text", "font_clear_small", linespacing)
    LabelSetFont("DefaultTooltipRow1Col3Text", "font_clear_small", linespacing)
end

local function template_restore_tooltip_font()
    if type(LabelSetFont) ~= "function" then
        return
    end
    local linespacing = template_get_tooltip_font_linespacing()
    LabelSetFont("DefaultTooltipRow1Col1Text", "font_default_text", linespacing)
    LabelSetFont("DefaultTooltipRow1Col2Text", "font_default_text", linespacing)
    LabelSetFont("DefaultTooltipRow1Col3Text", "font_default_text", linespacing)
end

local function template_show_text_tooltip(tooltip_text)
    if type(Tooltips) ~= "table" or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    local window_name = template_get_tooltip_window_name()
    if not window_name or window_name == "" then
        return
    end
    local tooltip_value = tooltip_text
    if type(tooltip_value) == "string" then
        tooltip_value = towstring(tooltip_value)
    end
    if type(Tooltips.SetTooltipText) == "function" then
        Tooltips.CreateTextOnlyTooltip(window_name)
        template_apply_small_tooltip_font()
        Tooltips.SetTooltipText(1, 1, tooltip_value)
        if type(Tooltips.Finalize) == "function" then
            Tooltips.Finalize()
        end
    else
        Tooltips.CreateTextOnlyTooltip(window_name, tooltip_value)
    end
    if type(Tooltips.AnchorTooltip) == "function" then
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
    end
end

local function template_hide_text_tooltip()
    if type(Tooltips) ~= "table" or type(Tooltips.DestroyTooltip) ~= "function" then
        return
    end
    local window_name = template_get_tooltip_window_name()
    if not window_name or window_name == "" then
        return
    end
    template_restore_tooltip_font()
    Tooltips.DestroyTooltip(window_name)
end

local template_control_tooltips = {
    ComboBoxLabel = "Saved group layouts and role settings.",
    RolesHeader = "Role caps for the whole warband.",
    PlacementHeader = "How Organize places players into groups.",
    OrganizeHeader = "Organize actions and icon menu options.",
    ComboBox = "Template to edit or use.",
    DefaultCheckBox = "Template used by Organize WB.",
    DefaultLabel = "Template used by Organize WB.",
    OrgSelectedButton = "Organizes with the selected template.",
    OrgButton = "Organizes with the default template.",
    RightClickTemplateMenuCheckBox = "Adds templates to the icon menu.",
    RightClickTemplateMenuLabel = "Adds templates to the icon menu.",
    SaveButton = "Saves the layout and settings as a template.",
    ApplyButton = "Organizes using this layout.",
    MapIconCheckBox = "Shows the AutoBand icon.",
    MapIconLabel = "Shows the AutoBand icon.",
    AlgoLabel = "Spread evens roles out; Aggregate fills groups.",
    AlgoComboBox = "Spread evens roles out; Aggregate fills groups.",
    FocusLabel = "Keeps a role even across groups (Aggregate).",
    FocusComboBox = "Keeps a role even across groups (Aggregate).",
    GuildGroupingCheckBox = "Groups members of your guild together where possible.",
    GuildGroupingLabel = "Groups members of your guild together where possible.",
    DistanceLabel = "Distance used by right-click Organize.",
    DistanceEditBox = "Distance used by right-click Organize.",
    DistanceApplyButton = "Distance used by right-click Organize.",
}

local template_role_limit_tooltips = {
    RolesLabel = "Roles in this layout vs. the caps.",
}

local CAP_TIPS = {
    Tanks = "Tank cap (caps total 24).",
    Healers = "Healer cap (caps total 24).",
    Dps = "DPS cap (caps total 24).",
}
local CAP_ALIASES = {
    TanksLabel = "Tanks", TanksValueLabel = "Tanks", ButtonPlusTanks = "Tanks", ButtonMinusTanks = "Tanks",
    HealersLabel = "Healers", HealersValueLabel = "Healers", ButtonPlusHealers = "Healers", ButtonMinusHealers = "Healers",
    DpsLabel = "Dps", DpsValueLabel = "Dps", ButtonPlusDps = "Dps", ButtonMinusDps = "Dps",
}

local function template_get_control_name_from_active_window()
    local window_name = template_get_tooltip_window_name()
    if type(window_name) ~= "string" or window_name == "" then
        return nil
    end
    local prefix = AutoBandWindowTemplate.name
    if string.sub(window_name, 1, string.len(prefix)) ~= prefix then
        return nil
    end
    return string.sub(window_name, string.len(prefix) + 1)
end

local function template_delete_button_tooltip_text()
    local selected = AutoBandWindowTemplate.selected_combobox()
    if AutoBandWindowTemplate.is_special_template(selected) then
        return "Resets the caps to defaults."
    end
    return "Deletes the selected template."
end

-- Action gates (cheap; same permissions as the core commands).
local function warband_enabled()
    return AutoBand.is_warband_enabled() == true
end

local ACTIONS = {}

function ACTIONS.ApplyButton()
    if AutoBandWindowTemplate.selected_combobox() == AB_const.CURRENT_WB then
        return false, "Already the current warband."
    end
    if not warband_enabled() then
        return false, "Warband features are off."
    end
    if not (AutoBand.is_wb_leader() == true or AutoBand.debugon == true) then
        return false, "Leader only."
    end
    return true
end

function ACTIONS.OrgSelectedButton()
    local selected = AutoBandWindowTemplate.selected_combobox()
    local templates = type(AutoBand.saved.templates) == "table" and AutoBand.saved.templates or {}
    if AutoBandWindowTemplate.is_special_template(selected) or templates[selected] == nil then
        return false, "Select a saved template."
    end
    if not warband_enabled() then
        return false, "Warband features are off."
    end
    if not (AutoBand.is_wb_leader() == true or AutoBand.is_assistant() == true or AutoBand.debugon == true) then
        return false, "Leader or assistant only."
    end
    return true
end
-- Organize WB: same gate as the Tools button and /ab org (Warband features,
-- leader or assistant).
function ACTIONS.OrgButton()
    if not warband_enabled() then
        return false, "Warband features are off."
    end
    if not (AutoBand.is_wb_leader() == true or AutoBand.is_assistant() == true or AutoBand.debugon == true) then
        return false, "Leader or assistant only."
    end
    return true
end

function AutoBandWindowTemplate.RefreshActionButtons()
    for _, button in ipairs({ "ApplyButton", "OrgSelectedButton", "OrgButton" }) do
        local ok = ACTIONS[button]()
        ButtonSetDisabledFlag(P .. button, ok ~= true)
        WindowSetShowing(P .. button .. "DisabledHover", ok ~= true)
    end
end

local function template_tooltip_text_for_control(control_name)
    if control_name == "DeleteButton" then
        return template_delete_button_tooltip_text()
    end
    if control_name then
        control_name = string.gsub(control_name, "DisabledHover$", "")
    end
    local text = template_control_tooltips[control_name]
    if text == nil and control_name and CAP_ALIASES[control_name] then
        text = CAP_TIPS[CAP_ALIASES[control_name]]
    end
    local action = ACTIONS[control_name]
    if text and action then
        local ok, reason = action()
        if not ok then
            text = text .. "\nUnavailable: " .. tostring(reason)
        end
    end
    if text and (control_name == "FocusLabel" or control_name == "FocusComboBox") and
        AutoBand.saved.org_algo_mode ~= AB_const.MODE_AGGREGATE then
        text = text .. "\nUnavailable: Only used by Aggregate."
    end
    return text
end

local function template_show_control_tooltip(control_name)
    local text = template_tooltip_text_for_control(control_name)
    if type(text) == "string" and text ~= "" then
        template_show_text_tooltip(text)
    end
end

local function template_count_current_layout_roles()
    local counts = { tank = 0, healer = 0, mdps = 0, rdps = 0, dps = 0 }
    for gid = 1, AB_const.MAX_WB_GROUPS do
        local checkbox_name = AutoBandWindowTemplate.group_checkbox and AutoBandWindowTemplate.group_checkbox[gid]
        local role_group = AutoBandWindowTemplate.group_roles and AutoBandWindowTemplate.group_roles[gid]
        if checkbox_name and role_group and ButtonGetPressedFlag(checkbox_name) then
            for pid = 1, AB_const.GROUP_SIZE do
                local labelname = role_group[pid]
                local role = labelname and tostring(LabelGetText(labelname)) or nil
                if role == AB_const.TANK then
                    counts.tank = counts.tank + 1
                elseif role == AB_const.HEALER then
                    counts.healer = counts.healer + 1
                elseif role == AB_const.MDPS then
                    counts.mdps = counts.mdps + 1
                    counts.dps = counts.dps + 1
                elseif role == AB_const.RDPS then
                    counts.rdps = counts.rdps + 1
                    counts.dps = counts.dps + 1
                end
            end
        end
    end
    return counts
end

local function template_build_role_limit_warning()
    local saved = AutoBand.saved or {}
    local counts = template_count_current_layout_roles()
    local warning_flags = { tank = false, healer = false, dps = false }
    local issue_lines = {}

    local max_tanks = tonumber(saved.max_tanks) or 0
    local max_healers = tonumber(saved.max_healers) or 0
    local max_dps = tonumber(saved.max_dps) or 0

    if counts.tank > max_tanks then
        warning_flags.tank = true
        issue_lines[#issue_lines + 1] = string.format("Tanks %d/%d", counts.tank, max_tanks)
    end
    if counts.healer > max_healers then
        warning_flags.healer = true
        issue_lines[#issue_lines + 1] = string.format("Healers %d/%d", counts.healer, max_healers)
    end
    if counts.dps > max_dps then
        warning_flags.dps = true
        issue_lines[#issue_lines + 1] = string.format("DPS %d/%d", counts.dps, max_dps)
    end

    if saved.dps_weighting_enabled == true then
        local max_mdps = tonumber(saved.max_mdps) or 0
        local max_rdps = tonumber(saved.max_rdps) or 0
        if counts.mdps > max_mdps then
            warning_flags.dps = true
            issue_lines[#issue_lines + 1] = string.format("mDPS %d/%d", counts.mdps, max_mdps)
        end
        if counts.rdps > max_rdps then
            warning_flags.dps = true
            issue_lines[#issue_lines + 1] = string.format("rDPS %d/%d", counts.rdps, max_rdps)
        end
    end

    if #issue_lines == 0 then
        return nil, warning_flags
    end

    local lines = {
        "Layout exceeds the caps (layout/cap):",
    }
    for i = 1, #issue_lines do
        lines[#lines + 1] = issue_lines[i]
    end
    return table.concat(lines, "\n"), warning_flags
end

function AutoBandWindowTemplate.RefreshRightClickTemplateMenuState()
    local checkbox_name = AutoBandWindowTemplate.rightclicktemplatecheckbox_name
    local label_name = AutoBandWindowTemplate.name .. "RightClickTemplateMenuLabel"

    ButtonSetPressedFlag(checkbox_name, AutoBand.saved.right_click_organize_include_templates == true)
    ButtonSetDisabledFlag(checkbox_name, false)
    LabelSetTextColor(label_name, 225, 225, 225)
end


function AutoBandWindowTemplate.Initialize()
    C.label(P .. "ComboBoxLabel", "Templates", C.HEADER)
    C.label(P .. "RolesHeader", "Warband Role Composition", C.HEADER)
    C.label(P .. "PlacementHeader", "Placement", C.HEADER)
    C.label(P .. "OrganizeHeader", "Organize", C.HEADER)
    C.label(P .. "DefaultLabel", "Default", C.TEXT)
    C.label(P .. "TanksLabel", "Tanks", C.TEXT)
    C.label(P .. "HealersLabel", "Healers", C.TEXT)
    C.label(P .. "DpsLabel", "DPS", C.TEXT)
    C.label(P .. "MapIconLabel", "Show icon", C.TEXT)
    ButtonSetCheckButtonFlag(P .. "MapIconCheckBox", true)
    ButtonSetCheckButtonFlag(AutoBandWindowTemplate.defaultcheckbox_name, true)

    ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, true)
    ButtonSetText(AutoBandWindowTemplate.savebutton_name, L"Save")
    ButtonSetText(AutoBandWindowTemplate.deletebutton_name, L"Delete")
    ButtonSetText(AutoBandWindowTemplate.applybutton_name, L"Apply")
    ButtonSetText(AutoBandWindowTemplate.orgbutton_name, L"Organize WB")
    ButtonSetText(AutoBandWindowTemplate.orgselectedbutton_name, L"Organize WB (template)")
    C.label(P .. "RightClickTemplateMenuLabel", "Templates in icon menu", C.TEXT)
    ButtonSetCheckButtonFlag(AutoBandWindowTemplate.rightclicktemplatecheckbox_name, true)
    AutoBandWindowTemplate.RefreshRightClickTemplateMenuState()
    C.label(P .. "AlgoLabel", "Distribution Algorithm", C.TEXT)
    C.label(P .. "FocusLabel", "Spread role", C.TEXT)
    C.label(P .. "GuildGroupingLabel", "Group guildies together", C.TEXT)
    C.label(P .. "DistanceLabel", "Distance split (units)", C.TEXT)
    ButtonSetText(P .. "DistanceApplyButton", L"Apply")
    ButtonSetCheckButtonFlag(P .. "GuildGroupingCheckBox", true)
    refreshing = true
    ComboBoxClearMenuItems(P .. "AlgoComboBox")
    for _, entry in ipairs(AutoBandWindowTemplate.algo_modes) do
        ComboBoxAddMenuItem(P .. "AlgoComboBox", towstring(entry.label))
    end
    ComboBoxClearMenuItems(P .. "FocusComboBox")
    for _, entry in ipairs(AutoBandWindowTemplate.focus_roles) do
        ComboBoxAddMenuItem(P .. "FocusComboBox", towstring(entry.label))
    end
    refreshing = false

    -- add the empty template automatic
    AutoBand.saved.templates[AB_const.EMPTY_TEMPLATE] = nil

    -- mask down
    WindowSetShowing(AutoBandWindowTemplate.name .. "Mask", false)

    -- dynamic slot windows are created once per UI session
    if not AutoBandWindowTemplate.role_labels_created then
        AutoBandWindowTemplate.create_role_labels()
        AutoBandWindowTemplate.role_labels_created = true
    end

    AutoBandWindowTemplate.refresh_gui()
    -- Restore the remembered template selection instead of always snapping back to <Automatic>.
    local initial_selection = AB_const.EMPTY_TEMPLATE
    if AutoBand and type(AutoBand.restore_saved_template_selection) == "function" then
        initial_selection = AutoBand.restore_saved_template_selection()
    elseif AutoBand and type(AutoBand.saved) == "table" then
        initial_selection = AutoBand.saved.active_template_selection or AB_const.EMPTY_TEMPLATE
    end
    AutoBandWindowTemplate.set_combobox_item(initial_selection)
end

function AutoBandWindowTemplate.Hide()
    WindowSetShowing(AutoBandWindowTemplate.name, false)
end

function AutoBandWindowTemplate.Show()
    if AutoBand and AutoBand.template_settings_dirty == true then
        AutoBandWindowTemplate.modified = true
    end
    AutoBandWindowTemplate.Refresh({ distance_changed = true })
    WindowSetShowing(AutoBandWindowTemplate.name, true)
end

function AutoBandWindowTemplate.mark_modified(opts)
    opts = opts or {}
    AutoBandWindowTemplate.modified = true
    if type(ButtonSetDisabledFlag) == "function" then
        ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, false)
        if opts.enable_apply then
            AutoBandWindowTemplate.RefreshActionButtons()
        end
    end
end

-- default template checkbox pressed
function AutoBandWindowTemplate.OnDefaultCheckBox()
    if (ButtonGetDisabledFlag(AutoBandWindowTemplate.defaultcheckbox_name)) then
        return
    end

    -- global: never marks the preset modified
    local checked = ButtonGetPressedFlag(AutoBandWindowTemplate.defaultcheckbox_name)
    if (checked) then
        AutoBand.saved.default_template = AutoBandWindowTemplate.selected_combobox()
    else
        AutoBand.saved.default_template = AB_const.EMPTY_TEMPLATE
    end
end

function AutoBandWindowTemplate.OnClickDefaultLabel()
    C.label_toggle(AutoBandWindowTemplate.defaultcheckbox_name, AutoBandWindowTemplate.OnDefaultCheckBox)
end

function AutoBandWindowTemplate.is_special_template(name)
    return (name == AB_const.CURRENT_WB) or (name == AB_const.EMPTY_TEMPLATE)
end

-- Load and remember a template selection: restore its saved settings, then show its layout.
function AutoBandWindowTemplate.load_template(name)
    AB_util.debug("Loading: " .. name)
    if AutoBand then
        if type(AutoBand.remember_active_template_selection) == "function" then
            name = AutoBand.remember_active_template_selection(name)
        else
            AutoBand.template_active_key = name
        end
    end

    -- check if it's the default
    ButtonSetPressedFlag(AutoBandWindowTemplate.defaultcheckbox_name, name == AutoBand.saved.default_template)

    local temp = nil
    local is_special = AutoBandWindowTemplate.is_special_template(name)
    ButtonSetDisabledFlag(AutoBandWindowTemplate.defaultcheckbox_name, is_special)
    if (is_special) then
        if (name == AB_const.CURRENT_WB) then
            temp = AB_template.from_wb(AutoBand.get_wb())
        elseif (name == AB_const.EMPTY_TEMPLATE) then
            if type(AutoBand.restore_normal_template_settings) == "function" then
                AutoBand.restore_normal_template_settings({ silent = true, template_name = name })
            end
            temp = AB_const.EMPTY_WB_TEMPLATE
        end
        ButtonSetText(AutoBandWindowTemplate.deletebutton_name, L"Reset")
    else
        temp = AutoBand.saved.templates[name]
        if type(AutoBand.apply_template_settings) == "function" then
            AutoBand.apply_template_settings(temp, { silent = true, template_name = name })
        end
        if type(AutoBand.template_get_layout) == "function" then
            temp = AutoBand.template_get_layout(temp)
        end
        ButtonSetText(AutoBandWindowTemplate.deletebutton_name, L"Delete")
    end

    if (temp) then
        for gid = 1, AB_const.MAX_WB_GROUPS do
            for pid = 1, AB_const.GROUP_SIZE do
                local labelname = AutoBandWindowTemplate.group_roles[gid][pid]
                if (temp[gid][pid] == nil) then
                    AutoBandWindowTemplate.set_role_label(labelname, AB_const.LABEL_EMPTY)
                else
                    AutoBandWindowTemplate.set_role_label(labelname, temp[gid][pid].role)
                end
            end
        end
    end

    AutoBandWindowTemplate.modified = false
    if AutoBand then
        AutoBand.template_settings_dirty = false
    end
    ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, true)
    AutoBandWindowTemplate.refresh_role_limits()
    AutoBandWindowTemplate.RefreshActionButtons()
    refresh_placement({ distance_changed = true })
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshVisiblePage) == "function" then
        AutoBandWindow.RefreshVisiblePage({ prefix_text_changed = true, distance_changed = true })
    end
end

-- load selected template from combobox selected (index 0 comes from clearing the list)
function AutoBandWindowTemplate.OnSelChangedComboBox()
    if refreshing then
        return
    end
    local index = ComboBoxGetSelectedMenuItem(AutoBandWindowTemplate.combobox_name)
    if type(index) ~= "number" or index < 1 then
        return
    end
    AutoBandWindowTemplate.load_template(AutoBandWindowTemplate.selected_combobox())
end

-- Save the current editor layout together with the current settings preset.
function AutoBandWindowTemplate.OnSaveTemplate()
    if (ButtonGetDisabledFlag(AutoBandWindowTemplate.savebutton_name)) then
        return
    end

    -- mask up
    WindowSetShowing(AutoBandWindowTemplate.name .. "Mask", true)

    AutoBandWindowTemplateSave.ShowModal(
        -- this get called back if the user pressed OK and typed something
        function(name)
            -- save in AutoBand.saved.templates
            if type(AutoBand.build_template_snapshot) == "function" then
                AutoBand.saved.templates[name] = AutoBand.build_template_snapshot(AutoBandWindowTemplate.get_template_from_labels())
            else
                AutoBand.saved.templates[name] = AutoBandWindowTemplate.get_template_from_labels()
            end
            -- reset checkboxes
            for gid = 1, AB_const.MAX_WB_GROUPS do
                ButtonSetPressedFlag(AutoBandWindowTemplate.group_checkbox[gid], true)
            end
            AutoBandWindowTemplate.modified = false
            if AutoBand then
                AutoBand.template_settings_dirty = false
            end
            -- refresh
            AutoBandWindowTemplate.refresh_gui()
            AutoBandWindowTemplate.set_combobox_item(name)
        end
    )
end

-- delete template
function AutoBandWindowTemplate.OnDeleteTemplate()
    if (ButtonGetDisabledFlag(AutoBandWindowTemplate.deletebutton_name)) then
        return
    end

    local sel = AutoBandWindowTemplate.selected_combobox()
    if (AutoBandWindowTemplate.is_special_template(sel)) then
        -- we will refresh if it's <warband> or reset if it's <automatic>, in any case just reload them
        -- Only reset the role composition counts if they are not already default.
        if not (AutoBand.saved.max_tanks == AB_const.DEFAULT_MAX_TANKS and
                AutoBand.saved.max_healers == AB_const.DEFAULT_MAX_HEALERS and
                AutoBand.saved.max_dps == AB_const.DEFAULT_MAX_DPS)
        then
            AutoBand.cmd_resetroles({})
        end
        AutoBandWindowTemplate.load_template(sel)
        return
    end
    AB_util.debug("Deleting: " .. sel)
    if (AutoBand.saved.templates[sel] ~= nil) then
        local function delete_selected_template(template_name)
            if (AutoBand.saved.templates[template_name] ~= nil) then
                AutoBand.saved.templates[template_name] = nil
                if (AutoBand.saved.default_template == template_name) then
                    AutoBand.saved.default_template = AB_const.EMPTY_TEMPLATE
                end
                if AutoBand and type(AutoBand.remember_active_template_selection) == "function" then
                    AutoBand.remember_active_template_selection(AB_const.EMPTY_TEMPLATE)
                elseif AutoBand then
                    AutoBand.template_active_key = AB_const.EMPTY_TEMPLATE
                end
                AutoBandWindowTemplate.refresh_gui()
                AutoBandWindowTemplate.set_combobox_item(AB_const.EMPTY_TEMPLATE)
            end
        end

        if type(AutoBandWindowTemplateDeleteConfirm) == "table" and type(AutoBandWindowTemplateDeleteConfirm.ShowModal) == "function" then
            AutoBandWindowTemplateDeleteConfirm.ShowModal(sel, delete_selected_template)
        else
            delete_selected_template(sel)
        end
    end
end

-- Apply the current editor layout only and organize the live warband.
-- This does not reload saved preset settings from the selected template entry.
function AutoBandWindowTemplate.OnApplyTemplate()
    local ok, reason = ACTIONS.ApplyButton()
    if not ok then
        AutoBandWindowTemplate.RefreshActionButtons()
        AB_util.debug("Groups action unavailable: " .. tostring(reason))
        return
    end
    AB_org.auto_organize(AutoBandWindowTemplate.get_template_from_labels())
end

-- organize using normal /ab org behavior (default template path)
function AutoBandWindowTemplate.OnOrganize()
    if not ACTIONS.OrgButton() then
        AutoBandWindowTemplate.RefreshActionButtons()
        return
    end
    AutoBand.cmd_organize({})
end

-- organize using currently selected combobox template (/ab org <template>)
function AutoBandWindowTemplate.OnOrganizeSelectedTemplate()
    local ok, reason = ACTIONS.OrgSelectedButton()
    if not ok then
        AutoBandWindowTemplate.RefreshActionButtons()
        AB_util.debug("Groups action unavailable: " .. tostring(reason))
        return
    end

    local selected = AutoBandWindowTemplate.selected_combobox()
    if not selected or selected == "" then
        AB_util.print("[error] No template selected.")
        return
    end

    if AutoBandWindowTemplate.is_special_template(selected) then
        AB_util.print("[error] Select a saved template to organize by name.")
        return
    end

    if AutoBand.saved.templates[selected] == nil then
        AB_util.print("[error] Template '" .. tostring(selected) .. "' does not exist.")
        return
    end

    AutoBand.cmd_organize({selected})
end

function AutoBandWindowTemplate.OnRightClickTemplateMenuCheckBox()
    if ButtonGetDisabledFlag(AutoBandWindowTemplate.rightclicktemplatecheckbox_name) then
        return
    end
    AutoBand.saved.right_click_organize_include_templates = ButtonGetPressedFlag(AutoBandWindowTemplate.rightclicktemplatecheckbox_name)
    if AutoBand and AutoBand.mark_template_settings_modified then
        AutoBand.mark_template_settings_modified()
    end
    AB_util.print("Right-click icon menu includes template organize options: " .. tostring(AutoBand.saved.right_click_organize_include_templates))
end

function AutoBandWindowTemplate.OnClickRightClickTemplateMenuLabel()
    if ButtonGetDisabledFlag(AutoBandWindowTemplate.rightclicktemplatecheckbox_name) then
        return
    end
    PlaySound(GameData.Sound.BUTTON_CLICK)
    ButtonSetPressedFlag(
        AutoBandWindowTemplate.rightclicktemplatecheckbox_name,
        not ButtonGetPressedFlag(AutoBandWindowTemplate.rightclicktemplatecheckbox_name)
    )
    AutoBandWindowTemplate.OnRightClickTemplateMenuCheckBox()
end

function AutoBandWindowTemplate.OnRoleLimitsMouseOver()
    if AutoBandWindowTemplate.role_limit_warning_text and AutoBandWindowTemplate.role_limit_warning_text ~= "" then
        template_show_text_tooltip(AutoBandWindowTemplate.role_limit_warning_text)
        return
    end
    local text = template_role_limit_tooltips[template_get_control_name_from_active_window()]
    if type(text) == "string" and text ~= "" then
        template_show_text_tooltip(text)
    end
end

function AutoBandWindowTemplate.OnControlMouseOver()
    local control = template_get_control_name_from_active_window()
    if control == "RolesLabel" then
        AutoBandWindowTemplate.OnRoleLimitsMouseOver()
        return
    end
    template_show_control_tooltip(control)
end

function AutoBandWindowTemplate.OnControlMouseOverEnd()
    template_hide_text_tooltip()
end

function AutoBandWindowTemplate.OnRoleSlotMouseOver()
    template_show_text_tooltip("Click to change the role.")
end

function AutoBandWindowTemplate.OnRoleSlotMouseOverEnd()
    template_hide_text_tooltip()
end

function AutoBandWindowTemplate.OnGroupCheckBoxMouseOver()
    template_show_text_tooltip("Include this group.")
end

function AutoBandWindowTemplate.OnGroupCheckBoxMouseOverEnd()
    template_hide_text_tooltip()
end

-- Grid captions ("#1".."#4", runtime windows ...ElemCaption<N>).
function AutoBandWindowTemplate.OnGroupCaptionMouseOver()
    local control = template_get_control_name_from_active_window() or ""
    local gid = string.match(control, "^ElemCaption(%d+)$")
    if gid then
        template_show_text_tooltip("Roles for group " .. gid .. ".")
    end
end

-- create a template from labels
function AutoBandWindowTemplate.get_template_from_labels()
    local temp = {}
    for gid = 1, AB_const.MAX_WB_GROUPS do
        temp[gid] = {}
        -- if the group checkbox is checked
        if (ButtonGetPressedFlag(AutoBandWindowTemplate.group_checkbox[gid])) then
            for pid = 1, AB_const.GROUP_SIZE do
                local role = tostring(LabelGetText(AutoBandWindowTemplate.group_roles[gid][pid]))
                if (role ~= AB_const.LABEL_EMPTY) then
                    temp[gid][pid] = {["role"] = role}
                end
            end
        end
    end
    return temp
end


-- sets role label name and color
function AutoBandWindowTemplate.set_role_label(labelname, role)
    LabelSetText(labelname , towstring(role))
    local color = AB_const.LABEL_ROLE_COLORS[role]
    LabelSetTextColor(labelname, color[1], color[2], color[3])
end

-- return selected text
function AutoBandWindowTemplate.selected_combobox()
    return tostring(ComboBoxGetSelectedText(AutoBandWindowTemplate.combobox_name))
end

-- sets combobox to item called "name"
function AutoBandWindowTemplate.set_combobox_item(name)
    local index = nil
    for i, v in ipairs(AutoBandWindowTemplate.combo_items) do
        if (v == name) then
            index = i
            break
        end
    end
    if (index) then
        ComboBoxSetSelectedMenuItem(AutoBandWindowTemplate.combobox_name, index)
        AutoBandWindowTemplate.load_template(name)
    end
end

-- reload combobox items
function AutoBandWindowTemplate.refresh_gui()
    -- enable/disable Save
    ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, not AutoBandWindowTemplate.modified)
    -- reloadui combobox
    AutoBandWindowTemplate.combo_items = {}
    refreshing = true
    ComboBoxClearMenuItems(AutoBandWindowTemplate.combobox_name)
    refreshing = false
    -- add current warband
    ComboBoxAddMenuItem(AutoBandWindowTemplate.combobox_name, towstring(AB_const.EMPTY_TEMPLATE))
    table.insert(AutoBandWindowTemplate.combo_items, AB_const.EMPTY_TEMPLATE)
    ComboBoxAddMenuItem(AutoBandWindowTemplate.combobox_name, towstring(AB_const.CURRENT_WB))
    table.insert(AutoBandWindowTemplate.combo_items, AB_const.CURRENT_WB)
    -- saved presets, sorted case-insensitively (pairs order is not deterministic)
    local names = {}
    for tname in pairs(AutoBand.saved.templates) do
        names[#names + 1] = tname
    end
    table.sort(names, function(a, b)
        local la, lb = string.lower(tostring(a)), string.lower(tostring(b))
        if la ~= lb then
            return la < lb
        end
        return tostring(a) < tostring(b)
    end)
    for _, tname in ipairs(names) do
        ComboBoxAddMenuItem(AutoBandWindowTemplate.combobox_name, towstring(tname))
        table.insert(AutoBandWindowTemplate.combo_items, tname)
    end
end

-- create GUI element and return its name
function AutoBandWindowTemplate.create_element_tl_tl(element, name, parent, xoff, yoff, width, height)
    local label_name = AutoBandWindowTemplate.name .. "Elem" .. name
    CreateWindowFromTemplate(label_name, element, parent)
    width = width or 100
    height = height or 30
    WindowSetDimensions(label_name, width, height)
    WindowAddAnchor(label_name, "topleft", parent, "topleft", xoff, yoff)
    return label_name
end

-- fired whenever a role label is left clicked
function AutoBandWindowTemplate.role_label_left_clicked()
    AutoBandWindowTemplate.rotate_role_label(-1)
end

-- fired whenever a role label is right clicked
function AutoBandWindowTemplate.role_label_right_clicked()
    AutoBandWindowTemplate.rotate_role_label(1)
end

-- rotate label by "inc"
function AutoBandWindowTemplate.rotate_role_label(inc)
    local labelname = SystemData.ActiveWindow.name
    AB_util.debug(labelname)
    local role = tostring(LabelGetText(labelname))
    local c = AB_const.LABEL_ROLE_CATEGORIES[role] + inc
    if (c <= 0) then
        c = #AB_const.LABEL_ROLE_CATEGORIES_REV
    elseif (c > #AB_const.LABEL_ROLE_CATEGORIES_REV) then
        c = 1
    end
    AutoBandWindowTemplate.set_role_label(labelname, AB_const.LABEL_ROLE_CATEGORIES_REV[c])
    AutoBandWindowTemplate.mark_modified({ enable_apply = true })
    AutoBandWindowTemplate.refresh_role_limits()
end

function AutoBandWindowTemplate.group_checkbox_clicked()
    AutoBandWindowTemplate.mark_modified({ enable_apply = true })
    AutoBandWindowTemplate.refresh_role_limits()
end

-- create role labels (four columns, six slots, an include checkbox under each)
function AutoBandWindowTemplate.create_role_labels()
    local g = AutoBandWindowTemplate.GRID
    for gid = 1, AB_const.MAX_WB_GROUPS do
        AutoBandWindowTemplate.group_roles[gid] = {}
        local xoff = g.x + (gid - 1) * g.col
        -- centred in the same 120-wide box as the slots and include checkboxes
        local capname = AutoBandWindowTemplate.create_element_tl_tl("AutoBandWindowTemplateGroupCaption", "Caption" .. gid, AutoBandWindowTemplate.name, xoff, g.caption_y, g.slot_w, 24)
        LabelSetText(capname, towstring("#" .. gid))
        WindowRegisterCoreEventHandler(capname, "OnMouseOver", "AutoBandWindowTemplate.OnGroupCaptionMouseOver")
        WindowRegisterCoreEventHandler(capname, "OnMouseOverEnd", "AutoBandWindowTemplate.OnRoleSlotMouseOverEnd")
        for pid = 1, AB_const.GROUP_SIZE do
            local yoff = g.first_row_y + (pid - 1) * g.row
            local labelname = AutoBandWindowTemplate.create_element_tl_tl("EA_Label_DefaultText", "Role" .. gid .. pid, AutoBandWindowTemplate.name, xoff, yoff, g.slot_w, g.slot_h)
            AutoBandWindowTemplate.set_role_label(labelname, AB_const.LABEL_EMPTY)
            WindowRegisterCoreEventHandler(labelname, "OnLButtonUp", "AutoBandWindowTemplate.role_label_left_clicked")
            WindowRegisterCoreEventHandler(labelname, "OnRButtonUp", "AutoBandWindowTemplate.role_label_right_clicked")
            WindowRegisterCoreEventHandler(labelname, "OnMouseOver", "AutoBandWindowTemplate.OnRoleSlotMouseOver")
            WindowRegisterCoreEventHandler(labelname, "OnMouseOverEnd", "AutoBandWindowTemplate.OnRoleSlotMouseOverEnd")
            AutoBandWindowTemplate.group_roles[gid][pid] = labelname
        end
        local yoff = g.box_y or (g.first_row_y + AB_const.GROUP_SIZE * g.row + 4)
        local chkboxname = AutoBandWindowTemplate.create_element_tl_tl("EA_Button_DefaultCheckBox", "CheckBox" .. gid, AutoBandWindowTemplate.name, xoff + 49, yoff, 22, 22)
        ButtonSetCheckButtonFlag(chkboxname, true)
        ButtonSetPressedFlag(chkboxname, true)
        WindowRegisterCoreEventHandler(chkboxname, "OnLButtonUp", "AutoBandWindowTemplate.group_checkbox_clicked")
        WindowRegisterCoreEventHandler(chkboxname, "OnMouseOver", "AutoBandWindowTemplate.OnGroupCheckBoxMouseOver")
        WindowRegisterCoreEventHandler(chkboxname, "OnMouseOverEnd", "AutoBandWindowTemplate.OnGroupCheckBoxMouseOverEnd")
        AutoBandWindowTemplate.group_checkbox[gid] = chkboxname
    end
end

-- Composition line: roles in the shown layout against the current caps.
function AutoBandWindowTemplate.refresh_role_limits()
    local warning_text, warning_flags = template_build_role_limit_warning()
    AutoBandWindowTemplate.role_limit_warning_text = warning_text
    AutoBandWindowTemplate.role_limit_warning_flags = warning_flags or { tank = false, healer = false, dps = false }
    local counts = template_count_current_layout_roles()
    -- same order as the Tanks / Healers / DPS captions below; detail in the tooltip
    local text = string.format("Layout: %d / %d / %d", counts.tank, counts.healer, counts.dps)
    local any_warning = warning_text ~= nil and warning_text ~= ""
    C.label(P .. "RolesLabel", text, any_warning and TEMPLATE_LABEL_WARNING or TEMPLATE_LABEL_NORMAL)
end

-- Warband Role Composition: caps always total 24 (cmd_setroles) ----------------------
local function refresh_composition()
    local sv = AutoBand.saved
    C.label(P .. "TanksValueLabel", tostring(sv.max_tanks))
    C.label(P .. "HealersValueLabel", tostring(sv.max_healers))
    C.label(P .. "DpsValueLabel", tostring(sv.max_dps))
    C.check(P .. "MapIconCheckBox", sv.displayicon == true)
end
AutoBandWindowTemplate.refresh_composition = refresh_composition

local function set_caps(tanks, healers, dps)
    AutoBand.cmd_setroles({ tostring(tanks), tostring(healers), tostring(dps) }, true)
    refresh_composition()
    AutoBandWindowTemplate.refresh_role_limits()
end

local function cap_plus(field)
    local caps = { tanks = AutoBand.saved.max_tanks, healers = AutoBand.saved.max_healers, dps = AutoBand.saved.max_dps }
    if caps[field] >= 24 then
        return
    end
    caps[field] = caps[field] + 1
    -- take the slot from DPS, then healers, then tanks (as before)
    for _, other in ipairs({ "dps", "healers", "tanks" }) do
        if other ~= field and caps[other] > 0 then
            caps[other] = caps[other] - 1
            break
        end
    end
    set_caps(caps.tanks, caps.healers, caps.dps)
end

local function cap_minus(field)
    local caps = { tanks = AutoBand.saved.max_tanks, healers = AutoBand.saved.max_healers, dps = AutoBand.saved.max_dps }
    if caps[field] <= 0 then
        return
    end
    caps[field] = caps[field] - 1
    if field == "dps" then
        caps.healers = caps.healers + 1
    else
        caps.dps = caps.dps + 1
    end
    set_caps(caps.tanks, caps.healers, caps.dps)
end

function AutoBandWindowTemplate.OnPressTanksPlusButton() cap_plus("tanks") end
function AutoBandWindowTemplate.OnPressTanksMinusButton() cap_minus("tanks") end
function AutoBandWindowTemplate.OnPressHealersPlusButton() cap_plus("healers") end
function AutoBandWindowTemplate.OnPressHealersMinusButton() cap_minus("healers") end
function AutoBandWindowTemplate.OnPressDpsPlusButton() cap_plus("dps") end
function AutoBandWindowTemplate.OnPressDpsMinusButton() cap_minus("dps") end

-- Show icon (global), beside the icon-menu option it belongs with.
function AutoBandWindowTemplate.OnMapIconCheckBox()
    AutoBandWindow.toggle_mapicon(ButtonGetPressedFlag(P .. "MapIconCheckBox") == true)
    refresh_composition()
end

local LABEL_TARGETS = { MapIconLabel = "MapIcon" }

function AutoBandWindowTemplate.OnLabelClick()
    local base = LABEL_TARGETS[template_get_control_name_from_active_window() or ""]
    if base then
        C.label_toggle(P .. base .. "CheckBox", AutoBandWindowTemplate["On" .. base .. "CheckBox"])
    end
end

-- Placement settings ---------------------------------------------------------------------
refresh_placement = function(opts)
    refreshing = true
    local algo_index = 1
    for i, entry in ipairs(AutoBandWindowTemplate.algo_modes) do
        if entry.mode == AutoBand.saved.org_algo_mode then
            algo_index = i
        end
    end
    ComboBoxSetSelectedMenuItem(P .. "AlgoComboBox", algo_index)
    local focus_index = 1
    for i, entry in ipairs(AutoBandWindowTemplate.focus_roles) do
        if entry.role == AutoBand.saved.org_algo_role then
            focus_index = i
        end
    end
    ComboBoxSetSelectedMenuItem(P .. "FocusComboBox", focus_index)
    -- the spread role is only used by the Aggregate algorithm
    local aggregate = AutoBand.saved.org_algo_mode == AB_const.MODE_AGGREGATE
    ComboBoxSetDisabledFlag(P .. "FocusComboBox", not aggregate)
    local rgb = aggregate and C.TEXT or C.DIM
    LabelSetTextColor(P .. "FocusLabel", rgb[1], rgb[2], rgb[3])
    refreshing = false
    C.check(P .. "GuildGroupingCheckBox", AutoBand.saved.guild_grouping_enabled == true)
    if opts and opts.distance_changed then
        C.set_edit(P .. "DistanceEditBox", tostring(AutoBand.saved.range_sort_distance_threshold or AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD))
    end
end

function AutoBandWindowTemplate.OnAlgoChanged()
    if refreshing then
        return
    end
    local index = ComboBoxGetSelectedMenuItem(P .. "AlgoComboBox")
    local entry = type(index) == "number" and AutoBandWindowTemplate.algo_modes[index] or nil
    if entry and entry.mode ~= AutoBand.saved.org_algo_mode then
        AutoBand.cmd_mode({ tostring(entry.mode) })
    end
    refresh_placement({})
end

function AutoBandWindowTemplate.OnFocusChanged()
    if refreshing then
        return
    end
    if AutoBand.saved.org_algo_mode ~= AB_const.MODE_AGGREGATE then
        -- greyed: only Aggregate uses it; restore the saved choice
        refresh_placement({})
        return
    end
    local index = ComboBoxGetSelectedMenuItem(P .. "FocusComboBox")
    local entry = type(index) == "number" and AutoBandWindowTemplate.focus_roles[index] or nil
    if entry then
        AutoBand.set_org_algo_role(entry.role, { skip_gui_refresh = true })
    end
    refresh_placement({})
end

function AutoBandWindowTemplate.OnGuildGroupingCheckBox()
    AutoBand.set_guild_grouping_enabled(ButtonGetPressedFlag(P .. "GuildGroupingCheckBox") == true, { skip_gui_refresh = true })
end

function AutoBandWindowTemplate.OnClickGuildGroupingLabel()
    C.label_toggle(P .. "GuildGroupingCheckBox", AutoBandWindowTemplate.OnGuildGroupingCheckBox)
end

-- Distance split: any finite whole number >= 0 (no new maximum); invalid input stays
-- in the box for correction.
function AutoBandWindowTemplate.OnDistanceApply()
    local value = C.parse_whole(C.edit_text(P .. "DistanceEditBox"))
    if value == nil then
        AB_util.print("[Error] Distance split must be a whole number of units, 0 or more.")
        return
    end
    AutoBand.cmd_set_range_sort_distance_threshold({ tostring(value) })
end

function AutoBandWindowTemplate.OnDistanceEscape()
    refresh_placement({ distance_changed = true })
end

function AutoBandWindowTemplate.Refresh(opts)
    opts = opts or {}
    C.check(AutoBandWindowTemplate.defaultcheckbox_name, AutoBandWindowTemplate.selected_combobox() == AutoBand.saved.default_template)
    AutoBandWindowTemplate.RefreshRightClickTemplateMenuState()
    ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, not (AutoBandWindowTemplate.modified or AutoBand.template_settings_dirty == true))
    AutoBandWindowTemplate.refresh_role_limits()
    AutoBandWindowTemplate.refresh_composition()
    AutoBandWindowTemplate.RefreshActionButtons()
    refresh_placement(opts)
end
