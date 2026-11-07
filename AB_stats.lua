-- AB_stats.lua
-- /ab stats internals and command handler.

if type(AutoBand) ~= "table" then
    AutoBand = {}
end

local core = AutoBand._core_api or {}
local stats_module = AutoBand._realmstats_module or {}
AutoBand._realmstats_module = stats_module

local REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT = 2
local REALMSTATS_SHIFT_THRESHOLD_MIN_PERCENT = 0
local REALMSTATS_SHIFT_THRESHOLD_MAX_PERCENT = 100
local REALMSTATS_BREAKDOWN_DEFAULT_TIER = "t2plus"
local REALMRANK_CSV_FILE_NAME = "AutoBand_RealmRank.csv"
local ONLINE_MONITOR_STARTUP_DELAY_SECONDS = 10
local DEFAULT_REALMSTATS_GRAPH_LINK_DATA_TAG = "AUTOBAND_STATS_GRAPH"

local parse_first_integer = core.parse_first_integer
if type(parse_first_integer) ~= "function" then
    parse_first_integer = function(raw)
        if raw == nil then
            return nil
        end
        local t = type(raw)
        if t == "number" then
            if raw == raw then
                return math.floor(raw)
            end
            return nil
        end
        if t ~= "string" then
            local ok_str, raw_str = pcall(tostring, raw)
            if not ok_str or raw_str == nil then
                return nil
            end
            raw = raw_str
        end
        local matched = string.match(raw, "%-?%d+")
        if not matched then
            return nil
        end
        local as_number = tonumber(matched)
        if as_number == nil then
            return nil
        end
        return math.floor(as_number)
    end
end

local parse_first_number = core.parse_first_number
if type(parse_first_number) ~= "function" then
    parse_first_number = function(raw)
        if raw == nil then
            return nil
        end
        local t = type(raw)
        if t == "number" then
            if raw == raw then
                return raw
            end
            return nil
        end
        if t ~= "string" then
            local ok_str, raw_str = pcall(tostring, raw)
            if not ok_str or raw_str == nil then
                return nil
            end
            raw = raw_str
        end
        local matched = string.match(raw, "%-?%d+%.?%d*")
        if not matched then
            return nil
        end
        return tonumber(matched)
    end
end

local trim_string = core.trim_string
if type(trim_string) ~= "function" then
    trim_string = function(raw)
        if raw == nil then
            return nil
        end
        local text = tostring(raw)
        text = string.gsub(text, "^%s+", "")
        text = string.gsub(text, "%s+$", "")
        if text == "" then
            return nil
        end
        return text
    end
end

local function clamp_realmstats_shift_threshold_percent(value)
    local number = tonumber(value)
    if not number then
        return nil
    end
    if number < REALMSTATS_SHIFT_THRESHOLD_MIN_PERCENT then
        number = REALMSTATS_SHIFT_THRESHOLD_MIN_PERCENT
    elseif number > REALMSTATS_SHIFT_THRESHOLD_MAX_PERCENT then
        number = REALMSTATS_SHIFT_THRESHOLD_MAX_PERCENT
    end
    return number
end

