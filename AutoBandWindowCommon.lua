-- AutoBandWindowCommon.lua: small helpers shared by the settings pages.
-- Tooltips (small font), checkbox/label enable state, label-click toggles and the
-- read-only dependency gates. Gates only read cached state; they never load the
-- realm-rank CSV, walk markgroup members, print or change settings.
AutoBandWindowCommon = {}

local C = AutoBandWindowCommon

C.TEXT = { 225, 225, 225 }
C.DIM = { 150, 150, 150 }
C.HEADER = { 255, 204, 102 }
C.WARN = { 255, 190, 90 }
C.ALERT = { 255, 96, 96 }
C.LINK = { 140, 190, 255 }
C.LINK_HOVER = { 190, 220, 255 }


local function tooltip_window_name()
    if SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name and SystemData.ActiveWindow.name ~= "" then
        return SystemData.ActiveWindow.name
    end
    if SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name then
        return SystemData.MouseOverWindow.name
    end
    return nil
end
C.active_window = tooltip_window_name

-- Name of the hovered/clicked control without the page prefix.
function C.control(prefix)
    local name = tooltip_window_name()
    if type(name) ~= "string" or string.sub(name, 1, #prefix) ~= prefix then
        return nil
    end
    return string.sub(name, #prefix + 1)
end

local function set_tooltip_font(font)
    if type(LabelSetFont) ~= "function" then
        return
    end
    local spacing = 20
    if type(WindowUtils) == "table" and tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING) then
        spacing = tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
    end
    LabelSetFont("DefaultTooltipRow1Col1Text", font, spacing)
    LabelSetFont("DefaultTooltipRow1Col2Text", font, spacing)
    LabelSetFont("DefaultTooltipRow1Col3Text", font, spacing)
end

function C.show_tooltip(text)
    if type(Tooltips) ~= "table" or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    local window_name = tooltip_window_name()
    if not window_name or window_name == "" or text == nil or text == "" then
        return
    end
    if type(text) == "string" then
        text = towstring(text)
    end
    if type(Tooltips.SetTooltipText) == "function" then
        Tooltips.CreateTextOnlyTooltip(window_name)
        set_tooltip_font("font_clear_small")
        Tooltips.SetTooltipText(1, 1, text)
        if type(Tooltips.Finalize) == "function" then
            Tooltips.Finalize()
        end
    else
        Tooltips.CreateTextOnlyTooltip(window_name, text)
    end
    if type(Tooltips.AnchorTooltip) == "function" then
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
    end
end

function C.hide_tooltip()
    if type(Tooltips) ~= "table" or type(Tooltips.DestroyTooltip) ~= "function" then
        return
    end
    local window_name = tooltip_window_name()
    if not window_name or window_name == "" then
        return
    end
    set_tooltip_font("font_default_text")
    Tooltips.DestroyTooltip(window_name)
end

function C.label(name, text, rgb)
    LabelSetText(name, towstring(text or ""))
    if rgb then
        LabelSetTextColor(name, rgb[1], rgb[2], rgb[3])
    end
end

function C.init_info_link(name, text, height)
    C.label(name, text, C.LINK)
    local width = C.natural_text_size(name, nil, #text)
    WindowSetDimensions(name, width and math.ceil(width) or #text * 8, height or 26)
end

function C.set_info_link_hover(name, hovered)
    local rgb = hovered and C.LINK_HOVER or C.LINK
    LabelSetTextColor(name, rgb[1], rgb[2], rgb[3])
end

-- Hover previews use at most five cached rows. Larger lists keep their short hint.
function C.small_list_tooltip(hint, source, format_row, heading)
    if type(source) ~= "table" then return hint end
    local rows, count = {}, 0
    for key, value in pairs(source) do
        count = count + 1
        if count > 5 then return hint end
        local row = format_row(key, value)
        if type(row) == "string" and row ~= "" then
            row = string.gsub(row, "[\r\n]+", " ")
            if #row > 100 then row = string.sub(row, 1, 97) .. "..." end
            rows[#rows + 1] = row
        end
    end
    if #rows == 0 then return hint end
    table.sort(rows, function(a, b)
        local al, bl = string.lower(a), string.lower(b)
        if al ~= bl then return al < bl end
        return a < b
    end)
    return (heading or hint) .. "\n" .. table.concat(rows, "\n")
end

-- Natural (unclipped) size of a label's text. The client measures the label's
-- constrained layout (a narrow or zero-wide label reports its clipped width), so the
-- label is widened for the measurement and its previous size restored right after,
-- in the same call (nothing is drawn in between; same font and scale). Sets `text`
-- first when given. Returns nil when the API is missing or the result is not usable,
-- including zero for non-empty text (nchars > 0), which is never trusted.
local MEASURE_W = 4000
function C.natural_text_size(label, text, nchars)
    if type(LabelGetTextDimensions) ~= "function" then
        return nil
    end
    if text ~= nil then
        LabelSetText(label, towstring(text))
    end
    if nchars == nil then
        nchars = type(text) == "string" and #text or 1
    end
    local old_w, old_h
    if type(WindowGetDimensions) == "function" then
        old_w, old_h = WindowGetDimensions(label)
        WindowSetDimensions(label, MEASURE_W, (tonumber(old_h) or 0) > 0 and old_h or 26)
    end
    local ok, width, height = pcall(LabelGetTextDimensions, label)
    if old_w ~= nil then
        WindowSetDimensions(label, old_w, old_h)
    end
    width = ok and tonumber(width) or nil
    if width == nil or width ~= width or width < 0 or width >= MEASURE_W then
        return nil
    end
    if width == 0 and nchars > 0 then
        return nil
    end
    return width, tonumber(height)
end

local function measure(label, text)
    return (C.natural_text_size(label, text, #text))
end

-- prefix .. name .. suffix, with the name shortened ("...") until the measured text
-- fits max_w. Each distinct full text is measured once (opts.cache) and the loop is
-- bounded by the name length; without measuring, the name is cut to
-- opts.fallback_chars. The caller sets the returned text (and shows the full text in
-- the tooltip).
function C.fit_text(label, prefix, name, suffix, opts)
    local full = prefix .. name .. suffix
    local cache = opts.cache
    if cache[full] then
        return cache[full]
    end
    local text = full
    local width = measure(label, full)
    if width == nil then
        if #name > opts.fallback_chars then
            text = prefix .. string.sub(name, 1, opts.fallback_chars) .. "..." .. suffix
        end
    elseif width > opts.max_w then
        text = prefix .. "..." .. suffix
        for keep = #name - 1, 1, -1 do
            local candidate = prefix .. string.sub(name, 1, keep) .. "..." .. suffix
            local candidate_width = measure(label, candidate)
            if candidate_width == nil or candidate_width <= opts.max_w then
                text = candidate
                break
            end
        end
    end
    cache[full] = text
    return text
end

-- Size a centre-anchored label to its measured text height (keeps its width), so
-- its text sits on the anchor's centre line. One measurement per label.
local text_heights = {}
function C.match_text_height(label, width)
    local h = text_heights[label]
    if h == nil then
        local _, measured = C.natural_text_size(label, nil, 1)
        if measured and measured == measured and measured > 0 and measured < 200 then
            h = math.ceil(measured)
            text_heights[label] = h
        end
    end
    if h then
        WindowSetDimensions(label, width, h)
    end
    return h
end

-- Short tooltip reason for a missing chat channel (chat output keeps the /channeljoin hint).
function C.channel_reason(name)
    return "Join the " .. tostring(name) .. " channel."
end

function C.check(name, pressed)
    ButtonSetPressedFlag(name, pressed == true)
end

function C.disabled(name)
    return ButtonGetDisabledFlag(name) == true
end

-- Grey out a checkbox and its label together (the pressed state is kept).
function C.enable_check(checkbox, label, enabled)
    ButtonSetDisabledFlag(checkbox, enabled ~= true)
    local rgb = enabled and C.TEXT or C.DIM
    LabelSetTextColor(label, rgb[1], rgb[2], rgb[3])
end

function C.init_checks(prefix, names)
    for i = 1, #names do
        ButtonSetCheckButtonFlag(prefix .. names[i] .. "CheckBox", true)
    end
end

-- Label click: same as clicking its (enabled) checkbox.
function C.label_toggle(checkbox, handler)
    if C.disabled(checkbox) then
        return
    end
    if type(PlaySound) == "function" and GameData and GameData.Sound then
        PlaySound(GameData.Sound.BUTTON_CLICK)
    end
    ButtonSetPressedFlag(checkbox, not ButtonGetPressedFlag(checkbox))
    handler()
end

-- Edit box text as a Lua string (the payload is converted only for validation).
function C.edit_text(name)
    local value = TextEditBoxGetText(name)
    if type(WStringToString) == "function" and value ~= nil and type(value) ~= "string" then
        return WStringToString(value)
    end
    return tostring(value or "")
end

function C.set_edit(name, text)
    TextEditBoxSetText(name, towstring(text or ""))
end

-- Finite, non-negative whole number from an edit box, or nil.
function C.parse_whole(text)
    local trimmed = string.match(tostring(text or ""), "^%s*(.-)%s*$")
    if not string.match(trimmed, "^%d+$") then
        return nil
    end
    return tonumber(trimmed)
end

-- Read-only dependency gates ----------------------------------------------------
local function unavailable(reason)
    return false, "unavailable", reason
end

function C.csv_gate()
    if type(AutoBand.peek_realmrank_availability) ~= "function" then
        return unavailable("Realm-rank data is unavailable in this build.")
    end
    return AutoBand.peek_realmrank_availability()
end

function C.stats_gate()
    if type(AutoBand.cmd_stats) ~= "function" or type(AutoBand.peek_realmstats_availability) ~= "function" then
        return unavailable("Realm stats are unavailable in this build.")
    end
    return AutoBand.peek_realmstats_availability()
end

function C.online_gate()
    if type(AutoBand.peek_online_markgroup_availability) ~= "function" then
        return unavailable("Online markgroups are unavailable in this build.")
    end
    return AutoBand.peek_online_markgroup_availability()
end

-- Short status for the Realm tab, e.g. "Fresh (4 min old)" or "Stale (45 min old)";
-- the reason is in the tooltip.
function C.csv_status_text()
    local ok, status, reason, age = C.csv_gate()
    if ok then
        if age == nil then
            return "Loaded (age unknown)", C.TEXT, nil
        end
        return "Fresh (" .. tostring(math.floor(age / 60)) .. " min old)", C.TEXT, nil
    end
    local short = {
        lookup_disabled = "Lookup off",
        placeholder = "Placeholder only",
        missing = "Not loaded",
        empty = "No rows yet",
        stale = age and ("Stale (" .. tostring(math.floor(age / 60)) .. " min old)") or "Stale",
    }
    return short[status] or "Unavailable", C.WARN, reason
end
