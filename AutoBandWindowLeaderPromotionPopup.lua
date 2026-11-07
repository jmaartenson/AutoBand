AutoBandWindowLeaderPromotionPopup = {}

AutoBandWindowLeaderPromotionPopup.name = "AutoBandWindowLeaderPromotionPopup"
AutoBandWindowLeaderPromotionPopup.box_name = AutoBandWindowLeaderPromotionPopup.name
AutoBandWindowLeaderPromotionPopup.details = nil

local function to_wstring(text)
    if type(towstring) == "function" then
        return towstring(text or "")
    end
    return text or ""
end

local function get_unique_commands(commands)
    local unique = {}
    local ordered = {}

    if type(commands) ~= "table" then
        return ordered
    end

    for i = 1, #commands do
        local command = commands[i]
        if type(command) == "string" and command ~= "" and not unique[command] then
            unique[command] = true
            ordered[#ordered + 1] = command
        end
    end

    return ordered
end

local function build_summary_text(details)
    local player_count = tonumber(details and details.player_count) or 0

    if player_count > 0 then
        return "You got promoted to WB leader in an existing " .. tostring(player_count) .. "-player warband.\n"
            .. "AutoBand switched off risky settings to avoid unexpected kicks."
    end

    return "You got promoted to WB leader in an existing warband.\n"
        .. "AutoBand switched off risky settings to avoid unexpected kicks."
end

local function build_details_text(details)
    local lines = {}
    local disabled_items = details and details.disabled_items or nil

    if type(disabled_items) == "table" and #disabled_items > 0 then
        lines[#lines + 1] = "Turned off:"
        for i = 1, #disabled_items do
            local item = disabled_items[i]
            local label = item and item.label or nil
            if type(label) == "string" and label ~= "" then
                lines[#lines + 1] = "- " .. label
            end
        end
    else
        lines[#lines + 1] = "No settings were changed."
    end

    if details and details.template_reset_from then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Also changed:"
        lines[#lines + 1] = "- default template reset from "
            .. tostring(details.template_reset_from)
            .. " to "
            .. tostring(details.template_reset_to or AB_const.EMPTY_TEMPLATE)
    end

    local commands = get_unique_commands(details and details.reenable)
    if #commands > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Slash re-enable: " .. table.concat(commands, ", ")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Or use \"Open Config\" to review or re-enable these settings."

    return table.concat(lines, "\n")
end

function AutoBandWindowLeaderPromotionPopup.Refresh()
    local details = AutoBandWindowLeaderPromotionPopup.details or {}

    LabelSetText(
        AutoBandWindowLeaderPromotionPopup.box_name .. "SummaryLabel",
        to_wstring(build_summary_text(details))
    )
    LabelSetText(
        AutoBandWindowLeaderPromotionPopup.box_name .. "DetailsLabel",
        to_wstring(build_details_text(details))
    )
end

function AutoBandWindowLeaderPromotionPopup.Initialize()
    LabelSetText(AutoBandWindowLeaderPromotionPopup.box_name .. "TitleBarText", L"AutoBand Promotion Safety")
    ButtonSetText(AutoBandWindowLeaderPromotionPopup.box_name .. "CloseButton", L"Close")
    ButtonSetText(AutoBandWindowLeaderPromotionPopup.box_name .. "OpenConfigButton", L"Open Config")
    AutoBandWindowLeaderPromotionPopup.Refresh()
end

function AutoBandWindowLeaderPromotionPopup.Hide()
    AutoBandWindowLeaderPromotionPopup.details = nil
    WindowSetShowing(AutoBandWindowLeaderPromotionPopup.name, false)
end

function AutoBandWindowLeaderPromotionPopup.OnOpenConfig()
    AutoBandWindowLeaderPromotionPopup.Hide()

    if type(AutoBandWindow) ~= "table" then
        return
    end

    if type(AutoBandWindow.ShowConfigTab) == "function" then
        AutoBandWindow.ShowConfigTab()
        return
    end

    AutoBandWindow.SelectedTab = AB_const.TABS_CONFIG
    if type(AutoBandWindow.Show) == "function" then
        AutoBandWindow.Show()
    elseif type(AutoBandWindow.show_selected_tab) == "function" then
        AutoBandWindow.show_selected_tab()
    end
end

function AutoBandWindowLeaderPromotionPopup.ShowForPromotionSafety(details)
    if type(details) ~= "table" then
        return
    end

    if type(details.disabled_items) ~= "table" then
        details.disabled_items = {}
    end
    if #details.disabled_items == 0 and details.force_show ~= true then
        return
    end

    AutoBandWindowLeaderPromotionPopup.details = details
    AutoBandWindowLeaderPromotionPopup.Refresh()
    WindowSetShowing(AutoBandWindowLeaderPromotionPopup.name, true)
end
