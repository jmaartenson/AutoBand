AutoBandWindowTemplateSave = {}
AutoBandWindowTemplateSave.name = "AutoBandWindowTemplateSave"
AutoBandWindowTemplateSave.callback = nil

function AutoBandWindowTemplateSave.Initialize()
    LabelSetText(AutoBandWindowTemplateSave.name .. "TitleBarText", L"New Template")
    LabelSetText(AutoBandWindowTemplateSave.name .. "NameLabel", L"Enter a name:")
    ButtonSetText(AutoBandWindowTemplateSave.name .. "OKButton", L"OK")
    ButtonSetText(AutoBandWindowTemplateSave.name .. "CancelButton", L"Cancel")
end

function AutoBandWindowTemplateSave.OnOK()
        local newname = tostring(TextEditBoxGetText(AutoBandWindowTemplateSave.name .. "NameEditBox"))
        local newname_lower = newname:lower() -- For case-insensitive check

        AB_util.debug("Attempting to save template with name: '" .. newname .. "'")

        if newname == "" then
                AB_util.print("[Error] Template name cannot be empty.")
                AutoBandWindowTemplateSave.Hide() -- Hides the save dialog
                return
        end

        -- Check against special names like <Warband>, <Automatic> using the existing function
        if AutoBandWindowTemplate.is_special_template(newname) then
                AB_util.print("[Error] '" .. newname .. "' is a reserved name and cannot be used for templates.")
                AutoBandWindowTemplateSave.Hide()
                return
        end

        -- Add the specific check for "distance" (case-insensitive)
        if newname_lower == "distance" then
                AB_util.print("[Error] 'distance' is a reserved keyword and cannot be used for template names.")
                AutoBandWindowTemplateSave.Hide()
                return
        end

        -- If all checks pass and callback exists
        if AutoBandWindowTemplateSave.callback then
                AutoBandWindowTemplateSave.Hide()
                AutoBandWindowTemplateSave.callback(newname) -- Proceed to save
        else
                -- This case should ideally not happen if ShowModal was called correctly
                AB_util.debug("Error: Save OK pressed but no callback was set.")
                AutoBandWindowTemplateSave.Hide()
        end
end

function AutoBandWindowTemplateSave.OnCancel()
    AB_util.debug("Cancel")
    AutoBandWindowTemplateSave.Hide()
end

function AutoBandWindowTemplateSave.Hide()
    WindowSetShowing(AutoBandWindowTemplateSave.name, false)
    -- mask down
    WindowSetShowing(AutoBandWindowTemplate.name .. "Mask", false)
end

function AutoBandWindowTemplateSave.ShowModal(callback)
    AutoBandWindowTemplateSave.callback = callback
    WindowSetShowing(AutoBandWindowTemplateSave.name, true)
end

-- Tooltips: one short line per control (the title and stock close button have none).
local SAVE_TIPS = {
    NameLabel = "Name for the new template.",
    NameEditBox = "Name for the new template.",
    OKButton = "Saves the template.",
    CancelButton = "Closes without saving.",
}

function AutoBandWindowTemplateSave.OnControlMouseOver()
    local C = AutoBandWindowCommon
    C.show_tooltip(SAVE_TIPS[C.control(AutoBandWindowTemplateSave.name) or ""])
end

function AutoBandWindowTemplateSave.OnControlMouseOverEnd()
    AutoBandWindowCommon.hide_tooltip()
end
