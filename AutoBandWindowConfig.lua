-- AutoBand Config tab: composition checks (Auto enforce, DPS split, alt-spec, rank,
-- backfill), auto-kick, social priority and chat output (prefix and colours).
AutoBandWindowConfig = {}

AutoBandWindowConfig.name = "AutoBandWindowConfigTab"
AutoBandWindowConfig.guild_priority_value_label_name = AutoBandWindowConfig.name .. "GuildPriorityValueLabel"
AutoBandWindowConfig.friend_priority_value_label_name = AutoBandWindowConfig.name .. "FriendPriorityValueLabel"

local C = AutoBandWindowCommon
local P = AutoBandWindowConfig.name

local CAREER_RANK_REQUIREMENT_MAX = 40
local REALMRANK_REQUIREMENT_STEP = 5

local function saved(key)
    return AutoBand.saved[key] == true
end

local function social_modes()
    return AB_const.SOCIAL_PRIORITY_MODES or {
        AB_const.SOCIAL_PRIORITY_MODE_OFF,
        AB_const.SOCIAL_PRIORITY_MODE_PREFER,
        AB_const.SOCIAL_PRIORITY_MODE_PROTECT,
        AB_const.SOCIAL_PRIORITY_MODE_PROMOTE,
    }
end

-- Social priority modes cycle (as before).
local function step_social_mode(mode, delta)
    mode = AutoBand.normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    local modes = social_modes()
    local index = 1
    for i = 1, #modes do
        if modes[i] == mode then
            index = i
        end
    end
    index = index + delta
    if index > #modes then
        index = 1
    elseif index < 1 then
        index = #modes
    end
    return modes[index]
end

local function radius_names()
    local names = {}
    for name in pairs(AB_const.TOOFAR_DISTANCE_VALUES) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return AB_const.TOOFAR_DISTANCE_VALUES[a] < AB_const.TOOFAR_DISTANCE_VALUES[b] end)
    return names
end

-- Timeout as saved (a slash-set value above the stepper range is shown, not rewritten).
local function autokick_period()
    local period = tonumber(AutoBand.saved.autokick_period)
    if period == nil or period ~= period then
        period = AB_const.KICK_PERIOD
    end
    return math.floor(period)
end

-- Rank steps: 1-40 career rank, then RR in steps of 5 only while the cached CSV is
-- usable (read-only gate; never loads the CSV). No wrap-around at either end.
local function rr_allowed()
    local ok, _, reason = C.csv_gate()
    return ok == true, reason
end

local function normalize_rank(raw)
    local n = tonumber(raw)
    if n == nil or n ~= n then
        return 1
    end
    n = math.floor(n)
    if n < 1 then
        n = 1
    elseif n > AB_const.MAXIMUM_RANK then
        n = AB_const.MAXIMUM_RANK
    end
    if n > CAREER_RANK_REQUIREMENT_MAX and (n % REALMRANK_REQUIREMENT_STEP) ~= 0 then
        n = n - (n % REALMRANK_REQUIREMENT_STEP)
        if n <= CAREER_RANK_REQUIREMENT_MAX then
            n = CAREER_RANK_REQUIREMENT_MAX + REALMRANK_REQUIREMENT_STEP
        end
    end
    return n
end

local function step_rank(current, delta, shift)
    current = normalize_rank(current)
    if shift then
        -- Stay on valid CR/RR values when a ten-rank step crosses CR40.
        return normalize_rank(current + delta * 10)
    end
    if delta > 0 then
        if current < CAREER_RANK_REQUIREMENT_MAX then
            return current + 1
        end
        return math.min(current + REALMRANK_REQUIREMENT_STEP, AB_const.MAXIMUM_RANK)
    end
    if current > CAREER_RANK_REQUIREMENT_MAX then
        return math.max(current - REALMRANK_REQUIREMENT_STEP, CAREER_RANK_REQUIREMENT_MAX)
    end
    return math.max(current - 1, 1)
end

local function rank_fields()
    local tank, healer, dps = AutoBand.get_saved_rank_requirements(AutoBand.saved)
    return { min_rank_tank = tank, min_rank_healer = healer, min_rank_dps = dps }
end

-- Raising a requirement above 40 needs usable CSV; lowering one (including a stale
-- RR70 -> RR65) and turning enforcement off always work, so nothing is trapped.
-- The UI clamps at 1 and the maximum (the old buttons wrapped around).
local function rr_increase_possible(current)
    current = normalize_rank(current)
    if current >= AB_const.MAXIMUM_RANK then
        return false, "Already at the maximum."
    end
    if current < CAREER_RANK_REQUIREMENT_MAX then
        return true
    end
    return rr_allowed()
end

local function adjust_rank(field, delta, role_label, flags)
    local ranks = rank_fields()
    local shift_flag = SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT
    local shift = shift_flag ~= nil and flags == shift_flag
    local next_value = step_rank(ranks[field], delta, shift)
    if next_value == ranks[field] then
        return
    end
    if delta > 0 and next_value > CAREER_RANK_REQUIREMENT_MAX then
        local ok, reason = rr_allowed()
        if not ok then
            if shift and ranks[field] < CAREER_RANK_REQUIREMENT_MAX then
                next_value = CAREER_RANK_REQUIREMENT_MAX
            else
                AB_util.print("[Error] Cannot set the " .. tostring(role_label) .. " RR requirement above 40: " ..
                    tostring(reason))
                return
            end
        end
    end
    ranks[field] = next_value
    AutoBand.set_saved_rank_requirements(ranks.min_rank_tank, ranks.min_rank_healer, ranks.min_rank_dps, AutoBand.saved)
    if type(AutoBand.arm_rank_requirement_grace) == "function" then
        AutoBand.arm_rank_requirement_grace()
    end
    AutoBand.mark_template_settings_modified()
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnPressRankPlusButton(flags) adjust_rank("min_rank_tank", 1, "tank", flags) end
function AutoBandWindowConfig.OnPressRankMinusButton(flags) adjust_rank("min_rank_tank", -1, "tank", flags) end
function AutoBandWindowConfig.OnPressHealerRankPlusButton(flags) adjust_rank("min_rank_healer", 1, "healer", flags) end
function AutoBandWindowConfig.OnPressHealerRankMinusButton(flags) adjust_rank("min_rank_healer", -1, "healer", flags) end
function AutoBandWindowConfig.OnPressDpsRankPlusButton(flags) adjust_rank("min_rank_dps", 1, "dps", flags) end
function AutoBandWindowConfig.OnPressDpsRankMinusButton(flags) adjust_rank("min_rank_dps", -1, "dps", flags) end