local function color_text(value, color, fallback_color, link_data)
    local rgb = color or fallback_color or AB_const.COLOR_WHITE
    local r = tonumber(rgb[1] or rgb.r) or 255
    local g = tonumber(rgb[2] or rgb.g) or 255
    local b = tonumber(rgb[3] or rgb.b) or 255
    if r < 0 then r = 0 elseif r > 255 then r = 255 end
    if g < 0 then g = 0 elseif g > 255 then g = 255 end
    if b < 0 then b = 0 elseif b > 255 then b = 255 end
    local data = "0"
    if link_data ~= nil then
        data = tostring(link_data)
        data = string.gsub(data, "\"", "'")
        if data == "" then
            data = "0"
        end
    end
    local text = tostring(value or "")
    text = string.gsub(text, "\"", "'")
    return string.format("<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">", data, r, g, b, text)
end

local function realmstats_graph_link_data()
    if type(AutoBand.build_stats_graph_link_data) == "function" then
        local link_data = AutoBand.build_stats_graph_link_data()
        if type(link_data) == "string" and link_data ~= "" then
            return link_data
        end
    end
    return DEFAULT_REALMSTATS_GRAPH_LINK_DATA_TAG
end

local function realmstats_graph_link_text(value, color, fallback_color)
    return color_text(value, color, fallback_color or AB_const.COLOR_WHITE, realmstats_graph_link_data())
end

local function ensure_realmstats_startup_runtime()
    if type(AutoBand.realmstats_startup_pending) ~= "boolean" then
        AutoBand.realmstats_startup_pending = false
    end
    if type(AutoBand.realmstats_startup_announced) ~= "boolean" then
        AutoBand.realmstats_startup_announced = false
    end
    if type(AutoBand.realmstats_startup_delay_elapsed) ~= "number" then
        AutoBand.realmstats_startup_delay_elapsed = 0
    end
    if type(AutoBand.realmstats_startup_has_csv) ~= "boolean" then
        AutoBand.realmstats_startup_has_csv = false
    end
    if type(AutoBand.realmstats_startup_force_attempted) ~= "boolean" then
        AutoBand.realmstats_startup_force_attempted = false
    end
end

local function realmstats_reset_startup_runtime(announced)
    AutoBand.realmstats_startup_pending = false
    AutoBand.realmstats_startup_announced = announced == true
    AutoBand.realmstats_startup_delay_elapsed = 0
    AutoBand.realmstats_startup_has_csv = false
    AutoBand.realmstats_startup_force_attempted = false
end

function AutoBand.realmstats_init_runtime_state()
    AutoBand.realmstats_snapshot = nil
    AutoBand.realmstats_last_auto_snapshot = nil
    AutoBand.realmstats_last_auto_report_uptime_s = nil
    AutoBand.realmstats_last_manual_snapshot = nil
    AutoBand.realmstats_last_manual_report_uptime_s = nil
    realmstats_reset_startup_runtime(false)
end

function AutoBand.realmstats_init_saved_state()
    if type(AutoBand.saved) ~= "table" then
        AutoBand.saved = {}
    end

    if AutoBand.saved.realmstats_enabled == nil then
        AutoBand.saved.realmstats_enabled = false
    end
    if type(AutoBand.saved.realmstats_enabled) ~= "boolean" then
        AutoBand.saved.realmstats_enabled = false
    end

    if AutoBand.saved.realmstats_shift_threshold_percent == nil then
        AutoBand.saved.realmstats_shift_threshold_percent = REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    end
    local threshold = clamp_realmstats_shift_threshold_percent(AutoBand.saved.realmstats_shift_threshold_percent)
    if threshold == nil then
        AutoBand.saved.realmstats_shift_threshold_percent = REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    else
        AutoBand.saved.realmstats_shift_threshold_percent = threshold
    end
end

local function realmstats_copy_snapshot(snapshot)
    if type(snapshot) ~= "table" then
        return nil
    end
    local function copy_bucket(bucket)
        if type(bucket) ~= "table" then
            return nil
        end
        return {
            order = bucket.order or 0,
            destro = bucket.destro or 0,
            total = bucket.total or 0,
            order_pct = bucket.order_pct or 0,
            destro_pct = bucket.destro_pct or 0
        }
    end
    return {
        generated_epoch_ms = snapshot.generated_epoch_ms,
        generated_utc = snapshot.generated_utc,
        overall = copy_bucket(snapshot.overall),
        t1 = copy_bucket(snapshot.t1),
        t2plus = copy_bucket(snapshot.t2plus)
    }
end

local function realmstats_format_percent(value)
    local pct = parse_first_number(value) or 0
    if pct < 0 then pct = 0 end
    return string.format("%.1f%%", pct)
end

local function realmstats_format_compact_percent(value)
    local pct = parse_first_number(value) or 0
    if pct < 0 then pct = 0 end
    local text = string.format("%.1f", pct)
    text = string.gsub(text, "%.0$", "")
    return text .. "%"
end

local function realmstats_get_shift_threshold_percent()
    local threshold = REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    if AutoBand.saved then
        local saved_threshold = clamp_realmstats_shift_threshold_percent(AutoBand.saved.realmstats_shift_threshold_percent)
        if saved_threshold ~= nil then
            threshold = saved_threshold
        end
    end
    return threshold
end

local function realmstats_format_threshold_percent(value)
    local number = clamp_realmstats_shift_threshold_percent(value)
    if number == nil then
        number = REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    end
    local text = string.format("%.2f", number)
    text = string.gsub(text, "%.?0+$", "")
    return realmstats_graph_link_text(text .. "%", AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
end

local function realmstats_is_threshold_action(action)
    return action == "threshold" or action == "thres" or action == "thresh" or action == "diff"
end

local function realmstats_format_signed_delta(value)
    local number = parse_first_integer(value) or 0
    if number > 0 then
        return "+" .. tostring(number)
    end
    return tostring(number)
end

local function realmstats_get_lead_diff(bucket)
    if type(bucket) ~= "table" then
        return 0, AB_const.COLOR_WHITE
    end
    local order_count = parse_first_integer(bucket.order) or 0
    local destro_count = parse_first_integer(bucket.destro) or 0
    if order_count > destro_count then
        return order_count - destro_count, AB_const.COLOR_SKY
    end
    if destro_count > order_count then
        return destro_count - order_count, AB_const.COLOR_RED
    end
    return 0, AB_const.COLOR_WHITE
end

local function realmstats_share_shift_delta_percent(current_bucket, previous_bucket)
    if type(current_bucket) ~= "table" or type(previous_bucket) ~= "table" then
        return 0
    end
    local current_pct = parse_first_number(current_bucket.order_pct) or 0
    local previous_pct = parse_first_number(previous_bucket.order_pct) or 0
    return current_pct - previous_pct
end

local function realmstats_bucket_population_shift_signed_percent(current_bucket, previous_bucket)
    if type(current_bucket) ~= "table" or type(previous_bucket) ~= "table" then
        return 0
    end
    local current_total = parse_first_number(current_bucket.total) or 0
    local previous_total = parse_first_number(previous_bucket.total) or 0
    if previous_total <= 0 then
        if current_total > 0 then
            return 100
        end
        return 0
    end
    return ((current_total - previous_total) * 100) / previous_total
end

local function realmstats_bucket_population_delta(current_bucket, previous_bucket)
    if type(current_bucket) ~= "table" or type(previous_bucket) ~= "table" then
        return 0
    end
    local current_total = parse_first_integer(current_bucket.total) or 0
    local previous_total = parse_first_integer(previous_bucket.total) or 0
    return current_total - previous_total
end

local function realmstats_format_signed_shift_percent(value)
    local number = parse_first_number(value) or 0
    local prefix = ""
    if number < 0 then
        prefix = "-"
        number = -number
    elseif number > 0 then
        prefix = "+"
    end
    local text = string.format("%.2f", number)
    text = string.gsub(text, "%.?0+$", "")
    return prefix .. text .. "%"
end

local function realmstats_get_report_uptime_seconds()
    local now_s = nil
    if type(AutoBand.get_uptime_seconds) == "function" then
        now_s = tonumber(AutoBand.get_uptime_seconds())
    elseif type(GetGameTime) == "function" then
        local ok_time, raw_value = pcall(GetGameTime)
        if ok_time then
            now_s = tonumber(raw_value)
        end
    end
    if now_s == nil or now_s < 0 then
        return nil
    end
    return math.floor(now_s)
end

local function realmstats_format_elapsed_since_uptime(previous_uptime_s, current_uptime_s)
    local previous_s = parse_first_integer(previous_uptime_s)
    if previous_s == nil or previous_s < 0 then
        return nil
    end

    local current_s = parse_first_integer(current_uptime_s)
    if current_s == nil then
        current_s = realmstats_get_report_uptime_seconds()
    end
    if current_s == nil or current_s < previous_s then
        return nil
    end

    local elapsed_s = current_s - previous_s
    local text
    if elapsed_s < 60 then
        text = "<1m ago"
    elseif elapsed_s < 3600 then
        text = tostring(math.floor(elapsed_s / 60)) .. "m ago"
    elseif elapsed_s < 86400 then
        text = tostring(math.floor(elapsed_s / 3600)) .. "h ago"
    else
        text = tostring(math.floor(elapsed_s / 86400)) .. "d ago"
    end

    return realmstats_graph_link_text(text, AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
end

local function realmstats_format_signed_delta_text(value)
    return realmstats_graph_link_text(realmstats_format_signed_delta(value), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
end

local function realmstats_get_signed_lead_margin(bucket)
    if type(bucket) ~= "table" then
        return 0
    end
    local order_count = parse_first_integer(bucket.order) or 0
    local destro_count = parse_first_integer(bucket.destro) or 0
    return order_count - destro_count
end

local function realmstats_format_unsigned_delta_text(value)
    local number = parse_first_integer(value) or 0
    if number < 0 then
        number = -number
    end
    return realmstats_graph_link_text(tostring(number), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
end

local function realmstats_format_unsigned_shift_text(value, color)
    local number = parse_first_number(value) or 0
    if number < 0 then
        number = -number
    end
    local text = string.format("%.2f", number)
    text = string.gsub(text, "%.?0+$", "")
    return realmstats_graph_link_text(text .. "%", color or AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
end

local function realmstats_color_text(value, color, fallback_color, link_data)
    return color_text(value, color, fallback_color or AB_const.COLOR_WHITE, link_data)
end

local function realmstats_share_percent_text(count_value, total_value)
    local count = parse_first_number(count_value) or 0
    if count < 0 then count = 0 end
    local total = parse_first_number(total_value) or 0
    if total <= 0 then
        return "0%"
    end
    return realmstats_format_compact_percent((count * 100) / total)
end

local function realmstats_muted_paren_text(text)
    return realmstats_graph_link_text("(" .. tostring(text or "0%") .. ")", AB_const.COLOR_SILVER, AB_const.COLOR_WHITE)
end

local function realmstats_count_with_share_text(count_value, total_value, count_color)
    local count = parse_first_integer(count_value) or 0
    local count_text = tostring(count)
    count_text = realmstats_graph_link_text(count_text, count_color, AB_const.COLOR_WHITE)
    local pct_text = realmstats_muted_paren_text(realmstats_share_percent_text(count, total_value))
    return count_text .. " " .. pct_text
end

local function realmstats_faction_label_colored(faction_key, fallback_label)
    if faction_key == AB_const.ORDER then
        return realmstats_color_text("Order", AB_const.COLOR_SKY, AB_const.COLOR_WHITE)
    end
    if faction_key == AB_const.DESTRUCTION then
        return realmstats_color_text("Destro", AB_const.COLOR_RED, AB_const.COLOR_WHITE)
    end
    return tostring(fallback_label or faction_key or "Faction")
end

local function normalize_realmstats_breakdown_tier(raw)
    local tier = raw
    if tier == nil or tier == "" then
        tier = REALMSTATS_BREAKDOWN_DEFAULT_TIER
    end
    tier = tostring(tier)
    local ok_lower, lowered = pcall(string.lower, tier)
    if ok_lower and lowered then
        tier = lowered
    end
    tier = string.gsub(tier, "%s+", "")

    if tier == "all" or tier == "tall" or tier == "overall" or tier == "full" or tier == "total" then
        return "all", "All tiers"
    end
    if tier == "t1" or tier == "tier1" or tier == "1" then
        return "t1", "T1 (CR 1-15)"
    end
    if tier == "t2" or tier == "t3" or tier == "t2t3" or tier == "t2-3" or tier == "23" then
        return "t2t3", "T2-T3 (CR 16-39)"
    end
    if tier == "t2+" or tier == "t2plus" or tier == "t2p" or tier == "t2to4" or tier == "midplus" then
        return "t2plus", "T2+ (CR 16-40)"
    end
    if tier == "t4" or tier == "tier4" or tier == "40" then
        return "t4", "T4 (CR 40)"
    end
    if tier == "rr60" or tier == "rr6" or tier == "r60" then
        return "rr60", "RR 60+"
    end
    if tier == "rr80" or tier == "rr8" or tier == "r80" then
        return "rr80", "RR 80+"
    end

    return nil, nil
end

local function realmstats_breakdown_matches_tier(tier_key, level_value, rr_value)
    local level = tonumber(level_value)
    if level ~= nil then
        level = math.floor(level)
    end
    local rr = tonumber(rr_value)
    if rr ~= nil then
        rr = math.floor(rr)
    end

    if tier_key == "all" then
        return true
    end
    if tier_key == "t1" then
        return level ~= nil and level >= 1 and level <= 15
    end
    if tier_key == "t2t3" then
        return level ~= nil and level >= 16 and level <= 39
    end
    if tier_key == "t2plus" then
        return level ~= nil and level >= 16 and level <= 40
    end
    if tier_key == "t4" then
        return level ~= nil and level >= 40
    end
    if tier_key == "rr60" then
        return rr ~= nil and rr >= 60
    end
    if tier_key == "rr80" then
        return rr ~= nil and rr >= 80
    end
    return false
end

local function realmstats_breakdown_usage()
    AB_util.print("Usage: /ab stats breakdown [tAll|t1|t2t3|t2+|t4|rr60|rr80] [detailed]")
end

local function realmstats_get_ordered_career_groups()
    return {
        {
            faction = AB_const.ORDER,
            faction_label = "Order",
            role = AB_const.TANK,
            role_label = "Tanks",
            career_lines = { 13, 16, 17 }
        },
        {
            faction = AB_const.ORDER,
            faction_label = "Order",
            role = AB_const.MDPS,
            role_label = "mDPS",
            career_lines = { 9, 8, 10 }
        },
        {
            faction = AB_const.ORDER,
            faction_label = "Order",
            role = AB_const.RDPS,
            role_label = "rDPS",
            career_lines = { 2, 1, 6 }
        },
        {
            faction = AB_const.ORDER,
            faction_label = "Order",
            role = AB_const.HEALER,
            role_label = "Heals",
            career_lines = { 22, 21, 20 }
        },
        {
            faction = AB_const.DESTRUCTION,
            faction_label = "Destro",
            role = AB_const.TANK,
            role_label = "Tanks",
            career_lines = { 18, 14, 15 }
        },
        {
            faction = AB_const.DESTRUCTION,
            faction_label = "Destro",
            role = AB_const.MDPS,
            role_label = "mDPS",
            career_lines = { 11, 12, 7 }
        },
        {
            faction = AB_const.DESTRUCTION,
            faction_label = "Destro",
            role = AB_const.RDPS,
            role_label = "rDPS",
            career_lines = { 3, 5, 4 }
        },
        {
            faction = AB_const.DESTRUCTION,
            faction_label = "Destro",
            role = AB_const.HEALER,
            role_label = "Heals",
            career_lines = { 23, 19, 24 }
        },
    }
end

local function realmstats_get_career_display_name(career_line, name_by_line)
    if type(name_by_line) == "table" then
        local mapped = name_by_line[career_line]
        if type(mapped) == "string" and mapped ~= "" then
            return mapped
        end
    end
    return "Career " .. tostring(career_line)
end

local function realmstats_get_career_icon(career_line, icon_by_line)
    if type(icon_by_line) ~= "table" then
        return nil
    end
    local icon = icon_by_line[career_line]
    if type(icon) == "string" and icon ~= "" then
        return icon
    end
    return nil
end

local function realmstats_normalize_faction(raw)
    local text = trim_string(raw)
    if not text then
        return nil
    end
    local ok_lower, lowered = pcall(string.lower, text)
    if not ok_lower or lowered == nil then
        return nil
    end
    if lowered == "order" then
        return AB_const.ORDER
    end
    if lowered == "destruction" or lowered == "destro" then
        return AB_const.DESTRUCTION
    end
    return nil
end

local function realmstats_normalize_role(raw)
    local text = trim_string(raw)
    if not text then
        return nil
    end
    local ok_lower, lowered = pcall(string.lower, text)
    if not ok_lower or lowered == nil then
        return nil
    end
    if lowered == AB_const.TANK or lowered == AB_const.HEALER or lowered == AB_const.MDPS or lowered == AB_const.RDPS then
        return lowered
    end
    return nil
end

local function realmstats_format_career_count_entry(career_line, count, role_total, name_by_line, icon_by_line)
    local count_number = parse_first_integer(count) or 0
    local label = realmstats_get_career_display_name(career_line, name_by_line) .. " " ..
        realmstats_graph_link_text(tostring(count_number), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE) ..
        " " .. realmstats_muted_paren_text(realmstats_share_percent_text(count_number, role_total))
    local icon = realmstats_get_career_icon(career_line, icon_by_line)
    if icon and icon ~= "" then
        return icon .. " " .. label
    end
    return label
end

local function realmstats_build_career_breakdown(tier_key)
    local snapshot_state = nil
    if type(AutoBand.get_realmrank_snapshot_state) == "function" then
        snapshot_state = AutoBand.get_realmrank_snapshot_state(true, { cache_first = true })
    end
    if type(snapshot_state) ~= "table" or snapshot_state.status ~= "ok" then
        local miss_status = snapshot_state and snapshot_state.status or "csv_unavailable"
        local miss_reason = nil
        if type(AutoBand.realmrank_snapshot_miss_reason) == "function" then
            miss_reason = AutoBand.realmrank_snapshot_miss_reason(miss_status)
        end
        return nil, miss_reason or "online snapshot unavailable", snapshot_state
    end

    local online_lookup = snapshot_state.online_lookup
    local level_lookup = snapshot_state.level_lookup or {}
    local careerline_lookup = snapshot_state.careerline_lookup or {}
    local careername_lookup = snapshot_state.careername_lookup or {}
    local careericon_lookup = snapshot_state.careericon_lookup or {}
    local faction_lookup = snapshot_state.faction_lookup or {}
    local role_lookup = snapshot_state.role_lookup or {}

    local breakdown = {
        total = 0,
        population = {
            [AB_const.ORDER] = 0,
            [AB_const.DESTRUCTION] = 0,
        },
        archetypes = {
            [AB_const.ORDER] = {
                [AB_const.TANK] = 0,
                [AB_const.HEALER] = 0,
                [AB_const.MDPS] = 0,
                [AB_const.RDPS] = 0,
            },
            [AB_const.DESTRUCTION] = {
                [AB_const.TANK] = 0,
                [AB_const.HEALER] = 0,
                [AB_const.MDPS] = 0,
                [AB_const.RDPS] = 0,
            },
        },
        career_counts = {
            [AB_const.ORDER] = {
                [AB_const.TANK] = {},
                [AB_const.HEALER] = {},
                [AB_const.MDPS] = {},
                [AB_const.RDPS] = {},
            },
            [AB_const.DESTRUCTION] = {
                [AB_const.TANK] = {},
                [AB_const.HEALER] = {},
                [AB_const.MDPS] = {},
                [AB_const.RDPS] = {},
            },
        },
        career_name_by_line = {},
        career_icon_by_line = {},
    }

    for key, rr in pairs(online_lookup) do
        local level = level_lookup[key]
        local career_line = parse_first_integer(careerline_lookup[key])
        local faction = realmstats_normalize_faction(faction_lookup[key])
        local role = realmstats_normalize_role(role_lookup[key])
        if career_line ~= nil and career_line > 0 then
            if breakdown.career_name_by_line[career_line] == nil then
                local name = trim_string(careername_lookup[key])
                if name ~= nil then
                    breakdown.career_name_by_line[career_line] = name
                end
            end
            if breakdown.career_icon_by_line[career_line] == nil then
                local icon = trim_string(careericon_lookup[key])
                if icon ~= nil then
                    breakdown.career_icon_by_line[career_line] = icon
                end
            end
        end
        if career_line ~= nil and career_line > 0 and realmstats_breakdown_matches_tier(tier_key, level, rr) then
            if faction and role and breakdown.population[faction] ~= nil and breakdown.archetypes[faction][role] ~= nil then
                breakdown.total = breakdown.total + 1
                breakdown.population[faction] = breakdown.population[faction] + 1
                breakdown.archetypes[faction][role] = breakdown.archetypes[faction][role] + 1

                local role_counts = breakdown.career_counts[faction][role]
                role_counts[career_line] = (role_counts[career_line] or 0) + 1
            end
        end
    end

    return breakdown, nil, snapshot_state
end

local function realmstats_show_career_breakdown(tier_key, tier_label, show_careers)
    local breakdown, err, snapshot_state = realmstats_build_career_breakdown(tier_key)
    if not breakdown then
        if type(AutoBand.is_realmrank_soft_disabled) == "function" and AutoBand.is_realmrank_soft_disabled() then
            return false
        end
        AB_util.print("[Error] Realm stats breakdown unavailable: " .. tostring(err or "online CSV unavailable") .. " (" .. REALMRANK_CSV_FILE_NAME .. ").")
        return false
    end

    local order_count = breakdown.population[AB_const.ORDER] or 0
    local destro_count = breakdown.population[AB_const.DESTRUCTION] or 0
    local total_count = breakdown.total or 0
    local order_count_text = realmstats_count_with_share_text(order_count, total_count, AB_const.COLOR_SKY)
    local destro_count_text = realmstats_count_with_share_text(destro_count, total_count, AB_const.COLOR_RED)
    local order_label = realmstats_faction_label_colored(AB_const.ORDER, "Order")
    local destro_label = realmstats_faction_label_colored(AB_const.DESTRUCTION, "Destro")
    local total_count_text = realmstats_graph_link_text(tostring(total_count), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
    AB_util.print("Breakdown -- " .. tostring(tier_label or "") .. "  [" .. total_count_text .. " total]")
    AB_util.print(
        order_label .. " " .. order_count_text ..
        "  |  " ..
        destro_label .. " " .. destro_count_text
    )

    local function print_archetype_line(faction_key, faction_label)
        local role_counts = breakdown.archetypes[faction_key] or {}
        local faction_total = breakdown.population[faction_key] or 0
        local faction_text = realmstats_faction_label_colored(faction_key, faction_label)
        AB_util.print(
            faction_text .. " " ..
            "Tanks " .. realmstats_count_with_share_text(role_counts[AB_const.TANK] or 0, faction_total) .. " / " ..
            "mDPS " .. realmstats_count_with_share_text(role_counts[AB_const.MDPS] or 0, faction_total) .. " / " ..
            "rDPS " .. realmstats_count_with_share_text(role_counts[AB_const.RDPS] or 0, faction_total) .. " / " ..
            "Heals " .. realmstats_count_with_share_text(role_counts[AB_const.HEALER] or 0, faction_total)
        )
    end

    print_archetype_line(AB_const.ORDER, "Order")
    print_archetype_line(AB_const.DESTRUCTION, "Destro")

    if show_careers then
        local groups = realmstats_get_ordered_career_groups()
        for i = 1, #groups do
            local group = groups[i]
            local entries = {}
            local faction_counts = breakdown.career_counts[group.faction]
            local role_counts = faction_counts and faction_counts[group.role] or {}
            local role_totals = breakdown.archetypes[group.faction] or {}
            local role_total = role_totals[group.role] or 0
            local faction_text = realmstats_faction_label_colored(group.faction, group.faction_label)
            for j = 1, #(group.career_lines or {}) do
                    local career_line = group.career_lines[j]
                    if career_line ~= nil then
                        local count = role_counts and role_counts[career_line] or 0
                        entries[#entries + 1] = realmstats_format_career_count_entry(
                            career_line,
                            count,
                            role_total,
                            breakdown.career_name_by_line,
                            breakdown.career_icon_by_line
                        )
                    end
                end
            if #entries > 0 then
                AB_util.print(faction_text .. " " .. group.role_label .. ": " .. table.concat(entries, ", "))
            end
        end
    end

    local generated_utc = AutoBand.realmrank_generated_utc
    if not generated_utc or generated_utc == "" then
        local stats_snapshot = AutoBand.realmstats_snapshot
        if type(stats_snapshot) == "table" and stats_snapshot.generated_utc and stats_snapshot.generated_utc ~= "" then
            generated_utc = stats_snapshot.generated_utc
        elseif type(snapshot_state) == "table" and snapshot_state.generated_utc and snapshot_state.generated_utc ~= "" then
            generated_utc = snapshot_state.generated_utc
        else
            generated_utc = "unknown"
        end
    end
    AB_util.print("Snapshot: " .. realmstats_graph_link_text(tostring(generated_utc), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE))
    return true
end

local function realmstats_collect_shift_report(current, previous, threshold)
    if type(current) ~= "table" or type(previous) ~= "table" then
        return 0, {}
    end
    local threshold_value = parse_first_number(threshold) or REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    if threshold_value < 0 then
        threshold_value = 0
    end
    local max_shift = 0
    local triggered = {}
    local function format_population_delta(delta_value)
        local delta_number = parse_first_integer(delta_value) or 0
        -- Population deltas are realm-wide totals, so keep these neutral and rely on +/- sign.
        return realmstats_graph_link_text(realmstats_format_signed_delta(delta_number), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
    end

    local function add_share_shift(label, current_bucket, previous_bucket)
        local signed_delta = realmstats_share_shift_delta_percent(current_bucket, previous_bucket)
        local shift = signed_delta
        if shift < 0 then
            shift = -shift
        end
        if shift > max_shift then
            max_shift = shift
        end
        if shift > threshold_value then
            local shift_raw = realmstats_format_signed_shift_percent(signed_delta)
            local shift_text = realmstats_graph_link_text(shift_raw, AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)
            if signed_delta > 0 then
                shift_text = realmstats_graph_link_text(shift_raw, AB_const.COLOR_SKY, AB_const.COLOR_WHITE)
                triggered[#triggered + 1] = label .. " " .. shift_text
            elseif signed_delta < 0 then
                shift_text = realmstats_graph_link_text(shift_raw, AB_const.COLOR_RED, AB_const.COLOR_WHITE)
                triggered[#triggered + 1] = label .. " " .. shift_text
            else
                triggered[#triggered + 1] = label .. " " .. shift_text
            end
        end
    end

    local function add_shift(label, shift_value, population_delta_value)
        local signed_shift = parse_first_number(shift_value) or 0
        local shift = signed_shift
        if shift < 0 then
            shift = -shift
        end
        if shift > max_shift then
            max_shift = shift
        end
        if shift > threshold_value then
            local population_delta_text = format_population_delta(population_delta_value)
            local shift_text = realmstats_graph_link_text(
                realmstats_format_signed_shift_percent(signed_shift),
                AB_const.COLOR_WHITE,
                AB_const.COLOR_WHITE
            )
            triggered[#triggered + 1] = label .. " " .. shift_text .. " (" .. population_delta_text .. ")"
        end
    end

    -- T1 share is informational in /ab stats output but intentionally does not trigger alerts.
    add_share_shift("Overall share shift:", current.overall, previous.overall)
    add_share_shift("T2+ share shift:", current.t2plus, previous.t2plus)
    add_shift(
        "Overall population shift:",
        realmstats_bucket_population_shift_signed_percent(current.overall, previous.overall),
        realmstats_bucket_population_delta(current.overall, previous.overall)
    )

    return max_shift, triggered
end

local function realmstats_print_bucket_line(label, bucket)
    if type(bucket) ~= "table" then
        return
    end
    local order_color = AB_const.COLOR_SKY
    local destro_color = AB_const.COLOR_RED
    local lead_diff, lead_color = realmstats_get_lead_diff(bucket)
    local lead_text = "tied"
    if lead_diff > 0 then
        lead_text = realmstats_graph_link_text(realmstats_format_signed_delta(lead_diff), lead_color, AB_const.COLOR_WHITE)
    end
    local order_label = realmstats_color_text("Order", order_color, AB_const.COLOR_WHITE)
    local destro_label = realmstats_color_text("Destro", destro_color, AB_const.COLOR_WHITE)
    local order_pct = realmstats_graph_link_text(realmstats_format_percent(bucket.order_pct), order_color, AB_const.COLOR_WHITE)
    local destro_pct = realmstats_graph_link_text(realmstats_format_percent(bucket.destro_pct), destro_color, AB_const.COLOR_WHITE)
    local order_count_text = realmstats_muted_paren_text(tostring(parse_first_integer(bucket.order) or 0))
    local destro_count_text = realmstats_muted_paren_text(tostring(parse_first_integer(bucket.destro) or 0))
    local total_count = realmstats_graph_link_text(tostring(bucket.total or 0), AB_const.COLOR_WHITE, AB_const.COLOR_WHITE)

    AB_util.print(
        label .. ":  " ..
        order_label .. " " .. order_pct .. " " .. order_count_text ..
        "  vs  " ..
        destro_label .. " " .. destro_pct .. " " .. destro_count_text ..
        "  (" .. total_count .. " online, " .. lead_text .. ")"
    )
end

local function realmstats_print_snapshot(snapshot, opts)
    opts = opts or {}
    if type(snapshot) ~= "table" then
        return
    end
    realmstats_print_bucket_line("Overall", snapshot.overall)
    realmstats_print_bucket_line("T1", snapshot.t1)
    realmstats_print_bucket_line("T2+", snapshot.t2plus)
    if opts.include_snapshot_row == true and snapshot.generated_utc and snapshot.generated_utc ~= "" then
        AB_util.print("Snapshot: " .. realmstats_graph_link_text(snapshot.generated_utc, AB_const.COLOR_WHITE, AB_const.COLOR_WHITE))
    end
end

local function realmstats_print_delta_report(current, previous, opts)
    if type(current) ~= "table" or type(previous) ~= "table" then
        return false
    end
    opts = opts or {}

    local function bucket_has_change(current_bucket, previous_bucket)
        if type(current_bucket) ~= "table" or type(previous_bucket) ~= "table" then
            return false
        end
        return (parse_first_integer(current_bucket.order) or 0) ~= (parse_first_integer(previous_bucket.order) or 0) or
               (parse_first_integer(current_bucket.destro) or 0) ~= (parse_first_integer(previous_bucket.destro) or 0) or
               (parse_first_integer(current_bucket.total) or 0) ~= (parse_first_integer(previous_bucket.total) or 0)
    end

    local elapsed_text = realmstats_format_elapsed_since_uptime(
        opts.previous_report_uptime_s,
        opts.current_report_uptime_s
    )

    local header = "Since last manual /ab stats"
    if type(opts.header_label) == "string" and opts.header_label ~= "" then
        header = opts.header_label
    end
    if elapsed_text ~= nil then
        header = header .. " (" .. elapsed_text .. ")"
    end

    local changed_lines = {}
    local order_label = realmstats_color_text("Order", AB_const.COLOR_SKY, AB_const.COLOR_WHITE)
    local destro_label = realmstats_color_text("Destro", AB_const.COLOR_RED, AB_const.COLOR_WHITE)

    local function build_total_phrase(total_delta, population_shift)
        if total_delta == 0 then
            return "unchanged"
        end
        if total_delta > 0 then
            return "up " ..
                realmstats_format_unsigned_delta_text(total_delta) ..
                " (" .. realmstats_format_unsigned_shift_text(population_shift, AB_const.COLOR_WHITE) .. ")"
        end
        return "down " ..
            realmstats_format_unsigned_delta_text(total_delta) ..
            " (" .. realmstats_format_unsigned_shift_text(population_shift, AB_const.COLOR_WHITE) .. ")"
    end

    local function build_share_phrase(share_shift)
        if share_shift > 0 then
            return realmstats_color_text("Order share", AB_const.COLOR_SKY, AB_const.COLOR_WHITE) ..
                " up " .. realmstats_format_unsigned_shift_text(share_shift, AB_const.COLOR_SKY)
        end
        if share_shift < 0 then
            return realmstats_color_text("Destro share", AB_const.COLOR_RED, AB_const.COLOR_WHITE) ..
                " up " .. realmstats_format_unsigned_shift_text(share_shift, AB_const.COLOR_RED)
        end
        return "shares unchanged"
    end

    local function build_lead_phrase(current_margin, previous_margin)
        local current_sign = 0
        if current_margin > 0 then
            current_sign = 1
        elseif current_margin < 0 then
            current_sign = -1
        end

        local previous_sign = 0
        if previous_margin > 0 then
            previous_sign = 1
        elseif previous_margin < 0 then
            previous_sign = -1
        end

        local current_abs = current_margin
        if current_abs < 0 then
            current_abs = -current_abs
        end
        local previous_abs = previous_margin
        if previous_abs < 0 then
            previous_abs = -previous_abs
        end

        if current_sign == 0 and previous_sign == 0 then
            return "still tied"
        end
        if previous_sign == 0 and current_sign == 1 then
            return order_label .. " took the lead by " .. realmstats_format_unsigned_delta_text(current_abs)
        end
        if previous_sign == 0 and current_sign == -1 then
            return destro_label .. " took the lead by " .. realmstats_format_unsigned_delta_text(current_abs)
        end
        if current_sign == 0 then
            return "now tied"
        end
        if current_sign ~= previous_sign then
            local leader_label = order_label
            if current_sign < 0 then
                leader_label = destro_label
            end
            return "lead switched to " .. leader_label .. " by " .. realmstats_format_unsigned_delta_text(current_abs)
        end

        local leader_phrase = order_label .. " lead"
        if current_sign < 0 then
            leader_phrase = destro_label .. " lead"
        end
        if current_abs > previous_abs then
            return leader_phrase .. " widened by " .. realmstats_format_unsigned_delta_text(current_abs - previous_abs)
        end
        if current_abs < previous_abs then
            return leader_phrase .. " narrowed by " .. realmstats_format_unsigned_delta_text(previous_abs - current_abs)
        end
        return leader_phrase .. " unchanged"
    end

    local function add_bucket_line(label, current_bucket, previous_bucket)
        if not bucket_has_change(current_bucket, previous_bucket) then
            return
        end

        local order_delta = (parse_first_integer(current_bucket.order) or 0) - (parse_first_integer(previous_bucket.order) or 0)
        local destro_delta = (parse_first_integer(current_bucket.destro) or 0) - (parse_first_integer(previous_bucket.destro) or 0)
        local total_delta = realmstats_bucket_population_delta(current_bucket, previous_bucket)
        local population_shift = realmstats_bucket_population_shift_signed_percent(current_bucket, previous_bucket)
        local share_shift = realmstats_share_shift_delta_percent(current_bucket, previous_bucket)
        local current_margin = realmstats_get_signed_lead_margin(current_bucket)
        local previous_margin = realmstats_get_signed_lead_margin(previous_bucket)

        changed_lines[#changed_lines + 1] =
            label .. ": " ..
            order_label .. " " ..
            realmstats_format_signed_delta_text(order_delta) .. ", " ..
            destro_label .. " " ..
            realmstats_format_signed_delta_text(destro_delta) .. ", total " ..
            build_total_phrase(total_delta, population_shift) .. ", " ..
            build_share_phrase(share_shift) .. ", " ..
            build_lead_phrase(current_margin, previous_margin)
    end

    add_bucket_line("Overall", current.overall, previous.overall)
    add_bucket_line("T1", current.t1, previous.t1)
    add_bucket_line("T2+", current.t2plus, previous.t2plus)

    if #changed_lines <= 0 then
        AB_util.print(header .. ": no changes.")
        return true
    end

    AB_util.print(header .. ":")
    for idx = 1, #changed_lines do
        AB_util.print(changed_lines[idx])
    end
    return true
end

stats_module.const = {
    REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT = REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT,
    REALMSTATS_SHIFT_THRESHOLD_MIN_PERCENT = REALMSTATS_SHIFT_THRESHOLD_MIN_PERCENT,
    REALMSTATS_SHIFT_THRESHOLD_MAX_PERCENT = REALMSTATS_SHIFT_THRESHOLD_MAX_PERCENT,
    REALMSTATS_BREAKDOWN_DEFAULT_TIER = REALMSTATS_BREAKDOWN_DEFAULT_TIER,
    REALMRANK_CSV_FILE_NAME = REALMRANK_CSV_FILE_NAME,
    ONLINE_MONITOR_STARTUP_DELAY_SECONDS = ONLINE_MONITOR_STARTUP_DELAY_SECONDS,
}

stats_module.fn = {
    parse_first_number = parse_first_number,
    clamp_realmstats_shift_threshold_percent = clamp_realmstats_shift_threshold_percent,
    ensure_realmstats_startup_runtime = ensure_realmstats_startup_runtime,
    realmstats_reset_startup_runtime = realmstats_reset_startup_runtime,
    realmstats_copy_snapshot = realmstats_copy_snapshot,
    realmstats_get_shift_threshold_percent = realmstats_get_shift_threshold_percent,
    realmstats_format_threshold_percent = realmstats_format_threshold_percent,
    realmstats_is_threshold_action = realmstats_is_threshold_action,
    normalize_realmstats_breakdown_tier = normalize_realmstats_breakdown_tier,
    realmstats_breakdown_usage = realmstats_breakdown_usage,
    realmstats_show_career_breakdown = realmstats_show_career_breakdown,
    realmstats_collect_shift_report = realmstats_collect_shift_report,
    realmstats_get_report_uptime_seconds = realmstats_get_report_uptime_seconds,
    realmstats_format_elapsed_since_uptime = realmstats_format_elapsed_since_uptime,
    realmstats_print_snapshot = realmstats_print_snapshot,
    realmstats_print_delta_report = realmstats_print_delta_report,
}

AutoBand.ensure_realmstats_startup_runtime = ensure_realmstats_startup_runtime

local function stats_loader_print(message)
    if type(AB_util) == "table" and type(AB_util.print) == "function" then
        AB_util.print(message)
        return
    end
    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.Print) == "function" then
        local text = "[AutoBand] " .. tostring(message or "")
        if type(towstring) == "function" then
            EA_ChatWindow.Print(towstring(text))
        else
            EA_ChatWindow.Print(text)
        end
    end
end

local function load_stats_submodule(file_name)
    if type(dofile) ~= "function" then
        return false
    end
    local ok, err = pcall(dofile, file_name)
    if not ok then
        stats_loader_print("[Error] Failed to load " .. tostring(file_name) .. ": " .. tostring(err))
        return false
    end
    return true
end

load_stats_submodule("AB_stats_runtime.lua")
load_stats_submodule("AB_stats_commands.lua")
