AutoBandWindowScoreboardPreview = {}

AutoBandWindowScoreboardPreview.name = "AutoBandWindowScoreboardPreview"
AutoBandWindowScoreboardPreview.pending_commands = nil
AutoBandWindowScoreboardPreview.initialized = false

local function preview_to_wstring(text)
    if type(towstring) == "function" then
        return towstring(text or "")
    end
    return text or ""
end

local function preview_window_exists(name)
    if type(DoesWindowExist) ~= "function" then
        return false
    end
    local ok_exists, exists = pcall(DoesWindowExist, name)
    return ok_exists and exists == true
end

local function build_preview_lines(commands)
    if type(AutoBand) == "table" and type(AutoBand.ScoreboardProbe) == "table" and
       type(AutoBand.ScoreboardProbe.BuildPreviewLines) == "function" then
        return AutoBand.ScoreboardProbe.BuildPreviewLines(commands)
    end

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

local function build_summary_text()
    return "Review the formatted preview below.\n"
        .. "Confirm to send it to /wb."
end

local function can_send_to_wb()
    if type(AutoBand) == "table" and type(AutoBand.ScoreboardProbe) == "table" and
       type(AutoBand.ScoreboardProbe.CanSendToWarband) == "function" then
        return AutoBand.ScoreboardProbe.CanSendToWarband()
    end

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

local function print_commands_locally(commands)
    if type(commands) ~= "table" or type(AB_util) ~= "table" or type(AB_util.print) ~= "function" then
        return
    end

    for i = 1, #commands do
        local line = tostring(commands[i] or "")
        line = string.gsub(line, "^/wb%s+", "", 1)
        AB_util.print(line)
    end
end

function AutoBandWindowScoreboardPreview.Initialize()
    if AutoBandWindowScoreboardPreview.initialized == true then
        return
    end
    AutoBandWindowScoreboardPreview.initialized = true

    if type(LabelSetText) == "function" then
        LabelSetText(AutoBandWindowScoreboardPreview.name .. "TitleBarText", L"Send Scoreboard to WB?")
    end
    if type(ButtonSetText) == "function" then
        ButtonSetText(AutoBandWindowScoreboardPreview.name .. "ConfirmButton", L"Send")
        ButtonSetText(AutoBandWindowScoreboardPreview.name .. "CancelButton", L"Cancel")
    end
end

function AutoBandWindowScoreboardPreview.EnsureWindow()
    if preview_window_exists(AutoBandWindowScoreboardPreview.name) then
        AutoBandWindowScoreboardPreview.Initialize()
        return true
    end

    if type(CreateWindow) ~= "function" then
        return false
    end

    local ok_create = pcall(CreateWindow, AutoBandWindowScoreboardPreview.name, false)
    if not ok_create then
        return false
    end

    if type(DoesWindowExist) == "function" and not preview_window_exists(AutoBandWindowScoreboardPreview.name) then
        return false
    end

    AutoBandWindowScoreboardPreview.Initialize()
    return true
end

function AutoBandWindowScoreboardPreview.Hide()
    AutoBandWindowScoreboardPreview.pending_commands = nil
    if type(WindowSetShowing) == "function" and preview_window_exists(AutoBandWindowScoreboardPreview.name) then
        WindowSetShowing(AutoBandWindowScoreboardPreview.name, false)
    end
end

function AutoBandWindowScoreboardPreview.OnCancel()
    AutoBandWindowScoreboardPreview.Hide()
end

function AutoBandWindowScoreboardPreview.OnConfirm()
    local commands = AutoBandWindowScoreboardPreview.pending_commands
    AutoBandWindowScoreboardPreview.Hide()

    if type(commands) ~= "table" then
        return
    end

    if not can_send_to_wb() then
        if type(AB_util) == "table" and type(AB_util.print) == "function" then
            AB_util.print("Only the WB leader or an assistant can send scoreboard output to /wb. Showing it locally instead.")
        end
        print_commands_locally(commands)
        return
    end

    for i = 1, #commands do
        AutoBand.enqueue_command(commands[i], nil, nil, "scoreboard")
    end
end

function AutoBandWindowScoreboardPreview.ShowModal(commands)
    if type(commands) ~= "table" or #commands == 0 then
        return false
    end
    if not AutoBandWindowScoreboardPreview.EnsureWindow() then
        return false
    end

    AutoBandWindowScoreboardPreview.pending_commands = commands
    AutoBandWindowScoreboardPreview.Initialize()

    if type(LabelSetText) == "function" then
        LabelSetText(
            AutoBandWindowScoreboardPreview.name .. "SummaryLabel",
            preview_to_wstring(build_summary_text())
        )
        local preview_lines = build_preview_lines(commands)
        LabelSetText(
            AutoBandWindowScoreboardPreview.name .. "DetailsLabel",
            preview_to_wstring(table.concat(preview_lines, "\n\n"))
        )
    end
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(AutoBandWindowScoreboardPreview.name, true)
    end
    return true
end