-- Refresh ------------------------------------------------------------------------------
local NOTE_COLOR = { 195, 200, 205 }
local caption_sizes = {}

local function set_caption_part(name, text, color)
    C.label(name, text, color)
    if text == "" then return end
    local cached = caption_sizes[name]
    if not cached or cached.text ~= text then
        local width = C.natural_text_size(name, nil, #text)
        cached = { text = text, width = width and math.ceil(width) or #text * 9 }
        caption_sizes[name] = cached
    end
    WindowSetDimensions(name, cached.width, 26)
end

local function setting_caption(label, note_label, text, note)
    set_caption_part(P .. label, text, C.TEXT)
    set_caption_part(P .. note_label, note, NOTE_COLOR)
    WindowSetShowing(P .. note_label, note ~= "")
end

-- Inactive settings are subtly muted (not disabled): lighter labels, faded steppers.
local function set_active(names, active, buttons)
    local rgb = active and C.TEXT or { 190, 190, 190 }
    for _, name in ipairs(names) do
        LabelSetTextColor(P .. name, rgb[1], rgb[2], rgb[3])
    end
    for _, button in ipairs(buttons or {}) do
        WindowSetAlpha(P .. button, active and 1 or 0.82)
    end
end

function AutoBandWindowConfig.refresh_autokick_label()
    local caps = tostring(AutoBand.saved.max_tanks) .. "-" .. tostring(AutoBand.saved.max_healers) .. "-" .. tostring(AutoBand.saved.max_dps)
    local backfill = saved("backfill_enabled") and "(BackFill)" or ""
    setting_caption("AutoKickLabel", "AutoKickNoteLabel", "Auto enforce " .. caps .. " WB", backfill)
    C.check(P .. "KickCheckBox", saved("autokick_enabled"))
end

function AutoBandWindowConfig.refresh_dps_weights()
    local inactive = saved("autokick_enabled") and "" or "(Auto enforce off)"
    setting_caption("DpsWeightingLabel", "DpsWeightingNoteLabel", "Split DPS caps", inactive)
    C.label(P .. "MaxMdpsValueLabel", tostring(AutoBand.saved.max_mdps))
    C.label(P .. "MaxRdpsValueLabel", tostring(AutoBand.saved.max_rdps))
    C.check(P .. "DpsWeightingCheckBox", saved("dps_weighting_enabled"))
    set_active({ "MaxMdpsLabel", "MaxMdpsValueLabel", "MaxRdpsLabel", "MaxRdpsValueLabel" }, saved("dps_weighting_enabled"),
        { "ButtonPlusMaxMdps", "ButtonMinusMaxMdps", "ButtonPlusMaxRdps", "ButtonMinusMaxRdps" })
end

local RANK_PLUS = { min_rank_tank = "ButtonPlusRank", min_rank_healer = "ButtonPlusHealerRank", min_rank_dps = "ButtonPlusDpsRank" }
local RANK_MINUS = { min_rank_tank = "ButtonMinusRank", min_rank_healer = "ButtonMinusHealerRank", min_rank_dps = "ButtonMinusDpsRank" }

local function refresh_ranks()
    local ranks = rank_fields()
    for field, button in pairs(RANK_PLUS) do
        ButtonSetDisabledFlag(P .. button, rr_increase_possible(ranks[field]) ~= true)
        ButtonSetDisabledFlag(P .. RANK_MINUS[field], normalize_rank(ranks[field]) <= 1)
    end
    C.label(P .. "MinRankValueLabel", tostring(ranks.min_rank_tank))
    C.label(P .. "MinHealerRankValueLabel", tostring(ranks.min_rank_healer))
    C.label(P .. "MinDpsRankValueLabel", tostring(ranks.min_rank_dps))
    C.check(P .. "KickLowRankCheckBox", saved("autokick_low_rank_enabled"))
    set_active({ "RankReqLabel", "MinRankValueLabel", "HealerRankReqLabel", "MinHealerRankValueLabel", "DpsRankReqLabel",
        "MinDpsRankValueLabel" }, saved("autokick_low_rank_enabled"),
        { "ButtonPlusRank", "ButtonMinusRank", "ButtonPlusHealerRank", "ButtonMinusHealerRank", "ButtonPlusDpsRank", "ButtonMinusDpsRank" })
end
AutoBandWindowConfig.refresh_min_rank = refresh_ranks

local function should_show_common_race_names()
    return AutoBand.raceDetermined == true and type(AB_const.RaceSupportsCommonNames) == "function" and
        AB_const.RaceSupportsCommonNames(AutoBand.race) == true
end

-- Always shown (no blank row); greyed with a short reason when the race has no
-- common name or is not known yet.
function AutoBandWindowConfig.refresh_common_race_names_control()
    WindowSetShowing(P .. "CommonRaceNamesLabel", true)
    WindowSetShowing(P .. "CommonRaceNamesCheckBox", true)
    C.enable_check(P .. "CommonRaceNamesCheckBox", P .. "CommonRaceNamesLabel", should_show_common_race_names())
    C.check(P .. "CommonRaceNamesCheckBox", saved("use_common_race_names"))
end

function AutoBandWindowConfig.refresh_social_controls()
    C.label(AutoBandWindowConfig.guild_priority_value_label_name,
        AutoBand.get_social_priority_mode_label(AutoBand.get_saved_social_priority_mode("guild")))
    C.label(AutoBandWindowConfig.friend_priority_value_label_name,
        AutoBand.get_social_priority_mode_label(AutoBand.get_saved_social_priority_mode("friend")))
end

-- Distance only (the setting name is in the tooltip); greyed while it is the default.
local function radius_setting()
    return AutoBand.saved.toofar_radius_setting or AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
end

local function radius_text()
    local distance = AB_const.TOOFAR_DISTANCE_VALUES[radius_setting()] or AutoBand.get_current_toofar_distance()
    return tostring(distance)
end

local function color_names()
    local names = {}
    for name in pairs(AB_const.AVAILABLE_COLORS) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

local function set_color_value(label, name)
    C.label(P .. label, name, AB_const.AVAILABLE_COLORS[name] or C.TEXT)
end

-- The prefix preview (display only: nothing is saved, marked dirty or run until
-- Apply/Enter, and the edit box is never written from here). It shows "[" + the exact
-- edit-box text + "]", or, with Guild link prefix on in a usable guild, "[" + the guild
-- name + "]" (the name comes straight from GetCurrentGuildInfo; no formatter or link
-- builder is called). "[" and "]" stay neutral and only the text takes the prefix
-- colour. Native labels are one colour each, so three labels sit right-aligned on the
-- Guild link row: "]" ends at x 576, the text's right edge is on "]"'s left edge and
-- "["'s right edge on the text's left edge (XML anchors). Each width is its measured
-- natural text, so the brackets are tight and the text is never cut. The draft label
-- gets the box's own wide string (no lossy conversion); validity uses the same check
-- as the command. Apply is enabled only while the draft differs from the saved prefix.
local PREVIEW_H = 26
local prefix_draft_problem = nil
local prefix_preview_busy = false
local bracket_widths = {}

-- One natural-width measurement per call (no loop; C.natural_text_size widens the
-- label so a narrow or zero-wide label cannot report its clipped width); estimate
-- when the API is missing or the result is not usable.
local function measured_width(name, chars)
    local w = C.natural_text_size(name, nil, chars)
    if w ~= nil then
        return math.ceil(w), true
    end
    return chars * 8, false
end

-- A neutral bracket ("[" or "]"), measured once per label and font.
-- Preview font: the normal text font (XML default). Only an unusually long guild
-- link that would run past x 214 (PREVIEW_SLOT) switches all three parts to the
-- small font, once per draw; nothing is ever truncated. The normal font is set back
-- only after such a switch, so the plain draft never touches fonts.
local PREVIEW_SLOT = 362 -- x 214 .. 576
local NORMAL_FONT, SMALL_FONT, TINY_FONT = "font_default_text", "font_clear_small", "font_clear_tiny"
local preview_font = NORMAL_FONT
local function apply_preview_font(font)
    if preview_font == font then
        return
    end
    if type(LabelSetFont) == "function" then
        local spacing = WindowUtils and WindowUtils.FONT_DEFAULT_TEXT_LINESPACING or 0
        for _, part in ipairs({ "PrefixPreviewOpen", "PrefixPreviewLabel", "PrefixPreviewClose" }) do
            LabelSetFont(P .. part, font, spacing)
        end
    end
    preview_font = font
end

local function set_bracket(name, text, plain)
    LabelSetText(name, text)
    LabelSetTextColor(name, C.TEXT[1], C.TEXT[2], C.TEXT[3])
    local key = name .. "|" .. preview_font .. "|" .. plain
    local w = bracket_widths[key]
    if plain == "" then
        w = 0
    elseif w == nil then
        local native
        w, native = measured_width(name, string.len(plain))
        if native then
            bracket_widths[key] = w
        end
    end
    WindowSetDimensions(name, w, PREVIEW_H)
    return w
end

-- Guild link prefix preview data: the guild name of a usable (non-starter) guild,
-- shown like the advert writes it: neutral "[" and "]" around the name in the prefix
-- colour. Pure: neither GenerateGuildLinkRaw nor the chat formatter (which resets
-- allow_guild_prefix_override) is called. nil when guildless.
local prefix_preview_guild = false
local function guild_preview_name()
    if type(AutoBand.GetCurrentGuildInfo) ~= "function" then
        return nil
    end
    local info = AutoBand.GetCurrentGuildInfo()
    if type(info) ~= "table" or info.name == nil or tostring(info.name) == "" then
        return nil
    end
    return tostring(info.name)
end

local function preview_ready()
    if type(AutoBand.saved) ~= "table" then
        return false
    end
    if type(DoesWindowExist) == "function" then
        for _, part in ipairs({ "PrefixEditBox", "PrefixApplyButton", "PrefixPreviewOpen", "PrefixPreviewLabel",
            "PrefixPreviewClose" }) do
            if not DoesWindowExist(P .. part) then
                return false -- OnTextChanged during creation, before the preview labels exist
            end
        end
    end
    return true
end

local function draw_prefix_preview()
    local draft = TextEditBoxGetText(P .. "PrefixEditBox")
    if draft == nil then
        draft = towstring(AutoBand.saved.prefix_text or AB_const.DEFAULT_PREFIX_TEXT)
    end
    local plain = C.edit_text(P .. "PrefixEditBox")
    local _, problem = AutoBand.validate_prefix_text(plain)
    prefix_draft_problem = problem
    ButtonSetDisabledFlag(P .. "PrefixApplyButton", plain == AutoBand.saved.prefix_text)

    -- normal text prefix: "[" + exactly the box text + "]"; guild link prefix (with a
    -- guild): what the guild link writes; guildless falls back to the draft
    local open_plain, body, body_plain, rgb, close_plain = "[", towstring(draft), plain, nil, "]"
    prefix_preview_guild = false
    if saved("prefix_use_guild") then
        local name = guild_preview_name()
        if name ~= nil then
            body, body_plain, rgb = towstring(name), name, AutoBand.get_prefix_color_rgb()
            prefix_preview_guild = true
        end
    end
    if rgb == nil then
        rgb = problem and C.ALERT or AutoBand.get_prefix_color_rgb()
    end
    -- body width = width(body .. close) - width(close), both measured unconstrained
    -- on the body label, so trailing glyph spacing cannot open a gap before the close
    -- part; the close width is measured once per font. An empty body gives 0.
    local text_name = P .. "PrefixPreviewLabel"
    local function measure_parts(font)
        apply_preview_font(font)
        local cw = set_bracket(P .. "PrefixPreviewClose", towstring(close_plain), close_plain)
        local ow = set_bracket(P .. "PrefixPreviewOpen", towstring(open_plain), open_plain)
        local tw = 0
        if string.len(body_plain) > 0 then
            local close_w = 0
            if close_plain ~= "" then
                local key = text_name .. "|" .. preview_font .. "|" .. close_plain
                close_w = bracket_widths[key]
                if close_w == nil then
                    local w = C.natural_text_size(text_name, towstring(close_plain), string.len(close_plain))
                    if w ~= nil then
                        close_w = math.ceil(w)
                        bracket_widths[key] = close_w
                    end
                end
            end
            local with_close = C.natural_text_size(text_name, body .. towstring(close_plain),
                string.len(body_plain) + string.len(close_plain))
            if with_close ~= nil and close_w ~= nil then
                tw = math.max(0, math.ceil(with_close) - close_w)
            else
                tw = string.len(body_plain) * 8
            end
        end
        return ow + tw + cw, tw
    end
    -- normal font when it fits; long guild names step down to small, then tiny (the
    -- client's 24-character guild names fit in small; tiny covers longer old names)
    local total, text_w = measure_parts(NORMAL_FONT)
    if prefix_preview_guild and total > PREVIEW_SLOT then
        total, text_w = measure_parts(SMALL_FONT)
        if total > PREVIEW_SLOT then
            _, text_w = measure_parts(TINY_FONT)
        end
    end
    LabelSetText(text_name, body) -- exactly the box text (wide, untrimmed) or the link text
    LabelSetTextColor(text_name, rgb[1], rgb[2], rgb[3])
    WindowSetDimensions(text_name, text_w, PREVIEW_H)
end

local function refresh_prefix_preview()
    if prefix_preview_busy or not preview_ready() then
        return
    end
    prefix_preview_busy = true
    local ok, err = pcall(draw_prefix_preview)
    prefix_preview_busy = false
    if not ok then
        error(err)
    end
end

local function refresh_prefix_box(force)
    if force then
        C.set_edit(P .. "PrefixEditBox", AutoBand.saved.prefix_text or AB_const.DEFAULT_PREFIX_TEXT)
    end
    refresh_prefix_preview()
end

local function in_usable_guild()
    return type(AutoBand.GetCurrentGuildInfo) == "function" and AutoBand.GetCurrentGuildInfo() ~= nil
end

-- Guild link prefix: turning it on needs a usable guild; turning it off always works
-- (a box left on while guildless is never trapped).
local function refresh_guild_check()
    C.check(P .. "PrefixGuildCheckBox", saved("prefix_use_guild"))
    C.enable_check(P .. "PrefixGuildCheckBox", P .. "PrefixGuildLabel", saved("prefix_use_guild") or in_usable_guild())
end

local function refresh_chat(opts)
    refresh_guild_check()
    set_color_value("PrefixColorValueLabel", AutoBand.saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME)
    set_color_value("LeadColorValueLabel", AutoBand.saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME)
    -- typed text survives unrelated refreshes; only a change of the saved prefix replaces it
    refresh_prefix_box(opts.prefix_text_changed == true)
end

function AutoBandWindowConfig.Refresh(opts)
    opts = opts or {}
    AutoBandWindowConfig.refresh_autokick_label()
    AutoBandWindowConfig.refresh_dps_weights()
    C.check(P .. "AltCheckCheckBox", saved("alt_speccheck_enabled"))
    C.label(P .. "ExcludeRealmHealerAltSpecLabel", AB_const.GetExcludeRealmHealerAltSpecLabel())
    C.check(P .. "ExcludeRealmHealerAltSpecCheckBox", saved("exclude_realm_healer_alt_spec"))
    C.enable_check(P .. "ExcludeRealmHealerAltSpecCheckBox", P .. "ExcludeRealmHealerAltSpecLabel", saved("alt_speccheck_enabled"))
    C.label(P .. "BWSorcAsMDPSLabel", AB_const.GetBWSorcAsMDPSLabel(), C.TEXT)
    C.check(P .. "BWSorcAsMDPSCheckBox", saved("bw_sorc_as_mdps"))
    refresh_ranks()
    C.check(P .. "BackFillCheckBox", saved("backfill_enabled"))
    C.check(P .. "BackFillNoHeadsUpsCheckBox", saved("backfill_no_headsups_enabled"))
    C.check(P .. "KickToofarCheckBox", saved("autokick_toofar_enabled"))
    C.label(P .. "RadiusValueLabel", radius_text())
    C.label(P .. "AutoKickTimeoutLabel", tostring(autokick_period()) .. " min")
    set_active({ "RadiusLabel", "RadiusValueLabel", "KickTimeLabel", "AutoKickTimeoutLabel" }, saved("autokick_toofar_enabled"),
        { "ButtonPlusRadius", "ButtonMinusRadius", "ButtonPlusTime", "ButtonMinusTime" })
    if radius_setting() == AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING then
        LabelSetTextColor(P .. "RadiusValueLabel", C.DIM[1], C.DIM[2], C.DIM[3])
    end
    C.check(P .. "KickRvRZonesCheckBox", saved("autokick_rvrzone_enabled"))
    C.check(P .. "KickIgnoreCheckBox", saved("autokick_ignorelist_enabled"))
    C.label(P .. "AutoKickStealthersLabel", AB_const.GetAutoKickStealthersLabel("Remove"), C.TEXT)
    C.check(P .. "KickStealthersCheckBox", saved("autokick_we_wh_enabled"))
    C.label(P .. "RestrictRaceLabel", AB_const.GetRestrictRaceLabel(), C.TEXT)
    C.check(P .. "RestrictRaceCheckBox", saved("restrict_same_race"))
    AutoBandWindowConfig.refresh_common_race_names_control()
    AutoBandWindowConfig.refresh_social_controls()
    refresh_chat(opts)
end

function AutoBandWindowConfig.Initialize()
    C.label(P .. "CompositionHeader", "Composition checks", C.HEADER)
    C.label(P .. "RemoveHeader", "Auto-kick", C.HEADER)
    C.label(P .. "SocialLabel", "Social", C.HEADER)
    C.label(P .. "ChatHeader", "Chat output", C.HEADER)
    C.label(P .. "DpsWeightingLabel", "Split DPS caps", C.TEXT)
    C.label(P .. "MaxMdpsLabel", "mDPS")
    C.label(P .. "MaxRdpsLabel", "rDPS")
    C.label(P .. "AltCheckLabel", "Alt-Spec check", C.TEXT)
    C.init_info_link(P .. "CustomRolesLink", "Custom roles")
    C.label(P .. "AutoKickLowRankLabel", "Rank requirement", C.TEXT)
    C.label(P .. "RankReqLabel", "Tank")
    C.label(P .. "HealerRankReqLabel", "Heal")
    C.label(P .. "DpsRankReqLabel", "DPS")
    C.label(P .. "BackFillLabel", "Backfill for roles/ranks", C.TEXT)
    C.label(P .. "BackFillNoHeadsUpsLabel", "No heads-ups", C.TEXT)
    C.label(P .. "AutoKickToofarLabel", "Too far from the leader", C.TEXT)
    C.label(P .. "RadiusLabel", "Radius")
    C.label(P .. "KickTimeLabel", "After")
    C.label(P .. "AutoKickRvRZonesLabel", "Outside RvR/city zones", C.TEXT)
    C.label(P .. "KickIgnoreLabel", "On ignore list", C.TEXT)
    C.label(P .. "CommonRaceNamesLabel", "Common race names", C.TEXT)
    C.label(P .. "GuildPriorityLabel", "Guild prio", C.TEXT)
    C.label(P .. "FriendPriorityLabel", "Friend prio", C.TEXT)
    C.label(P .. "PrefixLabel", "Prefix", C.TEXT)
    ButtonSetText(P .. "PrefixApplyButton", L"Apply")
    ButtonSetText(P .. "PrefixResetButton", L"Default")
    C.label(P .. "PrefixColorLabel", "Prefix", C.TEXT)
    C.label(P .. "PrefixGuildLabel", "Guild link prefix", C.TEXT)
    C.label(P .. "LeadColorLabel", "Leader", C.TEXT)
    C.init_checks(P, { "Kick", "DpsWeighting", "AltCheck", "ExcludeRealmHealerAltSpec", "BWSorcAsMDPS", "KickLowRank",
        "BackFill", "BackFillNoHeadsUps", "KickToofar", "KickRvRZones", "KickIgnore", "KickStealthers", "RestrictRace",
        "CommonRaceNames", "PrefixGuild" })
end

function AutoBandWindowConfig.Show()
    AutoBandWindowConfig.Refresh({ prefix_text_changed = true })
    WindowSetShowing(P, true)
end

function AutoBandWindowConfig.Hide()
    WindowSetShowing(P, false)
end

-- Checkboxes ----------------------------------------------------------------------------
local function pressed(box)
    return ButtonGetPressedFlag(P .. box) == true
end

local quiet = { skip_gui_refresh = true }

function AutoBandWindowConfig.OnAltCheckCheckBox()
    if saved("alt_speccheck_enabled") ~= pressed("AltCheckCheckBox") then
        AutoBand.cmd_alt_speccheck({})
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnExcludeRealmHealerAltSpecCheckBox()
    local box = "ExcludeRealmHealerAltSpecCheckBox"
    if C.disabled(P .. box) or not saved("alt_speccheck_enabled") then
        AutoBandWindowConfig.Refresh({})
        return
    end
    AutoBand.saved.exclude_realm_healer_alt_spec = pressed(box)
    if type(AutoBand.mark_alt_spec_snapshot_dirty) == "function" then
        AutoBand.mark_alt_spec_snapshot_dirty()
    end
    AB_util.print(AB_const.GetExcludeRealmHealerAltSpecLabel() .. " from alt spec check: " ..
        tostring(AutoBand.saved.exclude_realm_healer_alt_spec))
    AutoBand.mark_template_settings_modified()
    AutoBand.need_role_update = true
end

function AutoBandWindowConfig.OnBWSorcAsMDPSCheckBox()
    if saved("bw_sorc_as_mdps") ~= pressed("BWSorcAsMDPSCheckBox") then
        AutoBand.cmd_toggle_bw_sorc_mdps({})
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnKickLowRankCheckBox()
    AutoBand.set_autokick_low_rank_enabled(pressed("KickLowRankCheckBox"), quiet)
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnBackFillCheckBox()
    AutoBand.set_backfill_enabled(pressed("BackFillCheckBox"), quiet)
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnBackFillNoHeadsUpsCheckBox()
    AutoBand.set_backfill_no_headsups_enabled(pressed("BackFillNoHeadsUpsCheckBox"), quiet)
end

function AutoBandWindowConfig.OnKickToofarCheckBox()
    AutoBand.set_autokick_toofar_enabled(pressed("KickToofarCheckBox"), quiet)
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnKickRvRZonesCheckBox()
    AutoBand.set_autokick_rvrzone_enabled(pressed("KickRvRZonesCheckBox"), quiet)
end

function AutoBandWindowConfig.OnKickIgnoreCheckBox()
    AutoBand.set_autokick_ignorelist_enabled(pressed("KickIgnoreCheckBox"), quiet)
end

function AutoBandWindowConfig.OnKickStealthersCheckBox()
    AutoBand.set_autokick_we_wh_enabled(pressed("KickStealthersCheckBox"), quiet)
end

function AutoBandWindowConfig.OnRestrictRaceCheckBox()
    if saved("restrict_same_race") ~= pressed("RestrictRaceCheckBox") then
        AutoBand.cmd_toggle_restrict_race({})
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnCommonRaceNamesCheckBox()
    if not should_show_common_race_names() then
        -- greyed: no effect for this race; keep the saved state
        C.check(P .. "CommonRaceNamesCheckBox", saved("use_common_race_names"))
        return
    end
    AutoBand.set_use_common_race_names(pressed("CommonRaceNamesCheckBox"))
    AutoBandWindowConfig.Refresh({})
end

local LABEL_TARGETS = {
    AutoKickLabel = "Kick", DpsWeightingLabel = "DpsWeighting",
    AutoKickNoteLabel = "Kick", DpsWeightingNoteLabel = "DpsWeighting",
    AltCheckLabel = "AltCheck", PrefixGuildLabel = "PrefixGuild",
    ExcludeRealmHealerAltSpecLabel = "ExcludeRealmHealerAltSpec", BWSorcAsMDPSLabel = "BWSorcAsMDPS",
    AutoKickLowRankLabel = "KickLowRank", BackFillLabel = "BackFill", BackFillNoHeadsUpsLabel = "BackFillNoHeadsUps",
    AutoKickToofarLabel = "KickToofar", AutoKickRvRZonesLabel = "KickRvRZones", KickIgnoreLabel = "KickIgnore",
    AutoKickStealthersLabel = "KickStealthers", RestrictRaceLabel = "RestrictRace", CommonRaceNamesLabel = "CommonRaceNames",
}

function AutoBandWindowConfig.OnLabelClick()
    local base = LABEL_TARGETS[C.control(P) or ""]
    if base then
        C.label_toggle(P .. base .. "CheckBox", AutoBandWindowConfig["On" .. base .. "CheckBox"])
    end
end

-- Chat output: prefix text, colours, guild link ------------------------------------------
function AutoBandWindowConfig.OnPrefixApply()
    local text = C.edit_text(P .. "PrefixEditBox")
    local valid = AutoBand.validate_prefix_text(text)
    AutoBand.cmd_set_prefix(text)
    -- accepted (also the same value): show the saved, trimmed text; a rejected value
    -- stays in the box for correction (the command printed why)
    refresh_prefix_box(valid ~= nil and AutoBand.saved.prefix_text == valid)
end

-- Display only: never saves, marks dirty, prints or runs a command.
function AutoBandWindowConfig.OnPrefixTextChanged()
    refresh_prefix_preview()
end

function AutoBandWindowConfig.OnPrefixEscape()
    refresh_prefix_box(true)
end

function AutoBandWindowConfig.OnPrefixReset()
    AutoBand.cmd_reset_prefix({})
    refresh_prefix_box(true)
end

-- + and - wrap round the sorted palette: + on the last name gives the first, - on the
-- first gives the last.
local function step_color(key, default, delta, command)
    local names = color_names()
    if #names == 0 then
        return
    end
    local current = AutoBand.saved[key] or default
    local index = 1
    for i, name in ipairs(names) do
        if name == current then
            index = i
        end
    end
    command({ names[(index - 1 + delta) % #names + 1] })
end

function AutoBandWindowConfig.OnPrefixColorPlus() step_color("prefix_color_name", AB_const.DEFAULT_PREFIX_COLOR_NAME, 1, AutoBand.cmd_set_prefix_color) end
function AutoBandWindowConfig.OnPrefixColorMinus() step_color("prefix_color_name", AB_const.DEFAULT_PREFIX_COLOR_NAME, -1, AutoBand.cmd_set_prefix_color) end
function AutoBandWindowConfig.OnLeadColorPlus() step_color("lead_color_name", AB_const.DEFAULT_LEAD_COLOR_NAME, 1, AutoBand.cmd_set_lead_color) end
function AutoBandWindowConfig.OnLeadColorMinus() step_color("lead_color_name", AB_const.DEFAULT_LEAD_COLOR_NAME, -1, AutoBand.cmd_set_lead_color) end

function AutoBandWindowConfig.OnPrefixGuildCheckBox()
    local want = pressed("PrefixGuildCheckBox")
    if want and not saved("prefix_use_guild") and not in_usable_guild() then
        refresh_guild_check() -- refused: not in a usable guild
        return
    end
    if saved("prefix_use_guild") ~= want then
        AutoBand.cmd_toggle_prefix_guild({})
    end
    refresh_guild_check()
    refresh_prefix_preview()
end

-- Auto enforce and DPS split (the cap values are on Templates) -----------------------------
function AutoBandWindowConfig.OnKickCheckBox()
    AutoBand.set_autokick_enabled(pressed("KickCheckBox"), quiet)
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnDpsWeightingCheckBox()
    if saved("dps_weighting_enabled") ~= pressed("DpsWeightingCheckBox") then
        AutoBand.cmd_toggle_dps_weighting({ pressed("DpsWeightingCheckBox") and "on" or "off" })
    end
    AutoBandWindowConfig.Refresh({})
end

local function set_dps_split(mdps, rdps)
    if mdps >= 0 and rdps >= 0 then
        AutoBand.cmd_set_dps_weights({ tostring(mdps), tostring(rdps) }, true)
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnPressMaxMdpsPlusButton() set_dps_split(AutoBand.saved.max_mdps + 1, AutoBand.saved.max_dps - AutoBand.saved.max_mdps - 1) end
function AutoBandWindowConfig.OnPressMaxMdpsMinusButton() set_dps_split(AutoBand.saved.max_mdps - 1, AutoBand.saved.max_dps - AutoBand.saved.max_mdps + 1) end
function AutoBandWindowConfig.OnPressMaxRdpsPlusButton() set_dps_split(AutoBand.saved.max_dps - AutoBand.saved.max_rdps - 1, AutoBand.saved.max_rdps + 1) end
function AutoBandWindowConfig.OnPressMaxRdpsMinusButton() set_dps_split(AutoBand.saved.max_dps - AutoBand.saved.max_rdps + 1, AutoBand.saved.max_rdps - 1) end

-- Too-far radius and timeout (no wrap-around) ----------------------------------------------
local function step_radius(delta)
    local names = radius_names()
    local current = AutoBand.saved.toofar_radius_setting or AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    local index = 1
    for i, name in ipairs(names) do
        if name == current then
            index = i
        end
    end
    local target = names[index + delta]
    if target then
        AutoBand.cmd_set_toofar_distance({ target })
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnPressRadiusPlusButton() step_radius(1) end
function AutoBandWindowConfig.OnPressRadiusMinusButton() step_radius(-1) end

function AutoBandWindowConfig.OnPressTimePlusButton()
    local next_value = autokick_period() + 1
    if next_value <= AB_const.MAX_KICKOFF_TIME then
        AutoBand.cmd_autokick_timeout({ tostring(next_value) })
    end
    AutoBandWindowConfig.Refresh({})
end

function AutoBandWindowConfig.OnPressTimeMinusButton()
    local next_value = autokick_period() - 1
    if next_value >= 0 then
        AutoBand.cmd_autokick_timeout({ tostring(next_value) })
    end
    AutoBandWindowConfig.Refresh({})
end

-- Guild/friend priority -------------------------------------------------------------------------
function AutoBandWindowConfig.OnPressGuildPriorityPlusButton()
    AutoBand.set_guild_priority_mode(step_social_mode(AutoBand.get_saved_social_priority_mode("guild"), 1))
end

function AutoBandWindowConfig.OnPressGuildPriorityMinusButton()
    AutoBand.set_guild_priority_mode(step_social_mode(AutoBand.get_saved_social_priority_mode("guild"), -1))
end

function AutoBandWindowConfig.OnPressFriendPriorityPlusButton()
    AutoBand.set_friend_priority_mode(step_social_mode(AutoBand.get_saved_social_priority_mode("friend"), 1))
end

function AutoBandWindowConfig.OnPressFriendPriorityMinusButton()
    AutoBand.set_friend_priority_mode(step_social_mode(AutoBand.get_saved_social_priority_mode("friend"), -1))
end

function AutoBandWindowConfig.OnCustomRolesLink()
    AutoBand.cmd_custom_role({ "list" })
end

-- Tooltips ----------------------------------------------------------------------------------------
-- Guild/friend priority: what the row does, the current mode only, and the rule
-- that the strongest matching mode wins (three short lines).
local SOCIAL_MODE_LINES = {
    [AB_const.SOCIAL_PRIORITY_MODE_OFF] = "Off: no priority.",
    [AB_const.SOCIAL_PRIORITY_MODE_PREFER] = "Prefer: trimmed last; too-far kicks still apply.",
    [AB_const.SOCIAL_PRIORITY_MODE_PROTECT] = "Protect: never kicked for rank or distance.",
    [AB_const.SOCIAL_PRIORITY_MODE_PROMOTE] = "Promote: as Protect; may replace a full role's newest non-priority member.",
}

local function social_tip(source_key, who)
    local mode = AutoBand.get_saved_social_priority_mode(source_key)
    local line = SOCIAL_MODE_LINES[mode] or SOCIAL_MODE_LINES[AB_const.SOCIAL_PRIORITY_MODE_OFF]
    return "How " .. who .. " are favoured.\n" .. line .. "\nStrongest guild/friend mode wins."
end

local function too_far_tip()
    local setting = AutoBand.saved.toofar_radius_setting or AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    local distance = AB_const.TOOFAR_DISTANCE_VALUES[setting] or AutoBand.get_current_toofar_distance()
    return "Kicks players beyond " .. tostring(setting) .. " (" .. tostring(distance) .. " units), not Protect/Promote."
end

local function timeout_tip()
    return "Minutes before a too-far kick."
end

-- Indented parameter rows stay editable while their checkbox is off (safe setup with
-- automation off); the labels are only dimmed and the tooltip says so.
local function inactive_line(key, name)
    if saved(key) then
        return ""
    end
    return "\nInactive while " .. name .. " is off."
end

local function rank_tip(role)
    local text = role .. " minimum: CR1-40 or RR45+. Shift-click: +/-10."
    local ok, reason = rr_allowed()
    if not ok then
        text = text .. "\nUnavailable above 40: " .. tostring(reason)
    end
    return text .. inactive_line("autokick_low_rank_enabled", "Rank requirement")
end

local function radius_tip()
    return too_far_tip() .. inactive_line("autokick_toofar_enabled", "Too far")
end

local function headsups_tip()
    return "No backfill warning tells (kick-reason tells unaffected)."
end

local CUSTOM_ROLE_NAMES = { tank = "Tank", healer = "Healer", mdps = "mDPS", rdps = "rDPS" }
local function custom_role_row(name, role)
    if type(name) == "string" and type(role) == "string" then
        return name .. ": " .. (CUSTOM_ROLE_NAMES[role] or role)
    end
end

local function custom_roles_tip()
    local roles = type(AutoBand.saved) == "table" and AutoBand.saved.custom_roles or nil
    return C.small_list_tooltip("Lists custom roles (set via a player's Set Role menu).", roles, custom_role_row)
end

local TOOLTIPS = {
    AltCheck = "Uses spec to choose some roles.",
    ExcludeRealmHealerAltSpec = function() return AB_const.GetExcludeRealmHealerAltSpecTooltip() end,
    BWSorcAsMDPS = function() return "Counts " .. tostring(AB_const.GetBWSorcAsMDPSLabel()) .. "." end,
    KickLowRank = "Kicks players below the rank requirement.",
    RankReq = function() return rank_tip("Tank") end,
    MinRank = function() return rank_tip("Tank") end,
    HealerRankReq = function() return rank_tip("Healer") end,
    MinHealerRank = function() return rank_tip("Healer") end,
    DpsRankReq = function() return rank_tip("DPS") end,
    MinDpsRank = function() return rank_tip("DPS") end,
    BackFill = function()
        local text = "Fills fast, then trims the newest extras."
        if not saved("autokick_enabled") and not saved("autokick_low_rank_enabled") then
            text = text .. "\nNo effect without Auto enforce or Rank requirement."
        end
        return text
    end,
    Kick = function()
        if saved("backfill_enabled") then
            return "BackFill allows extra roles while filling.\nTrims newest extras to keep room for missing roles."
        end
        return "Kicks members over the role caps."
    end,
    DpsWeighting = function()
        return "Separate mDPS and rDPS caps." .. inactive_line("autokick_enabled", "Auto enforce")
    end,
    MaxMdps = function() return "mDPS cap." .. inactive_line("dps_weighting_enabled", "Split DPS caps") end,
    MaxRdps = function() return "rDPS cap." .. inactive_line("dps_weighting_enabled", "Split DPS caps") end,
    BackFillNoHeadsUps = headsups_tip,
    KickToofar = too_far_tip, Radius = radius_tip,
    KickTime = function() return timeout_tip() .. inactive_line("autokick_toofar_enabled", "Too far") end,
    AutoKickTimeout = function() return timeout_tip() .. inactive_line("autokick_toofar_enabled", "Too far") end,
    KickRvRZones = "Kicks players outside RvR or city zones.",
    KickIgnore = "Kicks players you ignore.",
    KickStealthers = function() return AB_const.GetAutoKickStealthersLabel("Kick") .. "." end,
    RestrictRace = "Only your race may join.",
    CommonRaceNames = function()
        local race = AutoBand.raceDetermined == true and AutoBand.race or nil
        if race and should_show_common_race_names() then
            local lore_title = AB_const.GetRaceLoreTitle(race)
            local common_title = AB_const.GetRaceCommonTitle(race)
            if lore_title and common_title and lore_title ~= "" and common_title ~= "" then
                return "Says '" .. tostring(common_title) .. "' instead of '" .. tostring(lore_title) .. "'."
            end
        end
        if AutoBand.raceDetermined ~= true then
            return "Uses common race names.\nUnavailable: Race not known yet."
        end
        if not should_show_common_race_names() then
            return "Uses common race names.\nUnavailable: No common name for this race."
        end
        return "Uses common race names."
    end,
    GuildPriority = function() return social_tip("guild", "guild members") end,
    FriendPriority = function() return social_tip("friend", "friends") end,
    Prefix = "Prefix for AutoBand chat (max " .. tostring(AB_const.MAX_PREFIX_LENGTH) .. ").",
    PrefixColor = "Colour of the prefix in chat.",
    LeadColor = "Colour of the leader's name in chat.",
    PrefixGuild = function()
        local text = "Uses your guild link in recruitment adverts."
        if not saved("prefix_use_guild") and not in_usable_guild() then
            text = text .. "\nUnavailable: Not in a guild."
        end
        return text
    end,
    PrefixPreview = function()
        if prefix_preview_guild then
            return "How the prefix appears in recruitment adverts."
        end
        if prefix_draft_problem then
            return "How the prefix appears in chat.\nNot valid: " .. prefix_draft_problem
        end
        return "How the prefix appears in chat."
    end,
    CustomRoles = custom_roles_tip,
    PrefixApply = "Saves the typed prefix.",
    PrefixReset = "Restores the default prefix.",
    -- section headings
    CompositionHeader = "Rules for which roles and ranks may stay.",
    RemoveHeader = "Removes members automatically for these reasons.",
    SocialHeader = "Priority for guild members and friends.",
    ChatHeader = "How AutoBand messages look in chat.",
}

local ALIASES = {
    CustomRolesLink = "CustomRoles",
    AutoKickNoteLabel = "Kick", DpsWeightingNoteLabel = "DpsWeighting",
    AutoKick = "Kick", ButtonPlusMaxMdps = "MaxMdps", ButtonMinusMaxMdps = "MaxMdps",
    ButtonPlusMaxRdps = "MaxRdps", ButtonMinusMaxRdps = "MaxRdps",
    AutoKickLowRank = "KickLowRank", AutoKickToofar = "KickToofar", AutoKickRvRZones = "KickRvRZones",
    AutoKickStealthers = "KickStealthers", PrefixEditBox = "Prefix", PrefixPreviewOpen = "PrefixPreview", PrefixPreviewClose = "PrefixPreview", PrefixApplyButton = "PrefixApply", PrefixResetButton = "PrefixReset",
    SocialLabel = "SocialHeader",
    PrefixColorMinusButton = "PrefixColor", PrefixColorPlusButton = "PrefixColor", PrefixColorValueLabel = "PrefixColor",
    LeadColorMinusButton = "LeadColor", LeadColorPlusButton = "LeadColor", LeadColorValueLabel = "LeadColor",
    ButtonPlusRank = "RankReq", ButtonMinusRank = "RankReq", ButtonPlusHealerRank = "HealerRankReq",
    ButtonMinusHealerRank = "HealerRankReq", ButtonPlusDpsRank = "DpsRankReq", ButtonMinusDpsRank = "DpsRankReq",
    ButtonPlusRadius = "Radius", ButtonMinusRadius = "Radius", ButtonPlusTime = "KickTime", ButtonMinusTime = "KickTime",
    ButtonPlusGuildPriority = "GuildPriority", ButtonMinusGuildPriority = "GuildPriority",
    ButtonPlusFriendPriority = "FriendPriority", ButtonMinusFriendPriority = "FriendPriority",
}

local function tooltip_for(control)
    if control == nil then
        return nil
    end
    local base = ALIASES[control]
    if base == nil then
        base = string.gsub(control, "CheckBox$", "")
        base = string.gsub(base, "ValueLabel$", "")
        base = string.gsub(base, "Label$", "")
        base = string.gsub(base, "Button$", "")
        base = ALIASES[base] or base
    end
    local text = TOOLTIPS[base]
    if type(text) == "function" then
        text = text()
    end
    if text == nil then
        return nil
    end
    return text
end

function AutoBandWindowConfig.OnControlMouseOver()
    local control = C.control(P)
    if control == "CustomRolesLink" then C.set_info_link_hover(P .. control, true) end
    C.show_tooltip(tooltip_for(control))
end

function AutoBandWindowConfig.OnControlMouseOverEnd()
    if C.control(P) == "CustomRolesLink" then C.set_info_link_hover(P .. "CustomRolesLink", false) end
    C.hide_tooltip()
end
