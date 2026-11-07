-- AB_realmrank.lua
-- Realm-rank support module.
--
-- Responsibilities:
-- 1) Load/parse AutoBand_RealmRank.csv and maintain in-memory snapshot tables.
-- 2) Resolve CR/RR rank requirement checks (including RR availability guards).
-- 3) Track generated time freshness and maintain fallback cache aging.
-- 4) Provide user-facing commands (/ab rrlookup, /ab online, /ab friends, /ab rank...).
--
-- Notes:
-- - This file intentionally centralizes RR behavior so command paths share one policy source.
-- - Keep behavior changes conservative: many systems depend on status strings and message text.

if type(AutoBand) ~= "table" then
    AutoBand = {}
end

local core = AutoBand._core_api or {}
local rr_module = AutoBand._realmrank_module or {}
AutoBand._realmrank_module = rr_module

-- Runtime and policy constants.
local REALMRANK_REFRESH_DEFAULT_SECONDS = 300
local REALMRANK_REFRESH_MIN_SECONDS = 60
local REALMRANK_REFRESH_MAX_SECONDS = 1800
local REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS = 1800
local REALMRANK_STALE_MAX_AGE_SECONDS = 30 * 60
local REALMRANK_FALLBACK_MAX_AGE_SECONDS = 14 * 24 * 60 * 60
local REALMRANK_FALLBACK_CLEAN_INTERVAL_SECONDS = 6 * 60 * 60
local REALMRANK_FALLBACK_MAX_ENTRIES = 3000
local REALMRANK_EPOCH_MIN_SECONDS = 946684800
local REALMRANK_EPOCH_MAX_SECONDS = 4102444800
local REALMRANK_CUMULATED_DAYS_FOR_MONTH = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }
local REALMRANK_CUMULATED_DAYS_FOR_MONTH_LEAP = { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 }
local REALMRANK_CSV_FILE_NAME = "AutoBand_RealmRank.csv"
local REALMRANK_CSV_TABLE_NAME = "AutoBand._realm_rank_csv_rows"
local ONLINE_MONITOR_INTERVAL_SECONDS = 60
local ONLINE_MONITOR_STARTUP_DELAY_SECONDS = 10
local CAREER_RANK_REQUIREMENT_MIN = 1
local CAREER_RANK_REQUIREMENT_MAX = 40
local REALMRANK_REQUIREMENT_STEP = 5

-- Runtime state initialization.
function AutoBand.realmrank_init_runtime_state()
    AutoBand.rankreq_pending_notice_state = {}
    AutoBand.rankreq_poller_warning_state = { status = nil, cooldown_ticks = 0 }

    AutoBand.realmrank_lookup = {}
    AutoBand.realmrank_name_lookup = {}
    AutoBand.realmrank_charid_lookup = {}
    AutoBand.realmrank_level_lookup = {}
    AutoBand.realmrank_careerline_lookup = {}
    AutoBand.realmrank_careername_lookup = {}
    AutoBand.realmrank_careericon_lookup = {}
    AutoBand.realmrank_faction_lookup = {}
    AutoBand.realmrank_role_lookup = {}
    AutoBand.realmrank_signature = nil
    AutoBand.realmrank_row_count = 0
    AutoBand.realmrank_resolved_csv_path = nil
    AutoBand.realmrank_generated_epoch_ms = nil
    AutoBand.realmrank_generated_utc = nil
    AutoBand.realmrank_refresh_elapsed = REALMRANK_REFRESH_DEFAULT_SECONDS
    AutoBand.realmrank_soft_disabled = false
    AutoBand.realmrank_csv_placeholder_loaded = false
    AutoBand.realmrank_csv_auto_refresh_suppressed = false

    AutoBand.online_monitor_elapsed = 0
    AutoBand.online_monitor_groups = {}
    AutoBand.online_monitor_state = {}
    AutoBand.online_monitor_startup_pending = false
    AutoBand.online_monitor_startup_announced = false
    AutoBand.online_monitor_startup_delay_elapsed = 0

    AutoBand._realm_rank_csv_rows = {}
end

-- Shared primitive helpers. Prefer core-provided versions when available.
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

local uppercase_first_character_ascii = core.uppercase_first_character_ascii
if type(uppercase_first_character_ascii) ~= "function" then
    uppercase_first_character_ascii = function(text)
        if type(text) ~= "string" or text == "" then
            return text
        end
        local first = string.sub(text, 1, 1)
        local rest = string.sub(text, 2)
        return string.upper(first) .. rest
    end
end

local function normalize_wb_player_name(name_raw)
    if type(AutoBand.normalize_wb_player_name) == "function" then
        return AutoBand.normalize_wb_player_name(name_raw)
    end
    if type(core.normalize_wb_player_name) == "function" then
        return core.normalize_wb_player_name(name_raw)
    end
    return nil, nil
end

local function normalize_realmrank_character_id(raw)
    local character_id = parse_first_integer(raw)
    if character_id == nil or character_id <= 0 then
        return nil
    end
    return character_id
end

local function normalize_realmrank_career_line(raw)
    local career_line = parse_first_integer(raw)
    if career_line == nil or career_line <= 0 then
        return nil
    end
    return career_line
end

local function normalize_realmrank_faction(raw)
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

local function normalize_realmrank_role(raw)
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

local function normalize_generated_utc_text(raw)
    local text = trim_string(raw)
    if not text then
        return nil
    end

    local y, mon, day, hour, min, sec = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)Z$")
    if y then
        return y .. "-" .. mon .. "-" .. day .. " " .. hour .. ":" .. min .. ":" .. sec .. " UTC"
    end

    y, mon, day, hour, min, sec = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)%.%d+Z$")
    if y then
        return y .. "-" .. mon .. "-" .. day .. " " .. hour .. ":" .. min .. ":" .. sec .. " UTC"
    end

    y, mon, day, hour, min, sec = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d) ?[Uu][Tt][Cc]$")
    if y then
        return y .. "-" .. mon .. "-" .. day .. " " .. hour .. ":" .. min .. ":" .. sec .. " UTC"
    end

    y, mon, day, hour, min, sec = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
    if y then
        return y .. "-" .. mon .. "-" .. day .. " " .. hour .. ":" .. min .. ":" .. sec .. " UTC"
    end

    return text
end

local function format_epoch_seconds_utc(epoch_seconds)
    local total_seconds = parse_first_integer(epoch_seconds)
    if total_seconds == nil or total_seconds < 0 then
        return nil
    end

    local floor = math.floor
    local dsec = 24 * 60 * 60
    local ysec = 365 * dsec
    local lsec = ysec + dsec
    local fsec = 4 * ysec + dsec
    local base_year = 1970
    local mdays = { -1, 30, 58, 89, 119, 150, 180, 211, 242, 272, 303, 333, 364 }
    local leap_mdays = {}

    for i = 1, 2 do
        leap_mdays[i] = mdays[i]
    end
    for i = 3, 13 do
        leap_mdays[i] = mdays[i] + 1
    end

    local year = floor(total_seconds / fsec)
    total_seconds = total_seconds - year * fsec
    year = year * 4 + base_year

    local month_days = mdays
    if total_seconds >= ysec then
        year = year + 1
        total_seconds = total_seconds - ysec
        if total_seconds >= ysec then
            year = year + 1
            total_seconds = total_seconds - ysec
            if total_seconds >= lsec then
                year = year + 1
                total_seconds = total_seconds - lsec
            else
                month_days = leap_mdays
            end
        end
    end

    local year_day = floor(total_seconds / dsec)
    total_seconds = total_seconds - year_day * dsec
    local month = 1
    while month_days[month] < year_day do
        month = month + 1
    end
    month = month - 1
    local day = year_day - month_days[month]

    local hour = floor(total_seconds / 3600)
    total_seconds = total_seconds - hour * 3600
    local minute = floor(total_seconds / 60)
    local second = total_seconds - minute * 60

    return string.format("%04d-%02d-%02d %02d:%02d:%02d UTC", year, month, day, hour, minute, second)
end

local function is_realmrank_leap_year(year)
    if type(year) ~= "number" then
        return false
    end
    return (year % 4 == 0) and ((year % 100) ~= 0 or (year % 400) == 0)
end

local function is_valid_realmrank_epoch_seconds(seconds)
    if type(seconds) ~= "number" then
        return false
    end
    return seconds >= REALMRANK_EPOCH_MIN_SECONDS and seconds <= REALMRANK_EPOCH_MAX_SECONDS
end

local function parse_generated_utc_epoch_seconds(raw)
    local text = normalize_generated_utc_text(raw)
    if not text then
        return nil
    end

    local year_s, month_s, day_s, hour_s, minute_s, second_s =
        string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d) ?[Uu][Tt][Cc]$")
    if not year_s then
        year_s, month_s, day_s, hour_s, minute_s, second_s =
            string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
    end
    if not year_s then
        return nil
    end

    local year = tonumber(year_s)
    local month = tonumber(month_s)
    local day = tonumber(day_s)
    local hour = tonumber(hour_s)
    local minute = tonumber(minute_s)
    local second = tonumber(second_s)
    if not year or not month or not day or not hour or not minute or not second then
        return nil
    end

    if year < 1970 or month < 1 or month > 12 or day < 1 or hour < 0 or hour > 23 or
       minute < 0 or minute > 59 or second < 0 or second > 59 then
        return nil
    end

    local days_per_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if is_realmrank_leap_year(year) then
        days_per_month[2] = 29
    end
    if day > days_per_month[month] then
        return nil
    end

    local timestamp = 0
    for y = 1970, (year - 1) do
        if is_realmrank_leap_year(y) then
            timestamp = timestamp + (366 * 86400)
        else
            timestamp = timestamp + (365 * 86400)
        end
    end

    local month_days = REALMRANK_CUMULATED_DAYS_FOR_MONTH
    if is_realmrank_leap_year(year) then
        month_days = REALMRANK_CUMULATED_DAYS_FOR_MONTH_LEAP
    end
    timestamp = timestamp + month_days[month] * 86400
    timestamp = timestamp + (day - 1) * 86400
    timestamp = timestamp + hour * 3600
    timestamp = timestamp + minute * 60
    timestamp = timestamp + second

    if not is_valid_realmrank_epoch_seconds(timestamp) then
        return nil
    end
    return timestamp
end

local function get_realmrank_generated_epoch_seconds_with_source()
    local generated_epoch_ms = parse_first_integer(AutoBand.realmrank_generated_epoch_ms)
    if generated_epoch_ms ~= nil and generated_epoch_ms > 0 then
        local seconds = math.floor(generated_epoch_ms / 1000)
        if is_valid_realmrank_epoch_seconds(seconds) then
            return seconds, "GeneratedEpochMs"
        end
    end

    local generated_seconds = parse_generated_utc_epoch_seconds(AutoBand.realmrank_generated_utc)
    if generated_seconds ~= nil then
        return generated_seconds, "GeneratedUtc"
    end
    return nil, "none"
end

local function add_unique_csv_path(candidates, seen, path)
    if type(path) ~= "string" then
        return
    end
    local clean = trim_string(path)
    if not clean or seen[clean] then
        return
    end
    seen[clean] = true
    candidates[#candidates + 1] = clean
end

local function get_realmrank_csv_path_candidates()
    local candidates = {}
    local seen = {}

    add_unique_csv_path(candidates, seen, AutoBand.realmrank_resolved_csv_path)
    if AutoBand.saved and AutoBand.saved.realmrank_csv_path then
        add_unique_csv_path(candidates, seen, AutoBand.saved.realmrank_csv_path)
    end

    add_unique_csv_path(candidates, seen, "Interface/AddOns/AutoBand/" .. REALMRANK_CSV_FILE_NAME)
    add_unique_csv_path(candidates, seen, "Interface/Addons/AutoBand/" .. REALMRANK_CSV_FILE_NAME)
    add_unique_csv_path(candidates, seen, "Interface/AddOns/" .. REALMRANK_CSV_FILE_NAME)
    add_unique_csv_path(candidates, seen, "Interface/Addons/" .. REALMRANK_CSV_FILE_NAME)
    add_unique_csv_path(candidates, seen, REALMRANK_CSV_FILE_NAME)

    return candidates
end

local function append_realmstats_bucket_signature(parts, label, bucket)
    if type(parts) ~= "table" then
        return
    end
    if type(bucket) ~= "table" then
        parts[#parts + 1] = tostring(label) .. ":"
        return
    end
    parts[#parts + 1] =
        tostring(label) .. ":" ..
        tostring(bucket.order or "") .. ":" ..
        tostring(bucket.destro or "") .. ":" ..
        tostring(bucket.total or "")
end

local function build_realmrank_signature(lookup, stats_snapshot)
    if type(lookup) ~= "table" then
        lookup = {}
    end
    local lookup_parts = {}
    for key, rr in pairs(lookup) do
        lookup_parts[#lookup_parts + 1] = tostring(key) .. ":" .. tostring(rr)
    end
    table.sort(lookup_parts)

    local parts = { table.concat(lookup_parts, "|") }
    append_realmstats_bucket_signature(parts, "overall", stats_snapshot and stats_snapshot.overall)
    append_realmstats_bucket_signature(parts, "t1", stats_snapshot and stats_snapshot.t1)
    append_realmstats_bucket_signature(parts, "t2plus", stats_snapshot and stats_snapshot.t2plus)
    return table.concat(parts, "||")
end

local function realmstats_make_bucket(order_count, destro_count)
    local order = parse_first_integer(order_count) or 0
    local destro = parse_first_integer(destro_count) or 0
    if order < 0 then order = 0 end
    if destro < 0 then destro = 0 end
    local total = order + destro
    local order_pct = 0
    local destro_pct = 0
    if total > 0 then
        order_pct = (order * 100) / total
        destro_pct = (destro * 100) / total
    end
    return {
        order = order,
        destro = destro,
        total = total,
        order_pct = order_pct,
        destro_pct = destro_pct
    }
end

local function realmstats_parse_row_count(row, key)
    if type(row) ~= "table" or type(key) ~= "string" then
        return nil
    end
    local value = parse_first_integer(row[key])
    if value == nil then
        return nil
    end
    if value < 0 then
        value = 0
    end
    return value
end

local function realmstats_parse_snapshot_from_row(row, generated_epoch_ms, generated_utc)
    if type(row) ~= "table" then
        return nil
    end

    local overall_order = realmstats_parse_row_count(row, "StatsOrderCount")
    local overall_destro = realmstats_parse_row_count(row, "StatsDestroCount")
    local t1_order = realmstats_parse_row_count(row, "StatsT1OrderCount")
    local t1_destro = realmstats_parse_row_count(row, "StatsT1DestroCount")
    local t2_order = realmstats_parse_row_count(row, "StatsT2PlusOrderCount")
    local t2_destro = realmstats_parse_row_count(row, "StatsT2PlusDestroCount")

    if overall_order == nil or overall_destro == nil or
       t1_order == nil or t1_destro == nil or
       t2_order == nil or t2_destro == nil then
        return nil
    end

    local generated_epoch_ms_number = parse_first_integer(generated_epoch_ms)
    if generated_epoch_ms_number and generated_epoch_ms_number <= 0 then
        generated_epoch_ms_number = nil
    end
    local generated_utc_text = normalize_generated_utc_text(generated_utc)

    return {
        generated_epoch_ms = generated_epoch_ms_number,
        generated_utc = generated_utc_text,
        overall = realmstats_make_bucket(overall_order, overall_destro),
        t1 = realmstats_make_bucket(t1_order, t1_destro),
        t2plus = realmstats_make_bucket(t2_order, t2_destro)
    }
end

local function is_realmrank_placeholder_csv_rows(rows)
    if type(rows) ~= "table" then
        return false
    end
    local metadata_row = rows[1]
    if type(metadata_row) ~= "table" then
        metadata_row = rows["1"]
    end
    if type(metadata_row) ~= "table" then
        return false
    end
    local source = trim_string(metadata_row.Source)
    if not source then
        return false
    end
    local ok_lower, lowered = pcall(string.lower, source)
    return ok_lower == true and lowered == "placeholder"
end

local function parse_realmrank_csv_rows(rows)
    local lookup = {}
    local display_lookup = {}
    local charid_lookup = {}
    local level_lookup = {}
    local careerline_lookup = {}
    local careername_lookup = {}
    local careericon_lookup = {}
    local faction_lookup = {}
    local role_lookup = {}
    local unique_count = 0
    local latest_generated_epoch_ms = nil
    local latest_generated_utc = nil
    local latest_stats_snapshot = nil

    -- CSV v2+ metadata contract: row id 1 carries generated timestamp + stats snapshot.
    local metadata_row = rows and rows[1]
    if type(metadata_row) == "table" then
        local generated_epoch_ms = parse_first_integer(metadata_row.GeneratedEpochMs)
        if generated_epoch_ms ~= nil and generated_epoch_ms <= 0 then
            generated_epoch_ms = nil
        end
        local generated_utc = normalize_generated_utc_text(metadata_row.GeneratedUtc)
        local generated_seconds = nil

        if generated_epoch_ms and generated_epoch_ms > 0 then
            generated_seconds = math.floor(generated_epoch_ms / 1000)
            if not is_valid_realmrank_epoch_seconds(generated_seconds) then
                generated_seconds = nil
            end
        end
        if generated_seconds == nil and generated_utc then
            generated_seconds = parse_generated_utc_epoch_seconds(generated_utc)
        end

        if generated_seconds then
            if generated_epoch_ms and generated_epoch_ms > 0 then
                latest_generated_epoch_ms = generated_epoch_ms
            else
                latest_generated_epoch_ms = nil
            end
            if generated_utc and generated_utc ~= "" then
                latest_generated_utc = generated_utc
            else
                latest_generated_utc = format_epoch_seconds_utc(generated_seconds)
            end
            latest_stats_snapshot = realmstats_parse_snapshot_from_row(
                metadata_row,
                latest_generated_epoch_ms,
                latest_generated_utc
            )
        elseif generated_utc and generated_utc ~= "" then
            latest_generated_utc = generated_utc
        end
    end

    for _, row in pairs(rows) do
        if type(row) == "table" then
            local name_key = nil
            -- Native CSV empty cells are numeric zero, including metadata names.
            local name_lower_raw = row.NameLower ~= 0 and trim_string(row.NameLower) or nil
            if name_lower_raw then
                local ok_lower, lowered = pcall(string.lower, name_lower_raw)
                if ok_lower and lowered and lowered ~= "" then
                    name_key = lowered
                end
            end

            local rr = parse_first_integer(row.RenownRank)
            if rr == nil then
                rr = parse_first_integer(row.RealmRank)
            end
            if rr == nil then
                rr = parse_first_integer(row.RR)
            end
            local level = parse_first_integer(row.Level)
            if level ~= nil and level < 0 then
                level = nil
            end
            local career_line = parse_first_integer(row.CareerLine)
            if career_line ~= nil and career_line <= 0 then
                career_line = nil
            end
            local career_name = trim_string(row.CareerName)
            local career_icon = trim_string(row.CareerIcon)
            local faction = normalize_realmrank_faction(row.Faction)
            local role = normalize_realmrank_role(row.Role)
            local character_id = normalize_realmrank_character_id(row.CharacterId)

            if name_key and rr and rr >= 0 then
                local display_name = uppercase_first_character_ascii(name_key)

                local prev = lookup[name_key]
                if prev == nil then
                    unique_count = unique_count + 1
                    lookup[name_key] = rr
                    display_lookup[name_key] = display_name
                    if character_id ~= nil then
                        charid_lookup[name_key] = character_id
                    end
                    if level ~= nil then
                        level_lookup[name_key] = level
                    end
                    if career_line ~= nil then
                        careerline_lookup[name_key] = career_line
                    end
                    if career_name ~= nil then
                        careername_lookup[name_key] = career_name
                    end
                    if career_icon ~= nil then
                        careericon_lookup[name_key] = career_icon
                    end
                    if faction ~= nil then
                        faction_lookup[name_key] = faction
                    end
                    if role ~= nil then
                        role_lookup[name_key] = role
                    end
                elseif rr > prev then
                    lookup[name_key] = rr
                    display_lookup[name_key] = display_name
                    if character_id ~= nil then
                        charid_lookup[name_key] = character_id
                    else
                        charid_lookup[name_key] = nil
                    end
                    if level ~= nil then
                        level_lookup[name_key] = level
                    else
                        level_lookup[name_key] = nil
                    end
                    if career_line ~= nil then
                        careerline_lookup[name_key] = career_line
                    else
                        careerline_lookup[name_key] = nil
                    end
                    if career_name ~= nil then
                        careername_lookup[name_key] = career_name
                    else
                        careername_lookup[name_key] = nil
                    end
                    if career_icon ~= nil then
                        careericon_lookup[name_key] = career_icon
                    else
                        careericon_lookup[name_key] = nil
                    end
                    if faction ~= nil then
                        faction_lookup[name_key] = faction
                    else
                        faction_lookup[name_key] = nil
                    end
                    if role ~= nil then
                        role_lookup[name_key] = role
                    else
                        role_lookup[name_key] = nil
                    end
                elseif not display_lookup[name_key] and display_name then
                    display_lookup[name_key] = display_name
                end
                if rr == prev and charid_lookup[name_key] == nil and character_id ~= nil then
                    charid_lookup[name_key] = character_id
                end
                if rr == prev and level_lookup[name_key] == nil and level ~= nil then
                    level_lookup[name_key] = level
                end
                if rr == prev and careerline_lookup[name_key] == nil and career_line ~= nil then
                    careerline_lookup[name_key] = career_line
                end
                if rr == prev and careername_lookup[name_key] == nil and career_name ~= nil then
                    careername_lookup[name_key] = career_name
                end
                if rr == prev and careericon_lookup[name_key] == nil and career_icon ~= nil then
                    careericon_lookup[name_key] = career_icon
                end
                if rr == prev and faction_lookup[name_key] == nil and faction ~= nil then
                    faction_lookup[name_key] = faction
                end
                if rr == prev and role_lookup[name_key] == nil and role ~= nil then
                    role_lookup[name_key] = role
                end
            end
        end
    end

    return lookup, display_lookup, charid_lookup, level_lookup, careerline_lookup, careername_lookup, careericon_lookup, faction_lookup, role_lookup, unique_count, build_realmrank_signature(lookup, latest_stats_snapshot), latest_generated_epoch_ms, latest_generated_utc, latest_stats_snapshot
end

function AutoBand.has_realmrank_snapshot_rows()
    if AutoBand.realmrank_csv_placeholder_loaded == true then
        return false
    end
    if type(AutoBand.realmrank_lookup) ~= "table" then
        return false
    end
    return next(AutoBand.realmrank_lookup) ~= nil
end

local function has_realmrank_fallback_cache_entries()
    return
        type(AutoBand.saved) == "table" and
        type(AutoBand.saved.realmrank_fallback_cache) == "table" and
        next(AutoBand.saved.realmrank_fallback_cache) ~= nil
end

local function is_realmrank_csv_auto_refresh_suppressed()
    return AutoBand.realmrank_csv_auto_refresh_suppressed == true
end

function AutoBand.is_realmrank_csv_auto_refresh_suppressed()
    return is_realmrank_csv_auto_refresh_suppressed()
end

function AutoBand.is_realmrank_soft_disabled()
    if AutoBand.realmrank_soft_disabled ~= true then
        return false
    end

    if type(AutoBand.has_realmrank_snapshot_rows) == "function" and AutoBand.has_realmrank_snapshot_rows() then
        AutoBand.realmrank_soft_disabled = false
        return false
    end

    if has_realmrank_fallback_cache_entries() then
        AutoBand.realmrank_soft_disabled = false
        return false
    end

    return true
end

function AutoBand.ensure_realmrank_snapshot_loaded(force_refresh)
    if type(AutoBand.refresh_realmrank_cache) ~= "function" then
        return false
    end
    if force_refresh ~= true and AutoBand.is_realmrank_soft_disabled and AutoBand.is_realmrank_soft_disabled() then
        return false
    end
    if force_refresh ~= true and AutoBand.has_realmrank_snapshot_rows() then
        return true
    end
    if force_refresh ~= true and is_realmrank_csv_auto_refresh_suppressed() then
        return false
    end
    return AutoBand.refresh_realmrank_cache(true) == true
end

function AutoBand.get_realmrank_snapshot_state(require_fresh, options)
    options = type(options) == "table" and options or {}
    local cache_first = options.cache_first == true

    local loaded
    if cache_first then
        loaded = AutoBand.ensure_realmrank_snapshot_loaded(false)
    else
        loaded = AutoBand.ensure_realmrank_snapshot_loaded(true)
    end

    local is_stale = false
    if AutoBand.is_realmrank_data_stale then
        is_stale = AutoBand.is_realmrank_data_stale() == true
    end

    local online_lookup = type(AutoBand.realmrank_lookup) == "table" and AutoBand.realmrank_lookup or nil
    local status = "ok"
    if require_fresh == true and is_stale then
        status = "csv_stale"
    elseif type(online_lookup) ~= "table" or next(online_lookup) == nil then
        if loaded ~= true then
            status = "csv_unavailable"
        else
            status = "csv_empty"
        end
    end

    if status ~= "ok" then
        online_lookup = nil
    end

    return {
        status = status,
        online_lookup = online_lookup,
        display_lookup = type(AutoBand.realmrank_name_lookup) == "table" and AutoBand.realmrank_name_lookup or {},
        charid_lookup = type(AutoBand.realmrank_charid_lookup) == "table" and AutoBand.realmrank_charid_lookup or {},
        level_lookup = type(AutoBand.realmrank_level_lookup) == "table" and AutoBand.realmrank_level_lookup or {},
        careerline_lookup = type(AutoBand.realmrank_careerline_lookup) == "table" and AutoBand.realmrank_careerline_lookup or {},
        careername_lookup = type(AutoBand.realmrank_careername_lookup) == "table" and AutoBand.realmrank_careername_lookup or {},
        careericon_lookup = type(AutoBand.realmrank_careericon_lookup) == "table" and AutoBand.realmrank_careericon_lookup or {},
        faction_lookup = type(AutoBand.realmrank_faction_lookup) == "table" and AutoBand.realmrank_faction_lookup or {},
        role_lookup = type(AutoBand.realmrank_role_lookup) == "table" and AutoBand.realmrank_role_lookup or {},
    }
end

function AutoBand.realmrank_snapshot_miss_reason(status)
    if status == "csv_unavailable" then
        return "online CSV unavailable"
    end
    if status == "csv_stale" then
        return "online CSV is stale"
    end
    if status == "csv_empty" then
        return "online snapshot had no rows"
    end
    return "online snapshot unavailable"
end

function AutoBand.rank_requirement_snapshot_miss_reason(status)
    if status == "csv_stale" then
        return "new rank updates have not come in yet"
    end
    if status == "csv_empty" then
        return "rank updates are not ready yet"
    end
    return "rank updates are currently unavailable"
end

-- RR data changed: redraw the visible page if it shows RR state (Config RR rank
-- steps, Realm stats buttons and data status). Other pages and a hidden window
-- refresh on their next Show().
function AutoBand.refresh_realmrank_ui_if_visible()
    if type(AutoBandWindow) ~= "table" then
        return false
    end
    if type(AutoBandWindow.showing) ~= "function" or AutoBandWindow.showing() ~= true then
        return false
    end
    if AutoBandWindow.SelectedTab ~= AB_const.TABS_CONFIG and AutoBandWindow.SelectedTab ~= AB_const.TABS_REALM then
        return false
    end
    if type(AutoBandWindow.RefreshVisiblePage) ~= "function" then
        return false
    end
    AutoBandWindow.RefreshVisiblePage()
    return true
end

function AutoBand.realmrank_maybe_warn_requirement_snapshot(low_rank_enforcement_enabled)
    local saved = AutoBand.saved
    local effective_min_rank_tank = nil
    local effective_min_rank_healer = nil
    local effective_min_rank_dps = nil
    if type(AutoBand.get_effective_saved_rank_requirements) == "function" then
        effective_min_rank_tank, effective_min_rank_healer, effective_min_rank_dps = AutoBand.get_effective_saved_rank_requirements()
    end
    local rr_requirement_active =
        low_rank_enforcement_enabled == true and
        type(saved) == "table" and
        (
            AutoBand.is_realmrank_requirement_value(effective_min_rank_tank or saved.min_rank_tank or saved.min_rank) or
            AutoBand.is_realmrank_requirement_value(effective_min_rank_healer or saved.min_rank_healer) or
            AutoBand.is_realmrank_requirement_value(effective_min_rank_dps or saved.min_rank_dps or saved.min_rank)
        )

    local rr_warning_state = AutoBand.rankreq_poller_warning_state
    if type(rr_warning_state) ~= "table" then
        rr_warning_state = { status = nil, cooldown_ticks = 0 }
        AutoBand.rankreq_poller_warning_state = rr_warning_state
    end

    if not rr_requirement_active then
        rr_warning_state.status = nil
        rr_warning_state.cooldown_ticks = 0
        return "disabled"
    end

    local status = "ok"
    local has_rows = false
    if type(AutoBand.has_realmrank_snapshot_rows) == "function" then
        has_rows = AutoBand.has_realmrank_snapshot_rows() == true
    end
    if not has_rows then
        status = "csv_unavailable"
    elseif AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
        status = "csv_stale"
    end

    if status ~= "ok" then
        local has_fallback_cache = has_realmrank_fallback_cache_entries()
        if has_fallback_cache and rr_warning_state.status ~= status then
            local rr_warning_reason = "rank updates are currently unavailable"
            if type(AutoBand.rank_requirement_snapshot_miss_reason) == "function" then
                rr_warning_reason = AutoBand.rank_requirement_snapshot_miss_reason(status)
            end
            AB_util.print(
                "[Warning] RR requirement is on, but " ..
                tostring(rr_warning_reason) ..
                ". Known members are still fine. Please restart the rank updater and run /ab csvrefresh."
            )
        end
    end

    rr_warning_state.status = status
    rr_warning_state.cooldown_ticks = 0
    return status
end

function AutoBand.realmrank_ensure_pending_notice_state()
    local pending_notice_state = AutoBand.rankreq_pending_notice_state
    if type(pending_notice_state) ~= "table" then
        pending_notice_state = {}
        AutoBand.rankreq_pending_notice_state = pending_notice_state
    end
    return pending_notice_state
end

function AutoBand.realmrank_clear_pending_notice(player_name, pending_notice_state)
    local state = pending_notice_state
    if type(state) ~= "table" then
        state = AutoBand.realmrank_ensure_pending_notice_state()
    end
    local key = AutoBand.normalize_wb_player_name(player_name)
    if key then
        state[key] = nil
    end
end

function AutoBand.realmrank_maybe_send_pending_notice(player_name, required_rank, pending_notice_state, self_key, notify_fn)
    local state = pending_notice_state
    if type(state) ~= "table" then
        state = AutoBand.realmrank_ensure_pending_notice_state()
    end
    local key = AutoBand.normalize_wb_player_name(player_name)
    if not key or key == self_key then
        return false
    end
    if state[key] then
        return false
    end
    if type(notify_fn) ~= "function" then
        return false
    end

    local req_text = AutoBand.format_rank_requirement_value(required_rank)
    notify_fn(player_name, "Heads up: we're confirming your " .. req_text .. " before enforcing this requirement.")
    state[key] = true
    return true
end

function AutoBand.realmrank_prune_pending_notices(low_rank_enforcement_enabled, pending_notice_state, live_members_by_key, pending_kick_by_key, live_member_state_by_key)
    local state = pending_notice_state
    if type(state) ~= "table" then
        state = AutoBand.realmrank_ensure_pending_notice_state()
    end

    if low_rank_enforcement_enabled ~= true then
        for key, _ in pairs(state) do
            state[key] = nil
        end
        return
    end

    live_members_by_key = type(live_members_by_key) == "table" and live_members_by_key or {}
    pending_kick_by_key = type(pending_kick_by_key) == "table" and pending_kick_by_key or {}
    live_member_state_by_key = type(live_member_state_by_key) == "table" and live_member_state_by_key or {}

    for key, _ in pairs(state) do
        local live_state = live_member_state_by_key[key]
        if not live_members_by_key[key] or pending_kick_by_key[key] or not (live_state and live_state.rank_unknown == true) then
            state[key] = nil
        end
    end
end

function AutoBand.normalize_rank_requirement_value(raw_value, fallback)
    local n = tonumber(raw_value)
    if n == nil then
        n = tonumber(fallback) or 0
    end
    n = math.floor(n)
    if n < CAREER_RANK_REQUIREMENT_MIN then
        n = CAREER_RANK_REQUIREMENT_MIN
    elseif n > AB_const.MAXIMUM_RANK then
        n = AB_const.MAXIMUM_RANK
    end
    if n > CAREER_RANK_REQUIREMENT_MAX and (n % REALMRANK_REQUIREMENT_STEP) ~= 0 then
        local snapped = CAREER_RANK_REQUIREMENT_MAX + REALMRANK_REQUIREMENT_STEP
        if n > CAREER_RANK_REQUIREMENT_MAX + REALMRANK_REQUIREMENT_STEP then
            snapped = n - (n % REALMRANK_REQUIREMENT_STEP)
        end
        n = snapped
    end
    return n
end

function AutoBand.is_realmrank_requirement_value(required_rank)
    local n = AutoBand.normalize_rank_requirement_value(required_rank, 0)
    return n > CAREER_RANK_REQUIREMENT_MAX
end

function AutoBand.is_valid_rank_requirement_step(n)
    if n <= CAREER_RANK_REQUIREMENT_MAX then
        return true
    end
    return (n % REALMRANK_REQUIREMENT_STEP) == 0
end

function AutoBand.get_rank_requirement_metric_label(required_rank)
    if AutoBand.is_realmrank_requirement_value(required_rank) then
        return "RR"
    end
    return "CR"
end

local function normalize_runtime_rank_value(raw_value, max_value)
    local n = tonumber(raw_value)
    if n == nil then
        return nil
    end
    n = math.floor(n)
    if n < 0 then
        n = 0
    end
    if max_value and n > max_value then
        n = max_value
    end
    return n
end

function AutoBand.get_self_current_career_rank()
    local player = GameData and GameData.Player
    return normalize_runtime_rank_value(player and player.level, CAREER_RANK_REQUIREMENT_MAX)
end

function AutoBand.get_self_current_realm_rank()
    local player = GameData and GameData.Player
    local rr_value = nil
    if player and type(player.Renown) == "table" then
        rr_value = normalize_runtime_rank_value(player.Renown.curRank, AB_const.MAXIMUM_RANK)
    end
    if rr_value ~= nil then
        return rr_value
    end

    local self_name = player and player.name
    if self_name and type(AutoBand.get_realm_rank_lookup_result) == "function" then
        local ok_lookup, lookup_result = pcall(AutoBand.get_realm_rank_lookup_result, self_name, { allow_cache_fallback = true })
        if ok_lookup and type(lookup_result) == "table" then
            return normalize_runtime_rank_value(lookup_result.rr, AB_const.MAXIMUM_RANK)
        end
    end
    return nil
end

function AutoBand.get_self_rank_requirement_cap()
    local career_rank = AutoBand.get_self_current_career_rank()
    if career_rank == nil then
        return nil
    end
    if career_rank < CAREER_RANK_REQUIREMENT_MAX then
        return career_rank
    end

    local rr_value = AutoBand.get_self_current_realm_rank()
    if rr_value == nil then
        return CAREER_RANK_REQUIREMENT_MAX
    end

    local rr_cap = math.floor(rr_value / REALMRANK_REQUIREMENT_STEP) * REALMRANK_REQUIREMENT_STEP
    if rr_cap < CAREER_RANK_REQUIREMENT_MAX then
        rr_cap = CAREER_RANK_REQUIREMENT_MAX
    elseif rr_cap > AB_const.MAXIMUM_RANK then
        rr_cap = AB_const.MAXIMUM_RANK
    end
    return rr_cap
end

local function format_metric_rank_token(metric, rank_value)
    return tostring(metric) .. tostring(rank_value) .. "+"
end

local function normalize_rank_requirement_role(role)
    if role == AB_const.TANK or role == "tank" then
        return AB_const.TANK
    end
    if role == AB_const.HEALER or role == "healer" then
        return AB_const.HEALER
    end
    if role == AB_const.MDPS or role == AB_const.RDPS or role == "mdps" or role == "rdps" or role == "dps" then
        return "dps"
    end
    return "dps"
end

local function get_rank_requirement_role_label(role_key, plural)
    if role_key == AB_const.TANK then
        if plural then
            return "tanks"
        end
        return "tank"
    end
    if role_key == AB_const.HEALER then
        if plural then
            return "healers"
        end
        return "healer"
    end
    if plural then
        return "dps"
    end
    return "dps"
end

local function get_saved_rank_requirement_triplet(raw_saved)
    local saved = raw_saved
    if type(saved) ~= "table" then
        saved = AutoBand.saved or {}
    end

    local legacy_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank, AB_const.MINIMUM_RANK)
    local tank_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_tank, legacy_rank)
    local healer_fallback = saved.min_rank_healer
    if healer_fallback == nil then
        healer_fallback = legacy_rank
    end
    local healer_rank = AutoBand.normalize_rank_requirement_value(healer_fallback, AB_const.MINIMUM_RANK_HEALER)
    local dps_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_dps, legacy_rank)
    if saved.min_rank ~= nil and saved.min_rank_tank ~= nil and saved.min_rank_dps ~= nil then
        local saved_tank_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_tank, legacy_rank)
        local saved_dps_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_dps, legacy_rank)
        if saved_tank_rank == saved_dps_rank and legacy_rank ~= saved_tank_rank then
            tank_rank = legacy_rank
            dps_rank = legacy_rank
        end
    end
    return tank_rank, healer_rank, dps_rank
end

function AutoBand.get_saved_rank_requirements(raw_saved)
    return get_saved_rank_requirement_triplet(raw_saved)
end

function AutoBand.sync_legacy_rank_requirement_fields(raw_saved)
    local saved = raw_saved
    if type(saved) ~= "table" then
        saved = AutoBand.saved
    end
    if type(saved) ~= "table" then
        return
    end

    local legacy_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank, AB_const.MINIMUM_RANK)
    local tank_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_tank, legacy_rank)
    local healer_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_healer, AB_const.MINIMUM_RANK_HEALER)
    local dps_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank_dps, legacy_rank)
    saved.min_rank_tank = tank_rank
    saved.min_rank_healer = healer_rank
    saved.min_rank_dps = dps_rank
    if tank_rank > dps_rank then
        saved.min_rank = tank_rank
    else
        saved.min_rank = dps_rank
    end
end

function AutoBand.set_saved_rank_requirements(tank_rank, healer_rank, dps_rank, raw_saved)
    local saved = raw_saved
    if type(saved) ~= "table" then
        if type(AutoBand.saved) ~= "table" then
            AutoBand.saved = {}
        end
        saved = AutoBand.saved
    end
    if type(saved) ~= "table" then
        return nil, nil, nil
    end

    saved.min_rank_tank = AutoBand.normalize_rank_requirement_value(tank_rank, AB_const.MINIMUM_RANK_TANK)
    saved.min_rank_healer = AutoBand.normalize_rank_requirement_value(healer_rank, AB_const.MINIMUM_RANK_HEALER)
    saved.min_rank_dps = AutoBand.normalize_rank_requirement_value(dps_rank, AB_const.MINIMUM_RANK_DPS)
    if saved.min_rank_tank > saved.min_rank_dps then
        saved.min_rank = saved.min_rank_tank
    else
        saved.min_rank = saved.min_rank_dps
    end
    return saved.min_rank_tank, saved.min_rank_healer, saved.min_rank_dps
end

local function get_self_rank_requirement_role()
    if not AutoBand then
        return "dps"
    end

    if type(AutoBand.GetLeaderEffectiveRoleCategory) == "function" then
        local ok_role, role = pcall(AutoBand.GetLeaderEffectiveRoleCategory)
        if ok_role then
            return normalize_rank_requirement_role(role)
        end
    end

    return "dps"
end

function AutoBand.get_effective_rank_requirements(required_rank_tank, required_rank_healer, required_rank_dps)
    local tank_rank = AutoBand.normalize_rank_requirement_value(required_rank_tank, 0)
    local healer_rank = AutoBand.normalize_rank_requirement_value(required_rank_healer, tank_rank)
    local dps_rank = AutoBand.normalize_rank_requirement_value(required_rank_dps, tank_rank)
    local self_cap = AutoBand.get_self_rank_requirement_cap()
    if self_cap ~= nil then
        local self_role = get_self_rank_requirement_role()
        if self_role == AB_const.TANK then
            if tank_rank > self_cap then
                tank_rank = self_cap
            end
        elseif self_role == AB_const.HEALER then
            if healer_rank > self_cap then
                healer_rank = self_cap
            end
        elseif dps_rank > self_cap then
            dps_rank = self_cap
        end
    end
    return tank_rank, healer_rank, dps_rank, self_cap
end

function AutoBand.get_effective_saved_rank_requirements()
    local tank_rank, healer_rank, dps_rank = get_saved_rank_requirement_triplet(AutoBand.saved or {})
    return AutoBand.get_effective_rank_requirements(tank_rank, healer_rank, dps_rank)
end

function AutoBand.get_effective_saved_rank_requirement_for_role(role)
    local tank_rank, healer_rank, dps_rank = AutoBand.get_effective_saved_rank_requirements()
    local role_key = normalize_rank_requirement_role(role)
    if role_key == AB_const.TANK then
        return tank_rank
    end
    if role_key == AB_const.HEALER then
        return healer_rank
    end
    return dps_rank
end

function AutoBand.realmrank_build_backfill_warning_message(risk)
    if risk and risk.mode == "rank-only" then
        local rank_required = risk.required_rank
        if rank_required == nil and type(AutoBand.get_effective_saved_rank_requirement_for_role) == "function" then
            rank_required = AutoBand.get_effective_saved_rank_requirement_for_role(risk and risk.role)
        end
        if rank_required == nil and AutoBand.saved then
            rank_required = AutoBand.saved.min_rank
        end
        if rank_required == nil then
            rank_required = 0
        end

        local required_metric = risk.required_metric
        if not required_metric then
            required_metric = AutoBand.get_rank_requirement_metric_label(rank_required)
        end

        local rank_text = format_metric_rank_token(required_metric, rank_required)
        if risk.rank_unknown and required_metric == "RR" then
            return "Heads up: " .. rank_text .. " required. Your RR is still unconfirmed, so you may be removed later if more players join."
        end
        return "Heads up: " .. rank_text .. " required. You may be removed later if more players join."
    end

    local role_label = tostring((risk and risk.role_label) or "role")
    local blocking_required_slot = risk and risk.blocking_required_slot == true
    local queued_below_rank = risk and risk.queued_below_rank == true
    local required_metric = nil
    local required_rank = nil
    if risk and risk.required_rank then
        required_rank = risk.required_rank
        required_metric = risk.required_metric or AutoBand.get_rank_requirement_metric_label(required_rank)
    end

    if queued_below_rank and not blocking_required_slot then
        if risk and risk.rank_unknown and required_metric == "RR" and required_rank then
            return "Heads up: " .. role_label .. " requires " .. format_metric_rank_token(required_metric, required_rank) .. ". Your RR is still unconfirmed, and you may be removed later if matching players join."
        elseif required_rank and required_metric then
            return "Heads up: " .. role_label .. " requires " .. format_metric_rank_token(required_metric, required_rank) .. ". You may be removed later if matching players join."
        end
        return "Heads up: your current " .. role_label .. " spot may need to open later."
    end

    if blocking_required_slot then
        if risk.rank_unknown and required_metric == "RR" and required_rank then
            return "Heads up: " .. role_label .. " requires " .. format_metric_rank_token(required_metric, required_rank) .. ". Your RR is still unconfirmed, so you may be removed if matching players join."
        elseif required_rank and required_metric then
            return "Heads up: " .. role_label .. " requires " .. format_metric_rank_token(required_metric, required_rank) .. ". You may be removed if matching players join."
        else
            return "Heads up: your current " .. role_label .. " spot may need to open if matching players join."
        end
    end

    if required_rank and required_metric and risk and risk.below_rank then
        return "Heads up: your role (" .. role_label .. ") is overfilled. " .. format_metric_rank_token(required_metric, required_rank) .. " required; you may be removed if matching players join."
    end
    if required_rank and required_metric and risk and risk.rank_unknown and required_metric == "RR" then
        return "Heads up: your role (" .. role_label .. ") is overfilled. " .. format_metric_rank_token(required_metric, required_rank) .. " required; your RR is still unconfirmed and you may be removed if matching players join."
    end
    return "Heads up: your role (" .. role_label .. ") is overfilled and you may be removed if matching players join."
end

function AutoBand.realmrank_build_backfill_safe_message(prev_state, current_state)
    local current_below = current_state and current_state.below_rank == true
    local current_required_rank = current_state and current_state.required_rank
    local current_required_metric = current_state and current_state.required_metric

    if prev_state and prev_state.rank_unknown == true and current_state and current_state.rank_unknown ~= true then
        return "Update: your RR check resolved. You keep your spot unless things change."
    end

    if prev_state and prev_state.below_rank == true and not current_below and current_required_rank then
        if not current_required_metric then
            current_required_metric = AutoBand.get_rank_requirement_metric_label(current_required_rank)
        end
        return "Update: you now meet " .. format_metric_rank_token(current_required_metric, current_required_rank) .. ". You keep your spot unless things change."
    end

    if prev_state and prev_state.blocking_required_slot == true then
        return "Update: your spot is safe for now unless things change."
    end

    local role_label = nil
    if prev_state and prev_state.role_label then
        role_label = tostring(prev_state.role_label)
    end
    if role_label and role_label ~= "" then
        return "Update: more " .. role_label .. " spots opened up. You keep your spot unless things change."
    end

    return "Update: spots opened up. You keep your spot unless things change."
end

function AutoBand.format_rank_requirement_value(required_rank)
    local normalized = AutoBand.normalize_rank_requirement_value(required_rank, 0)
    local metric = AutoBand.get_rank_requirement_metric_label(normalized)
    return format_metric_rank_token(metric, normalized)
end

local function format_rank_requirement_short_value(required_rank)
    local normalized = AutoBand.normalize_rank_requirement_value(required_rank, 0)
    local metric = AutoBand.get_rank_requirement_metric_label(normalized)
    if metric == "CR" then
        return tostring(normalized) .. "+"
    end
    return metric .. tostring(normalized) .. "+"
end

function AutoBand.build_rank_requirement_text(required_rank_tank, required_rank_healer, required_rank_dps, style, opts)
    local tank_rank, healer_rank, dps_rank = AutoBand.get_effective_rank_requirements(required_rank_tank, required_rank_healer, required_rank_dps)
    local visible_roles = {
        { key = AB_const.TANK, rank = tank_rank },
        { key = AB_const.HEALER, rank = healer_rank },
        { key = "dps", rank = dps_rank },
    }
    local explicit_roles = {}
    local visible_count = 0
    local visible_rank = nil
    local all_same = true

    style = style or "long"
    opts = type(opts) == "table" and opts or {}

    if type(opts.show_roles) == "table" then
        local filtered = {}
        for i = 1, #visible_roles do
            local entry = visible_roles[i]
            if opts.show_roles[entry.key] == true then
                filtered[#filtered + 1] = entry
            end
        end
        if #filtered > 0 then
            visible_roles = filtered
        end
    end

    for i = 1, #visible_roles do
        local entry = visible_roles[i]
        visible_count = visible_count + 1
        if visible_rank == nil then
            visible_rank = entry.rank
        elseif entry.rank ~= visible_rank then
            all_same = false
        end
    end

    if visible_count <= 0 then
        visible_roles = {
            { key = AB_const.TANK, rank = tank_rank },
            { key = AB_const.HEALER, rank = healer_rank },
            { key = "dps", rank = dps_rank },
        }
        visible_count = 3
        all_same = (tank_rank == healer_rank) and (healer_rank == dps_rank)
        visible_rank = tank_rank
    end

    if visible_count == 1 then
        local entry = visible_roles[1]
        local role_label = get_rank_requirement_role_label(entry.key, true)
        local rank_token = format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(entry.rank), entry.rank)
        if style == "short" then
            return tostring(role_label) .. " " .. format_rank_requirement_short_value(entry.rank)
        elseif style == "compact" then
            return tostring(role_label) .. " " .. rank_token
        end
        return "Min rank " .. tostring(role_label) .. ": " .. rank_token
    end

    if all_same then
        if style == "short" then
            local metric = AutoBand.get_rank_requirement_metric_label(visible_rank)
            if metric == "CR" then
                return "R " .. tostring(visible_rank) .. "+"
            end
            return format_metric_rank_token(metric, visible_rank)
        elseif style == "compact" then
            return format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(visible_rank), visible_rank)
        end
        return "Min " .. AutoBand.get_rank_requirement_metric_label(visible_rank) .. ": " .. tostring(visible_rank) .. "+"
    end

    if visible_count == 2 and visible_roles[1].rank ~= visible_roles[2].rank then
        for i = 1, #visible_roles do
            explicit_roles[#explicit_roles + 1] = visible_roles[i]
        end
    elseif visible_count == 3 then
        if healer_rank ~= tank_rank and tank_rank == dps_rank and opts.prefer_healer_others ~= false then
            if style == "short" then
                return "heal " .. format_rank_requirement_short_value(healer_rank) .. ", oth " .. format_rank_requirement_short_value(tank_rank)
            elseif style == "compact" then
                return "healers " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(healer_rank), healer_rank) .. ", others " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank)
            end
            return "Min rank healers: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(healer_rank), healer_rank) .. ", others: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank)
        end
        if tank_rank ~= healer_rank and healer_rank == dps_rank then
            if style == "short" then
                return "tank " .. format_rank_requirement_short_value(tank_rank) .. ", oth " .. format_rank_requirement_short_value(healer_rank)
            elseif style == "compact" then
                return "tanks " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank) .. ", others " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(healer_rank), healer_rank)
            end
            return "Min rank tanks: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank) .. ", others: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(healer_rank), healer_rank)
        end
        if dps_rank ~= tank_rank and tank_rank == healer_rank then
            if style == "short" then
                return "dps " .. format_rank_requirement_short_value(dps_rank) .. ", oth " .. format_rank_requirement_short_value(tank_rank)
            elseif style == "compact" then
                return "dps " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(dps_rank), dps_rank) .. ", others " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank)
            end
            return "Min rank dps: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(dps_rank), dps_rank) .. ", others: " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(tank_rank), tank_rank)
        end
    end

    if #explicit_roles == 0 then
        for i = 1, #visible_roles do
            explicit_roles[#explicit_roles + 1] = visible_roles[i]
        end
    end

    local parts = {}
    for i = 1, #explicit_roles do
        local entry = explicit_roles[i]
        local label = get_rank_requirement_role_label(entry.key, false)
        if style == "short" then
            parts[#parts + 1] = tostring(label) .. " " .. format_rank_requirement_short_value(entry.rank)
        else
            parts[#parts + 1] = tostring(get_rank_requirement_role_label(entry.key, true)) .. " " .. format_metric_rank_token(AutoBand.get_rank_requirement_metric_label(entry.rank), entry.rank)
        end
    end

    if style == "short" or style == "compact" then
        return table.concat(parts, ", ")
    end
    return "Min rank " .. table.concat(parts, ", ")
end

local function get_rank_requirement_mode_label(required_rank)
    if AutoBand.is_realmrank_requirement_value(required_rank) then
        return "realm-rank"
    end
    return "career-rank"
end

function AutoBand.can_use_realmrank_requirement(force_refresh)
    local snapshot_state = nil
    if type(AutoBand.get_realmrank_snapshot_state) == "function" then
        snapshot_state = AutoBand.get_realmrank_snapshot_state(true, { cache_first = force_refresh ~= true })
    end
    local ok = snapshot_state and snapshot_state.status == "ok"
    if ok then
        return true, nil, "ok"
    end
    local miss_status = snapshot_state and snapshot_state.status or "csv_unavailable"
    local miss_reason = "rank updates are currently unavailable"
    if type(AutoBand.rank_requirement_snapshot_miss_reason) == "function" then
        miss_reason = AutoBand.rank_requirement_snapshot_miss_reason(miss_status)
    end
    return false, miss_reason, miss_status
end

local function normalize_saved_rank_requirement(raw_value, label)
    local n = tonumber(raw_value)
    if n == nil then
        return AB_const.MINIMUM_RANK
    end
    n = math.floor(n)
    if n < CAREER_RANK_REQUIREMENT_MIN then
        AB_util.print("[Warning] Invalid " .. label .. " value (" .. tostring(raw_value) .. "). Clamping to " .. tostring(CAREER_RANK_REQUIREMENT_MIN) .. ".")
        n = CAREER_RANK_REQUIREMENT_MIN
    elseif n > AB_const.MAXIMUM_RANK then
        AB_util.print("[Warning] Invalid " .. label .. " value (" .. tostring(raw_value) .. "). Clamping to " .. tostring(AB_const.MAXIMUM_RANK) .. ".")
        n = AB_const.MAXIMUM_RANK
    end
    if n > CAREER_RANK_REQUIREMENT_MAX and (n % REALMRANK_REQUIREMENT_STEP) ~= 0 then
        local snapped = CAREER_RANK_REQUIREMENT_MAX + REALMRANK_REQUIREMENT_STEP
        if n > CAREER_RANK_REQUIREMENT_MAX + REALMRANK_REQUIREMENT_STEP then
            snapped = n - (n % REALMRANK_REQUIREMENT_STEP)
        end
        AB_util.print("[Warning] " .. label .. " " .. tostring(n) .. " is not a valid RR step; using " .. tostring(snapped) .. ".")
        n = snapped
    end
    return n
end

function AutoBand.realmrank_init_saved_rank_settings()
    if type(AutoBand.saved) ~= "table" then
        AutoBand.saved = {}
    end

    local legacy_rank = normalize_saved_rank_requirement(AutoBand.saved.min_rank, "Minimum rank requirement")
    local tank_rank = AutoBand.saved.min_rank_tank
    if tank_rank == nil then
        tank_rank = legacy_rank
    end
    local healer_rank = AutoBand.saved.min_rank_healer
    if healer_rank == nil then
        healer_rank = legacy_rank
    end
    local dps_rank = AutoBand.saved.min_rank_dps
    if dps_rank == nil then
        dps_rank = legacy_rank
    end

    AutoBand.saved.min_rank_tank = normalize_saved_rank_requirement(tank_rank, "Minimum tank rank requirement")
    AutoBand.saved.min_rank_healer = normalize_saved_rank_requirement(healer_rank, "Minimum healer rank requirement")
    AutoBand.saved.min_rank_dps = normalize_saved_rank_requirement(dps_rank, "Minimum dps rank requirement")
    AutoBand.sync_legacy_rank_requirement_fields(AutoBand.saved)

    if AutoBand.apply_saved_rank_requirement_startup_policy then
        AutoBand.apply_saved_rank_requirement_startup_policy()
    end
end

function AutoBand.apply_saved_rank_requirement_startup_policy()
    if type(AutoBand) ~= "table" or type(AutoBand.saved) ~= "table" then
        return false, "settings unavailable", "missing_saved"
    end

    local min_rank_tank, min_rank_healer, min_rank_dps = get_saved_rank_requirement_triplet(AutoBand.saved)

    local needs_rr =
        (min_rank_tank > CAREER_RANK_REQUIREMENT_MAX) or
        (min_rank_healer > CAREER_RANK_REQUIREMENT_MAX) or
        (min_rank_dps > CAREER_RANK_REQUIREMENT_MAX)
    if not needs_rr then
        AutoBand.set_saved_rank_requirements(min_rank_tank, min_rank_healer, min_rank_dps, AutoBand.saved)
        return false, nil, "not_needed"
    end

    local ok_rr, miss_reason = AutoBand.can_use_realmrank_requirement(true)
    if ok_rr then
        AutoBand.set_saved_rank_requirements(min_rank_tank, min_rank_healer, min_rank_dps, AutoBand.saved)
        return false, nil, "rr_available"
    end

    local changed = false
    if min_rank_tank > CAREER_RANK_REQUIREMENT_MAX then
        min_rank_tank = CAREER_RANK_REQUIREMENT_MAX
        changed = true
    end
    if min_rank_healer > CAREER_RANK_REQUIREMENT_MAX then
        min_rank_healer = CAREER_RANK_REQUIREMENT_MAX
        changed = true
    end
    if min_rank_dps > CAREER_RANK_REQUIREMENT_MAX then
        min_rank_dps = CAREER_RANK_REQUIREMENT_MAX
        changed = true
    end

    AutoBand.set_saved_rank_requirements(min_rank_tank, min_rank_healer, min_rank_dps, AutoBand.saved)

    if changed then
        AB_util.print("[Warning] " .. tostring(miss_reason or "RR updates unavailable") .. ". Saved RR rank requirements were reset to CR 40.")
    end
    return changed, miss_reason, "reset_to_40"
end

function AutoBand.get_rank_requirement_status_for_player(player, required_rank, opts)
    opts = type(opts) == "table" and opts or {}
    local normalized_required = AutoBand.normalize_rank_requirement_value(required_rank, 0)
    local metric_label = AutoBand.get_rank_requirement_metric_label(normalized_required)
    local status = {
        required_rank = normalized_required,
        required_metric = metric_label,
        mode = get_rank_requirement_mode_label(normalized_required),
        has_rank_info = false,
        rank_value = nil,
        below_required = false,
        rr_unknown = false,
        rr_source = nil,
    }

    if metric_label == "CR" then
        local level = tonumber(player and player.level)
        if level ~= nil then
            level = math.floor(level)
            if level < 0 then
                level = 0
            end
            status.has_rank_info = true
            status.rank_value = level
            status.below_required = level < normalized_required
        end
        return status
    end

    local lookup_result = nil
    if player and player.name and type(AutoBand.get_realm_rank_lookup_result) == "function" then
        local ok_lookup, value = pcall(AutoBand.get_realm_rank_lookup_result, player.name, { allow_cache_fallback = true })
        if ok_lookup and type(value) == "table" then
            lookup_result = value
        end
    end

    if lookup_result and lookup_result.rr ~= nil then
        local rr = tonumber(lookup_result.rr)
        if rr ~= nil then
            rr = math.floor(rr)
            if rr < CAREER_RANK_REQUIREMENT_MAX then
                rr = CAREER_RANK_REQUIREMENT_MAX
            end
            if rr >= 0 then
                status.has_rank_info = true
                status.rank_value = rr
                status.rr_source = lookup_result.source
                status.below_required = rr < normalized_required
                return status
            end
        end
    end

    status.rr_unknown = true
    status.has_rank_info = false
    if opts.treat_unknown_rr_as_below then
        status.below_required = true
    end
    return status
end

function AutoBand.get_realmrank_refresh_interval_seconds()
    local seconds = REALMRANK_REFRESH_DEFAULT_SECONDS
    if AutoBand.saved and type(AutoBand.saved.realmrank_refresh_seconds) == "number" then
        seconds = AutoBand.saved.realmrank_refresh_seconds
    end
    if seconds < REALMRANK_REFRESH_MIN_SECONDS then
        seconds = REALMRANK_REFRESH_MIN_SECONDS
    elseif seconds > REALMRANK_REFRESH_MAX_SECONDS then
        seconds = REALMRANK_REFRESH_MAX_SECONDS
    end
    return seconds
end

function AutoBand.should_suspend_realmrank_refresh_for_combat()
    if GameData and GameData.Player then
        local in_combat = GameData.Player.inCombat
        if type(in_combat) == "boolean" then
            return in_combat
        end
        local in_combat_alt = GameData.Player.isInCombat
        if type(in_combat_alt) == "boolean" then
            return in_combat_alt
        end
    end
    return false
end

function AutoBand.refresh_realmrank_cache(force)
    force = force == true

    if not force and AutoBand.is_realmrank_soft_disabled and AutoBand.is_realmrank_soft_disabled() then
        return false, false
    end
    if not force and is_realmrank_csv_auto_refresh_suppressed() then
        return false, false
    end

    if type(AutoBand.realmrank_lookup) ~= "table" then
        AutoBand.realmrank_lookup = {}
    end
    if type(AutoBand.realmrank_name_lookup) ~= "table" then
        AutoBand.realmrank_name_lookup = {}
    end
    if type(AutoBand.realmrank_charid_lookup) ~= "table" then
        AutoBand.realmrank_charid_lookup = {}
    end
    if type(AutoBand.realmrank_level_lookup) ~= "table" then
        AutoBand.realmrank_level_lookup = {}
    end
    if type(AutoBand.realmrank_careerline_lookup) ~= "table" then
        AutoBand.realmrank_careerline_lookup = {}
    end
    if type(AutoBand.realmrank_careername_lookup) ~= "table" then
        AutoBand.realmrank_careername_lookup = {}
    end
    if type(AutoBand.realmrank_careericon_lookup) ~= "table" then
        AutoBand.realmrank_careericon_lookup = {}
    end
    if type(AutoBand.realmrank_faction_lookup) ~= "table" then
        AutoBand.realmrank_faction_lookup = {}
    end
    if type(AutoBand.realmrank_role_lookup) ~= "table" then
        AutoBand.realmrank_role_lookup = {}
    end
    if AutoBand.realmrank_row_count == nil then
        AutoBand.realmrank_row_count = 0
    end
    if type(AutoBand._realm_rank_csv_rows) ~= "table" then
        AutoBand._realm_rank_csv_rows = {}
    end

    if not force then
        if not AutoBand.saved or AutoBand.saved.realmrank_lookup_enabled ~= true then
            return false, false
        end
        if AutoBand.should_suspend_realmrank_refresh_for_combat() then
            return false, false
        end
    end

    AutoBand.realmstats_snapshot = nil
    AutoBand.realmrank_csv_placeholder_loaded = false

    if type(BuildTableFromCSV) ~= "function" then
        return false, false
    end

    local paths = get_realmrank_csv_path_candidates()
    for _, path in ipairs(paths) do
        AutoBand._realm_rank_csv_rows = {}
        local ok_load, load_result = pcall(BuildTableFromCSV, path, REALMRANK_CSV_TABLE_NAME)
        if ok_load and load_result ~= false then
            local row_count = 0
            for _, row in pairs(AutoBand._realm_rank_csv_rows) do
                if type(row) == "table" then
                    row_count = row_count + 1
                end
            end
            if row_count > 0 then
                local lookup, name_lookup, charid_lookup, level_lookup, careerline_lookup, careername_lookup, careericon_lookup, faction_lookup, role_lookup, unique_count, signature, generated_epoch_ms, generated_utc, stats_snapshot = parse_realmrank_csv_rows(AutoBand._realm_rank_csv_rows)
                local placeholder_loaded = is_realmrank_placeholder_csv_rows(AutoBand._realm_rank_csv_rows)
                if placeholder_loaded then
                    lookup = {}
                    name_lookup = {}
                    charid_lookup = {}
                    level_lookup = {}
                    careerline_lookup = {}
                    careername_lookup = {}
                    careericon_lookup = {}
                    faction_lookup = {}
                    role_lookup = {}
                    unique_count = 0
                    signature = build_realmrank_signature(nil, nil)
                    generated_epoch_ms = nil
                    generated_utc = nil
                    stats_snapshot = nil
                end
                local changed = (signature ~= AutoBand.realmrank_signature)
                AutoBand.realmrank_lookup = lookup
                AutoBand.realmrank_name_lookup = name_lookup
                AutoBand.realmrank_charid_lookup = charid_lookup
                AutoBand.realmrank_level_lookup = level_lookup
                AutoBand.realmrank_careerline_lookup = careerline_lookup
                AutoBand.realmrank_careername_lookup = careername_lookup
                AutoBand.realmrank_careericon_lookup = careericon_lookup
                AutoBand.realmrank_faction_lookup = faction_lookup
                AutoBand.realmrank_role_lookup = role_lookup
                AutoBand.realmrank_signature = signature
                AutoBand.realmrank_row_count = unique_count
                AutoBand.realmrank_resolved_csv_path = path
                AutoBand.realmrank_generated_epoch_ms = generated_epoch_ms
                AutoBand.realmrank_generated_utc = generated_utc
                AutoBand.realmstats_snapshot = stats_snapshot
                AutoBand.realmrank_csv_placeholder_loaded = placeholder_loaded == true
                AutoBand.realmrank_soft_disabled = false
                AutoBand.realmrank_csv_auto_refresh_suppressed = false
                return true, changed
            end
            AutoBand.realmrank_resolved_csv_path = path
        end
    end

    if (force or (AutoBand.saved and AutoBand.saved.realmrank_lookup_enabled == true)) and
       (type(AutoBand.has_realmrank_snapshot_rows) ~= "function" or AutoBand.has_realmrank_snapshot_rows() ~= true) and
       not has_realmrank_fallback_cache_entries() then
        AutoBand.realmrank_soft_disabled = true
    end
    if force or (AutoBand.saved and AutoBand.saved.realmrank_lookup_enabled == true) then
        AutoBand.realmrank_csv_auto_refresh_suppressed = true
    end

    return false, false
end

local function get_current_game_time_seconds()
    if type(GetGameTime) ~= "function" then
        return nil
    end
    local ok_time, now_time = pcall(GetGameTime)
    if not ok_time then
        return nil
    end
    now_time = tonumber(now_time)
    if not now_time then
        return nil
    end
    now_time = math.floor(now_time)
    if now_time <= 0 then
        return nil
    end
    return now_time
end

local function get_realmrank_generated_epoch_seconds()
    local generated_seconds = get_realmrank_generated_epoch_seconds_with_source()
    return generated_seconds
end

local function get_realmrank_time_anchor()
    if not AutoBand.saved then
        return nil, nil
    end

    local epoch_s = parse_first_integer(AutoBand.saved.realmrank_time_anchor_epoch_s)
    if epoch_s == nil or epoch_s <= 0 then
        epoch_s = nil
    end

    local game_s = parse_first_integer(AutoBand.saved.realmrank_time_anchor_game_s)
    if game_s == nil or game_s <= 0 then
        game_s = nil
    end

    return epoch_s, game_s
end

local function set_realmrank_time_anchor(epoch_seconds, game_seconds)
    AutoBand.saved = AutoBand.saved or {}

    local epoch_s = parse_first_integer(epoch_seconds)
    if epoch_s == nil or epoch_s <= 0 then
        return false
    end

    local game_s = parse_first_integer(game_seconds)
    AutoBand.saved.realmrank_time_anchor_epoch_s = epoch_s
    if game_s ~= nil and game_s > 0 then
        AutoBand.saved.realmrank_time_anchor_game_s = game_s
    else
        AutoBand.saved.realmrank_time_anchor_game_s = nil
    end
    return true
end

local function get_realmrank_cache_now_seconds_with_source()
    local game_seconds = get_current_game_time_seconds()
    local generated_seconds, generated_source = get_realmrank_generated_epoch_seconds_with_source()
    local anchor_epoch_s, anchor_game_s = get_realmrank_time_anchor()

    if generated_seconds ~= nil then
        if anchor_epoch_s == nil or generated_seconds > anchor_epoch_s then
            set_realmrank_time_anchor(generated_seconds, game_seconds)
            anchor_epoch_s, anchor_game_s = get_realmrank_time_anchor()
        elseif anchor_game_s == nil and game_seconds ~= nil then
            set_realmrank_time_anchor(anchor_epoch_s, game_seconds)
            anchor_epoch_s, anchor_game_s = get_realmrank_time_anchor()
        end
    end

    if anchor_epoch_s == nil then
        if generated_seconds ~= nil then
            return generated_seconds, generated_source
        end
        return nil, "none"
    end

    if game_seconds == nil then
        return anchor_epoch_s, "anchor"
    end

    if anchor_game_s == nil then
        set_realmrank_time_anchor(anchor_epoch_s, game_seconds)
        return anchor_epoch_s, "anchor-init"
    end

    if game_seconds < anchor_game_s then
        set_realmrank_time_anchor(anchor_epoch_s, game_seconds)
        return anchor_epoch_s, "anchor-rebased"
    end

    local delta = game_seconds - anchor_game_s
    if delta > 0 then
        local estimated_now = anchor_epoch_s + delta
        set_realmrank_time_anchor(estimated_now, game_seconds)
        return estimated_now, "anchor+uptime"
    end

    return anchor_epoch_s, "anchor"
end

function AutoBand.get_realmrank_cache_now_seconds()
    local now_seconds = get_realmrank_cache_now_seconds_with_source()
    return now_seconds
end

function AutoBand.get_realmrank_data_age_seconds_with_details()
    local details = {
        generated_seconds = nil,
        generated_source = "none",
        now_seconds = nil,
        now_source = "none",
        game_seconds = nil,
        anchor_epoch_s = nil,
        anchor_game_s = nil,
        reason = "unknown"
    }

    local generated_seconds, generated_source = get_realmrank_generated_epoch_seconds_with_source()
    details.generated_seconds = generated_seconds
    details.generated_source = generated_source or "none"
    if generated_seconds == nil then
        details.reason = "generated_missing"
        details.game_seconds = get_current_game_time_seconds()
        details.anchor_epoch_s, details.anchor_game_s = get_realmrank_time_anchor()
        return nil, details
    end

    local now_seconds, now_source = get_realmrank_cache_now_seconds_with_source()
    details.now_seconds = now_seconds
    details.now_source = now_source or "none"
    details.game_seconds = get_current_game_time_seconds()
    details.anchor_epoch_s, details.anchor_game_s = get_realmrank_time_anchor()
    if now_seconds == nil then
        details.reason = "now_missing"
        return nil, details
    end

    local age_seconds = now_seconds - generated_seconds
    if age_seconds < 0 then
        age_seconds = 0
    end
    details.reason = "ok"
    return age_seconds, details
end

function AutoBand.debug_realmrank_stale_check(details, age_seconds, stale)
    if AutoBand.debugon ~= true then
        return
    end
    if type(AB_util) ~= "table" or type(AB_util.debug) ~= "function" then
        return
    end

    details = type(details) == "table" and details or {}
    local reason = tostring(details.reason or "unknown")
    local state_changed = AutoBand.realmrank_stale_debug_last_state ~= stale
    local reason_changed = AutoBand.realmrank_stale_debug_last_reason ~= reason

    local tick = parse_first_integer(details.game_seconds)
    if tick == nil or tick <= 0 then
        tick = parse_first_integer(details.now_seconds)
    end
    local last_tick = parse_first_integer(AutoBand.realmrank_stale_debug_last_emit_tick_s)

    local should_emit = false
    if state_changed or reason_changed then
        should_emit = true
    elseif tick == nil or tick <= 0 or last_tick == nil or tick < last_tick then
        should_emit = true
    elseif (tick - last_tick) >= 15 then
        should_emit = true
    end
    if not should_emit then
        return
    end

    if tick ~= nil and tick > 0 then
        AutoBand.realmrank_stale_debug_last_emit_tick_s = tick
    end
    AutoBand.realmrank_stale_debug_last_state = stale
    AutoBand.realmrank_stale_debug_last_reason = reason

    AB_util.debug(
        "[debug][rr-stale] stale=" .. tostring(stale) ..
        " age=" .. tostring(age_seconds) .. "/" .. tostring(REALMRANK_STALE_MAX_AGE_SECONDS) .. "s" ..
        " generated=" .. tostring(details.generated_seconds) .. " (" .. tostring(details.generated_source) .. ")" ..
        " now=" .. tostring(details.now_seconds) .. " (" .. tostring(details.now_source) .. ")" ..
        " game=" .. tostring(details.game_seconds) ..
        " anchor=" .. tostring(details.anchor_epoch_s) .. "/" .. tostring(details.anchor_game_s) ..
        " reason=" .. reason
    )
end

function AutoBand.is_realmrank_data_stale()
    if AutoBand.realmrank_csv_placeholder_loaded == true then
        local details = {
            reason = "placeholder",
            generated_source = "placeholder",
            now_source = "none",
            game_seconds = get_current_game_time_seconds()
        }
        details.anchor_epoch_s, details.anchor_game_s = get_realmrank_time_anchor()
        AutoBand.debug_realmrank_stale_check(details, nil, true)
        return true
    end

    local age_seconds, details = AutoBand.get_realmrank_data_age_seconds_with_details()
    local stale = false
    if age_seconds ~= nil then
        stale = age_seconds > REALMRANK_STALE_MAX_AGE_SECONDS
    end
    AutoBand.debug_realmrank_stale_check(details, age_seconds, stale)
    return stale
end

-- Same "now" as get_realmrank_cache_now_seconds_with_source, without moving the saved
-- time anchor, so availability checks stay read-only.
local function peek_realmrank_data_age_seconds()
    local generated_seconds = get_realmrank_generated_epoch_seconds_with_source()
    if generated_seconds == nil then
        return nil
    end
    local anchor_epoch_s, anchor_game_s = get_realmrank_time_anchor()
    local game_seconds = get_current_game_time_seconds()
    local now_seconds
    if anchor_epoch_s == nil or generated_seconds > anchor_epoch_s then
        now_seconds = generated_seconds
    elseif game_seconds == nil or anchor_game_s == nil or game_seconds < anchor_game_s then
        now_seconds = anchor_epoch_s
    else
        now_seconds = anchor_epoch_s + (game_seconds - anchor_game_s)
    end
    local age_seconds = now_seconds - generated_seconds
    if age_seconds < 0 then
        age_seconds = 0
    end
    return age_seconds
end

-- Early gate for everything that needs usable, fresh realm-rank CSV data (settings UI
-- state and tooltips, and the UI handlers before they collect, print, queue or
-- activate anything). Purely reads cached state: never calls BuildTableFromCSV or
-- refresh_realmrank_cache and never writes saved values. Returns ok, status, reason,
-- age_seconds. status: ok, lookup_disabled, placeholder, missing, empty, stale.
-- Rows without a generated timestamp keep the legacy behaviour (usable, never stale);
-- age_seconds is then nil and the UI shows "age unknown", not "Fresh".
function AutoBand.peek_realmrank_availability()
    local saved = type(AutoBand.saved) == "table" and AutoBand.saved or {}
    if saved.realmrank_lookup_enabled ~= true then
        return false, "lookup_disabled", "Rank data is off (Use realm-rank CSV)."
    end
    if AutoBand.realmrank_csv_placeholder_loaded == true then
        return false, "placeholder", "Rank data is a placeholder (start the poller)."
    end
    if type(AutoBand.realmrank_lookup) ~= "table" or next(AutoBand.realmrank_lookup) == nil then
        if type(AutoBand.realmrank_resolved_csv_path) == "string" and AutoBand.realmrank_resolved_csv_path ~= "" then
            return false, "empty", "Rank data has no rows yet."
        end
        return false, "missing", "No rank data loaded (Refresh now)."
    end
    local age_seconds = peek_realmrank_data_age_seconds()
    if age_seconds ~= nil and age_seconds > REALMRANK_STALE_MAX_AGE_SECONDS then
        return false, "stale",
            "Rank data is " .. tostring(math.floor(age_seconds / 60)) .. " min old (Refresh now).", age_seconds
    end
    return true, "ok", nil, age_seconds
end

-- Realm stats additionally need the stats columns in the loaded CSV.
function AutoBand.peek_realmstats_availability()
    local ok, status, reason, age_seconds = AutoBand.peek_realmrank_availability()
    if not ok then
        return false, status, reason, age_seconds
    end
    local snapshot = AutoBand.realmstats_snapshot
    if type(snapshot) ~= "table" or type(snapshot.overall) ~= "table" then
        return false, "stats_missing", "Rank data has no realm stats.", age_seconds
    end
    return true, "ok", nil, age_seconds
end

local function ensure_realmrank_fallback_cache()
    AutoBand.saved = AutoBand.saved or {}
    if type(AutoBand.saved.realmrank_fallback_cache) ~= "table" then
        AutoBand.saved.realmrank_fallback_cache = {}
    end
    return AutoBand.saved.realmrank_fallback_cache
end

function AutoBand.cleanup_realmrank_fallback_cache(force, now_seconds)
    local cache = ensure_realmrank_fallback_cache()
    local now = now_seconds
    if now == nil then
        now = AutoBand.get_realmrank_cache_now_seconds()
    end
    if now == nil then
        return 0
    end

    force = force == true
    if not force and
       type(AutoBand.should_suspend_realmrank_refresh_for_combat) == "function" and
       AutoBand.should_suspend_realmrank_refresh_for_combat() == true then
        return 0
    end
    if not force then
        local last_cleanup = parse_first_integer(AutoBand.saved.realmrank_fallback_last_cleanup_epoch_s)
        if last_cleanup ~= nil and last_cleanup > 0 and
           (now - last_cleanup) < REALMRANK_FALLBACK_CLEAN_INTERVAL_SECONDS then
            return 0
        end
    end

    local removed = 0
    local retained_keys = {}
    for key, entry in pairs(cache) do
        local should_drop = false
        if type(key) ~= "string" then
            should_drop = true
        elseif type(entry) ~= "table" then
            should_drop = true
        else
            local rr_number = tonumber(entry.rr)
            if rr_number == nil then
                rr_number = tonumber(entry.realmrank)
            end
            if rr_number == nil then
                should_drop = true
            else
                rr_number = math.floor(rr_number)
                if rr_number < 0 then
                    should_drop = true
                end
            end

            if not should_drop then
                local normalized_character_id = normalize_realmrank_character_id(entry.char_id)
                if normalized_character_id ~= nil then
                    entry.char_id = normalized_character_id
                else
                    entry.char_id = nil
                end

                local normalized_career_line = normalize_realmrank_career_line(entry.career_line)
                if normalized_career_line ~= nil then
                    entry.career_line = normalized_career_line
                else
                    entry.career_line = nil
                end

                local normalized_level = parse_first_integer(entry.level)
                if normalized_level ~= nil and normalized_level >= 0 then
                    entry.level = normalized_level
                else
                    entry.level = nil
                end

                local normalized_career_name = trim_string(entry.career_name)
                if normalized_career_name ~= nil then
                    entry.career_name = normalized_career_name
                else
                    entry.career_name = nil
                end

                local normalized_career_icon = trim_string(entry.career_icon)
                if normalized_career_icon ~= nil then
                    entry.career_icon = normalized_career_icon
                else
                    entry.career_icon = nil
                end

                local normalized_faction = normalize_realmrank_faction(entry.faction)
                if normalized_faction ~= nil then
                    entry.faction = normalized_faction
                else
                    entry.faction = nil
                end

                local normalized_role = normalize_realmrank_role(entry.role)
                if normalized_role ~= nil then
                    entry.role = normalized_role
                else
                    entry.role = nil
                end
            end

            if not should_drop then
                local last_seen_epoch_s = parse_first_integer(entry.last_seen_epoch_s)
                if last_seen_epoch_s == nil or last_seen_epoch_s <= 0 then
                    should_drop = true
                elseif (now - last_seen_epoch_s) > REALMRANK_FALLBACK_MAX_AGE_SECONDS then
                    should_drop = true
                end
            end
        end

        if should_drop then
            cache[key] = nil
            removed = removed + 1
        else
            retained_keys[#retained_keys + 1] = key
        end
    end

    local retained_count = #retained_keys
    if retained_count > REALMRANK_FALLBACK_MAX_ENTRIES then
        local retained_entries = {}
        for i = 1, retained_count do
            local key = retained_keys[i]
            local entry = cache[key]
            retained_entries[i] = {
                key = key,
                last_seen_epoch_s = parse_first_integer(entry and entry.last_seen_epoch_s) or 0
            }
        end

        table.sort(retained_entries, function(a, b)
            if a.last_seen_epoch_s ~= b.last_seen_epoch_s then
                return a.last_seen_epoch_s < b.last_seen_epoch_s
            end
            return tostring(a.key) < tostring(b.key)
        end)

        local overflow = retained_count - REALMRANK_FALLBACK_MAX_ENTRIES
        for i = 1, overflow do
            local item = retained_entries[i]
            if item and item.key ~= nil then
                cache[item.key] = nil
                removed = removed + 1
            end
        end
    end

    AutoBand.saved.realmrank_fallback_last_cleanup_epoch_s = now
    return removed
end

local function summarize_realmrank_fallback_cache_entry(raw_key, raw_entry, now_seconds)
    local item = {
        key = nil,
        display_name = nil,
        rr = nil,
        last_seen_epoch_s = nil,
        last_seen_utc = nil,
        age_seconds = nil,
        status = "invalid",
        invalid_reason = "invalid_entry"
    }

    if type(raw_key) ~= "string" or raw_key == "" then
        local key_text = tostring(raw_key or "")
        if key_text == "" then
            key_text = "?"
        end
        item.key = key_text
        item.display_name = key_text
        item.invalid_reason = "invalid_key"
        return item
    end

    item.key = raw_key
    item.display_name = raw_key

    if type(raw_entry) ~= "table" then
        item.invalid_reason = "invalid_entry"
        return item
    end

    local display_name = trim_string(raw_entry.name)
    if display_name ~= nil then
        item.display_name = display_name
    end

    local rr_number = tonumber(raw_entry.rr)
    if rr_number == nil then
        rr_number = tonumber(raw_entry.realmrank)
    end
    if rr_number == nil then
        item.invalid_reason = "invalid_rr"
        return item
    end
    rr_number = math.floor(rr_number)
    if rr_number < 0 then
        item.invalid_reason = "invalid_rr"
        return item
    end
    item.rr = rr_number

    local last_seen_epoch_s = parse_first_integer(raw_entry.last_seen_epoch_s)
    if last_seen_epoch_s == nil or last_seen_epoch_s <= 0 then
        item.invalid_reason = "invalid_last_seen"
        return item
    end

    item.last_seen_epoch_s = last_seen_epoch_s
    item.last_seen_utc = format_epoch_seconds_utc(last_seen_epoch_s)

    if now_seconds ~= nil then
        local age_seconds = now_seconds - last_seen_epoch_s
        if age_seconds < 0 then
            age_seconds = 0
        end
        item.age_seconds = age_seconds
        if age_seconds > REALMRANK_FALLBACK_MAX_AGE_SECONDS then
            item.status = "expired"
            item.invalid_reason = nil
            return item
        end
    end

    item.status = "valid"
    item.invalid_reason = nil
    return item
end

local function sort_realmrank_fallback_cache_items_oldest_first(items)
    if type(items) ~= "table" then
        return
    end

    table.sort(items, function(a, b)
        local a_seen = parse_first_integer(a and a.last_seen_epoch_s) or 0
        local b_seen = parse_first_integer(b and b.last_seen_epoch_s) or 0
        if a_seen ~= b_seen then
            return a_seen < b_seen
        end
        return tostring(a and a.key or "") < tostring(b and b.key or "")
    end)
end

function AutoBand.get_realmrank_fallback_cache_summary(limit)
    local cache = ensure_realmrank_fallback_cache()
    local now_seconds = AutoBand.get_realmrank_cache_now_seconds()
    local safe_limit = parse_first_integer(limit)
    if safe_limit == nil or safe_limit <= 0 then
        safe_limit = 5
    elseif safe_limit > 20 then
        safe_limit = 20
    end

    local last_cleanup_epoch_s = parse_first_integer(AutoBand.saved and AutoBand.saved.realmrank_fallback_last_cleanup_epoch_s)
    if last_cleanup_epoch_s ~= nil and last_cleanup_epoch_s <= 0 then
        last_cleanup_epoch_s = nil
    end

    local summary = {
        limit = safe_limit,
        now_seconds = now_seconds,
        now_utc = now_seconds and format_epoch_seconds_utc(now_seconds) or nil,
        last_cleanup_epoch_s = last_cleanup_epoch_s,
        last_cleanup_utc = last_cleanup_epoch_s and format_epoch_seconds_utc(last_cleanup_epoch_s) or nil,
        last_cleanup_age_seconds = nil,
        raw_count = 0,
        valid_count = 0,
        expired_count = 0,
        invalid_count = 0,
        over_cap_count = 0,
        effective_count = 0,
        valid_known_age_count = 0,
        newest_valid_age_seconds = nil,
        oldest_valid_age_seconds = nil,
        average_valid_age_seconds = nil,
        age_bucket_counts = {
            under_1h = 0,
            under_1d = 0,
            under_7d = 0,
            under_14d = 0,
            unknown = 0
        },
        oldest_valid_entries = {},
        newest_valid_entries = {},
        policy_max_age_seconds = REALMRANK_FALLBACK_MAX_AGE_SECONDS,
        policy_clean_interval_seconds = REALMRANK_FALLBACK_CLEAN_INTERVAL_SECONDS,
        policy_max_entries = REALMRANK_FALLBACK_MAX_ENTRIES
    }

    if last_cleanup_epoch_s ~= nil and now_seconds ~= nil then
        local cleanup_age_seconds = now_seconds - last_cleanup_epoch_s
        if cleanup_age_seconds < 0 then
            cleanup_age_seconds = 0
        end
        summary.last_cleanup_age_seconds = cleanup_age_seconds
    end

    local valid_items = {}
    local total_age_seconds = 0
    local known_age_count = 0

    for raw_key, raw_entry in pairs(cache) do
        summary.raw_count = summary.raw_count + 1
        local item = summarize_realmrank_fallback_cache_entry(raw_key, raw_entry, now_seconds)
        if item.status == "valid" then
            summary.valid_count = summary.valid_count + 1
            valid_items[#valid_items + 1] = item

            local age_seconds = item.age_seconds
            if age_seconds ~= nil then
                known_age_count = known_age_count + 1
                total_age_seconds = total_age_seconds + age_seconds
                if summary.newest_valid_age_seconds == nil or age_seconds < summary.newest_valid_age_seconds then
                    summary.newest_valid_age_seconds = age_seconds
                end
                if summary.oldest_valid_age_seconds == nil or age_seconds > summary.oldest_valid_age_seconds then
                    summary.oldest_valid_age_seconds = age_seconds
                end

                if age_seconds < 60 * 60 then
                    summary.age_bucket_counts.under_1h = summary.age_bucket_counts.under_1h + 1
                elseif age_seconds < 24 * 60 * 60 then
                    summary.age_bucket_counts.under_1d = summary.age_bucket_counts.under_1d + 1
                elseif age_seconds < 7 * 24 * 60 * 60 then
                    summary.age_bucket_counts.under_7d = summary.age_bucket_counts.under_7d + 1
                else
                    summary.age_bucket_counts.under_14d = summary.age_bucket_counts.under_14d + 1
                end
            else
                summary.age_bucket_counts.unknown = summary.age_bucket_counts.unknown + 1
            end
        elseif item.status == "expired" then
            summary.expired_count = summary.expired_count + 1
        else
            summary.invalid_count = summary.invalid_count + 1
        end
    end

    summary.valid_known_age_count = known_age_count
    if known_age_count > 0 then
        summary.average_valid_age_seconds = math.floor(total_age_seconds / known_age_count)
    end

    if summary.valid_count > REALMRANK_FALLBACK_MAX_ENTRIES then
        summary.over_cap_count = summary.valid_count - REALMRANK_FALLBACK_MAX_ENTRIES
    end
    summary.effective_count = summary.valid_count - summary.over_cap_count

    sort_realmrank_fallback_cache_items_oldest_first(valid_items)

    local take_count = safe_limit
    if take_count > #valid_items then
        take_count = #valid_items
    end

    for i = 1, take_count do
        summary.oldest_valid_entries[#summary.oldest_valid_entries + 1] = valid_items[i]
    end
    for i = #valid_items, math.max(#valid_items - take_count + 1, 1), -1 do
        summary.newest_valid_entries[#summary.newest_valid_entries + 1] = valid_items[i]
    end

    return summary
end

local function get_realmrank_fallback_entry(name_key, now_seconds)
    if not name_key then
        return nil
    end
    local cache = ensure_realmrank_fallback_cache()
    local entry = cache[name_key]
    if type(entry) ~= "table" then
        return nil
    end

    local suspend_cleanup_for_combat =
        type(AutoBand.should_suspend_realmrank_refresh_for_combat) == "function" and
        AutoBand.should_suspend_realmrank_refresh_for_combat() == true
    local function invalidate_and_drop()
        if not suspend_cleanup_for_combat then
            cache[name_key] = nil
        end
        return nil
    end

    local rr_number = tonumber(entry.rr)
    if rr_number == nil then
        rr_number = tonumber(entry.realmrank)
    end
    if rr_number == nil then
        return invalidate_and_drop()
    end
    rr_number = math.floor(rr_number)
    if rr_number < 0 then
        return invalidate_and_drop()
    end

    local last_seen_epoch_s = parse_first_integer(entry.last_seen_epoch_s)
    if last_seen_epoch_s ~= nil and last_seen_epoch_s <= 0 then
        return invalidate_and_drop()
    end
    if now_seconds ~= nil and last_seen_epoch_s ~= nil and
       (now_seconds - last_seen_epoch_s) > REALMRANK_FALLBACK_MAX_AGE_SECONDS then
        return invalidate_and_drop()
    end

    return {
        rr = rr_number,
        display_name = trim_string(entry.name),
        last_seen_epoch_s = last_seen_epoch_s,
        character_id = normalize_realmrank_character_id(entry.char_id),
        level = parse_first_integer(entry.level),
        career_line = normalize_realmrank_career_line(entry.career_line),
        career_name = trim_string(entry.career_name),
        career_icon = trim_string(entry.career_icon),
        faction = normalize_realmrank_faction(entry.faction),
        role = normalize_realmrank_role(entry.role)
    }
end

local function upsert_realmrank_fallback_entry(name_key, display_name, rr, now_seconds, metadata)
    if not name_key then
        return
    end
    local rr_number = tonumber(rr)
    if rr_number == nil then
        return
    end
    rr_number = math.floor(rr_number)
    if rr_number < 0 then
        return
    end

    local cache = ensure_realmrank_fallback_cache()
    local entry = cache[name_key]
    if type(entry) ~= "table" then
        entry = {}
        cache[name_key] = entry
    end
    entry.rr = rr_number

    local cleaned_name = trim_string(display_name)
    if cleaned_name then
        entry.name = cleaned_name
    elseif type(entry.name) ~= "string" or entry.name == "" then
        entry.name = name_key
    end

    metadata = type(metadata) == "table" and metadata or {}

    local normalized_character_id = normalize_realmrank_character_id(metadata.character_id)
    if normalized_character_id ~= nil then
        entry.char_id = normalized_character_id
    end

    local normalized_level = parse_first_integer(metadata.level)
    if normalized_level ~= nil and normalized_level >= 0 then
        entry.level = normalized_level
    end

    local normalized_career_line = normalize_realmrank_career_line(metadata.career_line)
    if normalized_career_line ~= nil then
        entry.career_line = normalized_career_line
    end

    local normalized_career_name = trim_string(metadata.career_name)
    if normalized_career_name ~= nil then
        entry.career_name = normalized_career_name
    end

    local normalized_career_icon = trim_string(metadata.career_icon)
    if normalized_career_icon ~= nil then
        entry.career_icon = normalized_career_icon
    end

    local normalized_faction = normalize_realmrank_faction(metadata.faction)
    if normalized_faction ~= nil then
        entry.faction = normalized_faction
    end

    local normalized_role = normalize_realmrank_role(metadata.role)
    if normalized_role ~= nil then
        entry.role = normalized_role
    end

    if now_seconds ~= nil then
        entry.last_seen_epoch_s = now_seconds
    elseif entry.last_seen_epoch_s == nil then
        local generated_epoch_s = get_realmrank_generated_epoch_seconds()
        if generated_epoch_s and generated_epoch_s > 0 then
            entry.last_seen_epoch_s = generated_epoch_s
        end
    end
end

local function get_realmrank_lookup_result(name_raw, opts)
    opts = opts or {}
    local allow_cache_fallback = opts.allow_cache_fallback ~= false
    local touch_cache = opts.touch_cache == true

    local name_key, normalized_display = normalize_wb_player_name(name_raw)
    if not name_key then
        return nil
    end

    local now_seconds = opts.now_seconds
    if now_seconds == nil and (allow_cache_fallback or touch_cache) then
        now_seconds = AutoBand.get_realmrank_cache_now_seconds()
    end
    if (allow_cache_fallback or touch_cache) and not opts.skip_cleanup then
        AutoBand.cleanup_realmrank_fallback_cache(false, now_seconds)
    end

    local csv_is_stale = false
    if AutoBand.is_realmrank_data_stale then
        csv_is_stale = AutoBand.is_realmrank_data_stale() == true
    end
    if not csv_is_stale and type(AutoBand.realmrank_lookup) == "table" then
        local rr_number = tonumber(AutoBand.realmrank_lookup[name_key])
        if rr_number ~= nil then
            rr_number = math.floor(rr_number)
            if rr_number >= 0 then
                local csv_name = nil
                if type(AutoBand.realmrank_name_lookup) == "table" then
                    csv_name = trim_string(AutoBand.realmrank_name_lookup[name_key])
                end
                local csv_character_id = nil
                if type(AutoBand.realmrank_charid_lookup) == "table" then
                    csv_character_id = normalize_realmrank_character_id(AutoBand.realmrank_charid_lookup[name_key])
                end
                local csv_level = nil
                if type(AutoBand.realmrank_level_lookup) == "table" then
                    csv_level = parse_first_integer(AutoBand.realmrank_level_lookup[name_key])
                    if csv_level ~= nil and csv_level < 0 then
                        csv_level = nil
                    end
                end
                local csv_career_line = nil
                if type(AutoBand.realmrank_careerline_lookup) == "table" then
                    csv_career_line = normalize_realmrank_career_line(AutoBand.realmrank_careerline_lookup[name_key])
                end
                local csv_career_name = nil
                if type(AutoBand.realmrank_careername_lookup) == "table" then
                    csv_career_name = trim_string(AutoBand.realmrank_careername_lookup[name_key])
                end
                local csv_career_icon = nil
                if type(AutoBand.realmrank_careericon_lookup) == "table" then
                    csv_career_icon = trim_string(AutoBand.realmrank_careericon_lookup[name_key])
                end
                local csv_faction = nil
                if type(AutoBand.realmrank_faction_lookup) == "table" then
                    csv_faction = normalize_realmrank_faction(AutoBand.realmrank_faction_lookup[name_key])
                end
                local csv_role = nil
                if type(AutoBand.realmrank_role_lookup) == "table" then
                    csv_role = normalize_realmrank_role(AutoBand.realmrank_role_lookup[name_key])
                end
                local display_name = csv_name or normalized_display or name_key
                if touch_cache then
                    upsert_realmrank_fallback_entry(name_key, display_name, rr_number, now_seconds, {
                        character_id = csv_character_id,
                        level = csv_level,
                        career_line = csv_career_line,
                        career_name = csv_career_name,
                        career_icon = csv_career_icon,
                        faction = csv_faction,
                        role = csv_role
                    })
                end
                return {
                    rr = rr_number,
                    display_name = display_name,
                    source = "csv",
                    character_id = csv_character_id,
                    level = csv_level,
                    career_line = csv_career_line,
                    career_name = csv_career_name,
                    career_icon = csv_career_icon,
                    faction = csv_faction,
                    role = csv_role,
                    generated_epoch_ms = parse_first_integer(AutoBand.realmrank_generated_epoch_ms),
                    generated_utc = AutoBand.realmrank_generated_utc
                }
            end
        end
    end

    if allow_cache_fallback then
        local cached = get_realmrank_fallback_entry(name_key, now_seconds)
        if cached then
            local display_name = cached.display_name or normalized_display or name_key
            if touch_cache then
                upsert_realmrank_fallback_entry(name_key, display_name, cached.rr, now_seconds, {
                    character_id = cached.character_id,
                    level = cached.level,
                    career_line = cached.career_line,
                    career_name = cached.career_name,
                    career_icon = cached.career_icon,
                    faction = cached.faction,
                    role = cached.role
                })
            end
            local cache_seen_utc = nil
            if cached.last_seen_epoch_s ~= nil and cached.last_seen_epoch_s > 0 then
                cache_seen_utc = format_epoch_seconds_utc(cached.last_seen_epoch_s)
            end
            return {
                rr = cached.rr,
                display_name = display_name,
                source = "cache",
                character_id = cached.character_id,
                level = cached.level,
                career_line = cached.career_line,
                career_name = cached.career_name,
                career_icon = cached.career_icon,
                faction = cached.faction,
                role = cached.role,
                cache_seen_epoch_s = cached.last_seen_epoch_s,
                cache_seen_utc = cache_seen_utc
            }
        end
    end

    return nil
end

function AutoBand.get_realm_rank_lookup_result(name_raw, opts)
    return get_realmrank_lookup_result(name_raw, opts)
end

function AutoBand.get_realm_rank_for_name(name_raw)
    local result = get_realmrank_lookup_result(name_raw, { allow_cache_fallback = true })
    if result and result.source == "csv" then
        local touched = get_realmrank_lookup_result(name_raw, {
            allow_cache_fallback = false,
            touch_cache = true,
            skip_cleanup = true
        })
        if touched then
            result = touched
        end
    end
    if result then
        return result.rr
    end
    return nil
end

function AutoBand.get_effective_realm_rank_for_player(player)
    if type(player) ~= "table" or player.name == nil then
        return nil
    end
    if type(AutoBand.get_realm_rank_for_name) ~= "function" then
        return nil
    end

    local ok_rr, rr_value = pcall(AutoBand.get_realm_rank_for_name, player.name)
    if not ok_rr or rr_value == nil then
        return nil
    end

    local rr_number = tonumber(rr_value)
    if rr_number == nil then
        return nil
    end
    rr_number = math.floor(rr_number)
    if rr_number < 0 then
        return nil
    end

    local career_rank = tonumber(player.level)
    if career_rank ~= nil then
        career_rank = math.floor(career_rank)
        if career_rank > 0 and career_rank < 40 and rr_number > career_rank then
            rr_number = career_rank
        end
    end

    return rr_number
end

function AutoBand.realmrank_seed_wb_snapshot()
    if type(AutoBand.refresh_realmrank_cache) == "function" then
        if is_realmrank_csv_auto_refresh_suppressed() then
            return
        end
        pcall(AutoBand.refresh_realmrank_cache, true)
    end
end

function AutoBand.realmrank_create_wb_average_state()
    return {
        rr_total = 0,
        rr_count = 0,
        rr_missing = 0
    }
end

function AutoBand.realmrank_accumulate_wb_average(state, player)
    if type(state) ~= "table" then
        return
    end

    local effective_rr = AutoBand.get_effective_realm_rank_for_player(player)
    if effective_rr ~= nil then
        state.rr_total = (tonumber(state.rr_total) or 0) + effective_rr
        state.rr_count = (tonumber(state.rr_count) or 0) + 1
    else
        state.rr_missing = (tonumber(state.rr_missing) or 0) + 1
    end
end

function AutoBand.realmrank_get_wb_average(state)
    if type(state) ~= "table" then
        return nil
    end
    local rr_count = tonumber(state.rr_count) or 0
    local rr_missing = tonumber(state.rr_missing) or 0
    if rr_count <= 0 or rr_missing > 0 then
        return nil
    end
    local rr_total = tonumber(state.rr_total) or 0
    return rr_total / rr_count
end

function AutoBand.get_realmrank_display_name_for_name(name_raw)
    local result = get_realmrank_lookup_result(name_raw, { allow_cache_fallback = true })
    if result and result.display_name and result.display_name ~= "" then
        return result.display_name
    end
    return nil
end

function AutoBand.get_realmrank_character_id_for_name(name_raw)
    local result = get_realmrank_lookup_result(name_raw, { allow_cache_fallback = true })
    if result and result.character_id ~= nil then
        return normalize_realmrank_character_id(result.character_id)
    end
    return nil
end

function AutoBand.checkpoint_realmrank_cache_for_wb(wbdata)
    if type(wbdata) ~= "table" then
        return
    end
    if not AutoBand.saved or AutoBand.saved.realmrank_lookup_enabled ~= true then
        AutoBand.cleanup_realmrank_fallback_cache(false)
        return
    end

    local now_seconds = AutoBand.get_realmrank_cache_now_seconds()
    AutoBand.cleanup_realmrank_fallback_cache(false, now_seconds)

    for _, grp in ipairs(wbdata) do
        if grp and type(grp.players) == "table" then
            for _, player in ipairs(grp.players) do
                if player and player.name then
                    get_realmrank_lookup_result(player.name, {
                        allow_cache_fallback = true,
                        touch_cache = true,
                        now_seconds = now_seconds,
                        skip_cleanup = true
                    })
                end
            end
        end
    end
end

local function online_killboard_link_data_for_character_id(character_id)
    if type(AutoBand.build_killboard_link_data_for_character_id) ~= "function" then
        return nil
    end
    local link_data = AutoBand.build_killboard_link_data_for_character_id(character_id)
    if type(link_data) ~= "string" or link_data == "" then
        return nil
    end
    return link_data
end

local function realmrank_icon_for_detail(detail)
    return trim_string(detail and detail.career_icon)
end

local function realmrank_name_for_detail(detail)
    return trim_string(detail and detail.career_name)
end

local function online_color_text(text, rgb, fallback_rgb, link_data)
    local color = rgb or fallback_rgb or AB_const.COLOR_WHITE
    local r = tonumber(color[1] or color.r) or 255
    local g = tonumber(color[2] or color.g) or 255
    local b = tonumber(color[3] or color.b) or 255
    if r < 0 then r = 0 elseif r > 255 then r = 255 end
    if g < 0 then g = 0 elseif g > 255 then g = 255 end
    if b < 0 then b = 0 elseif b > 255 then b = 255 end
    text = tostring(text or "")
    text = string.gsub(text, "\"", "'")
    local data = "0"
    if link_data ~= nil then
        data = tostring(link_data)
        data = string.gsub(data, "\"", "'")
        if data == "" then
            data = "0"
        end
    end
    return string.format("<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">", data, r, g, b, text)
end

local function online_enemy_to_string(value)
    if value == nil then
        return nil
    end
    if type(value) ~= "string" and type(WStringToString) == "function" then
        local ok_ws, converted = pcall(WStringToString, value)
        if ok_ws and type(converted) == "string" then
            value = converted
        end
    end
    local ok_str, as_string = pcall(tostring, value)
    if not ok_str or as_string == nil then
        return nil
    end
    return as_string
end

local function normalize_online_group_key(value)
    local s = online_enemy_to_string(value)
    if not s or s == "" then
        return nil
    end
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    s = string.gsub(s, "%p+$", "")
    if s == "" then
        return nil
    end
    local ok_lower, lowered = pcall(string.lower, s)
    if not ok_lower or not lowered or lowered == "" then
        return nil
    end
    return lowered
end

local function normalize_enemy_killspam_count(raw)
    local n = tonumber(raw) or 0
    n = math.floor(n)
    if n < 0 then
        return 0
    end
    return n
end

local function get_enemy_killspam_player_stats()
    if type(Enemy) ~= "table" then
        return nil
    end
    local killspam = Enemy.killSpam
    if type(killspam) ~= "table" then
        return nil
    end

    local settings = type(killspam.settings) == "table" and killspam.settings or nil
    local enabled = false
    if settings and settings.killSpamEnabled ~= nil then
        enabled = settings.killSpamEnabled == true
    elseif type(Enemy.Settings) == "table" then
        enabled = Enemy.Settings.killSpamEnabled == true
    end
    if not enabled then
        return nil
    end
    if killspam.isPluginEnabled ~= true then
        return nil
    end
    if type(killspam.playerStats) ~= "table" then
        return nil
    end
    return killspam.playerStats
end

local function normalize_enemy_killspam_name(value)
    local text = online_enemy_to_string(value)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

local function get_enemy_killspam_entry(player_stats, value)
    if type(player_stats) ~= "table" or value == nil then
        return nil
    end

    local entry = player_stats[value]
    if type(entry) == "table" then
        return entry
    end

    local name = normalize_enemy_killspam_name(value)
    if not name then
        return nil
    end

    entry = player_stats[name]
    if type(entry) == "table" then
        return entry
    end

    if type(towstring) == "function" then
        local ok, wide_name = pcall(towstring, name)
        if ok and wide_name ~= nil then
            entry = player_stats[wide_name]
            if type(entry) == "table" then
                return entry
            end
        end
    end

    return nil
end

local function get_enemy_killspam_entry_for_names(player_stats, ...)
    if type(player_stats) ~= "table" then
        return nil
    end

    for i = 1, select("#", ...) do
        local entry = get_enemy_killspam_entry(player_stats, select(i, ...))
        if type(entry) == "table" then
            return entry
        end
    end

    return nil
end

local function format_enemy_killspam_stats(stats)
    if type(stats) ~= "table" then
        return nil
    end
    local kills = normalize_enemy_killspam_count(stats.kills)
    local deaths = normalize_enemy_killspam_count(stats.deaths)
    if kills <= 0 and deaths <= 0 then
        return nil
    end
    return "(" .. tostring(kills) .. "k/" .. tostring(deaths) .. "d)"
end

local function normalize_online_group_color(color)
    if type(color) ~= "table" then
        return nil
    end
    local r = tonumber(color[1] or color.r)
    local g = tonumber(color[2] or color.g)
    local b = tonumber(color[3] or color.b)
    if not r or not g or not b then
        return nil
    end
    r = math.floor(r)
    g = math.floor(g)
    b = math.floor(b)
    if r < 0 then r = 0 elseif r > 255 then r = 255 end
    if g < 0 then g = 0 elseif g > 255 then g = 255 end
    if b < 0 then b = 0 elseif b > 255 then b = 255 end
    return { r, g, b }
end

function AutoBand.realmrank_init_saved_state()
    if type(AutoBand.saved) ~= "table" then
        AutoBand.saved = {}
    end

    if AutoBand.saved.realmrank_lookup_enabled == nil then
        AutoBand.saved.realmrank_lookup_enabled = true
    end

    if AutoBand.saved.realmrank_csv_path ~= nil and type(AutoBand.saved.realmrank_csv_path) ~= "string" then
        AutoBand.saved.realmrank_csv_path = nil
    end
    if AutoBand.saved.online_markgroup_default_key ~= nil and type(AutoBand.saved.online_markgroup_default_key) ~= "string" then
        AutoBand.saved.online_markgroup_default_key = nil
    end
    if AutoBand.saved.online_markgroup_default_name ~= nil and type(AutoBand.saved.online_markgroup_default_name) ~= "string" then
        AutoBand.saved.online_markgroup_default_name = nil
    end

    if type(AutoBand.saved.online_markgroup_default_key) == "string" then
        local cleaned_default_key = normalize_online_group_key(AutoBand.saved.online_markgroup_default_key)
        if cleaned_default_key then
            AutoBand.saved.online_markgroup_default_key = cleaned_default_key
        else
            AutoBand.saved.online_markgroup_default_key = nil
        end
    end
    if type(AutoBand.saved.online_markgroup_default_name) == "string" then
        local cleaned_default_name = online_enemy_to_string(AutoBand.saved.online_markgroup_default_name)
        if cleaned_default_name then
            cleaned_default_name = string.gsub(cleaned_default_name, "^%s+", "")
            cleaned_default_name = string.gsub(cleaned_default_name, "%s+$", "")
        end
        if cleaned_default_name == nil or cleaned_default_name == "" then
            AutoBand.saved.online_markgroup_default_name = nil
        else
            AutoBand.saved.online_markgroup_default_name = cleaned_default_name
        end
    end
    if AutoBand.saved.online_markgroup_default_key == nil then
        AutoBand.saved.online_markgroup_default_name = nil
    end

    if type(AutoBand.saved.online_monitor_groups) ~= "table" then
        AutoBand.saved.online_monitor_groups = {}
    end

    local cleaned_saved_groups = {}
    for raw_key, raw_entry in pairs(AutoBand.saved.online_monitor_groups) do
        local key = normalize_online_group_key(raw_key)
        if key then
            local clean_entry = {}
            if type(raw_entry) == "table" then
                local name_text = online_enemy_to_string(raw_entry.name_s or raw_entry.name)
                if name_text then
                    name_text = string.gsub(name_text, "^%s+", "")
                    name_text = string.gsub(name_text, "%s+$", "")
                    if name_text ~= "" then
                        clean_entry.name_s = name_text
                    end
                end
                local color = normalize_online_group_color(raw_entry.color)
                if color then
                    clean_entry.color = color
                end
            end
            cleaned_saved_groups[key] = clean_entry
        end
    end
    AutoBand.saved.online_monitor_groups = cleaned_saved_groups

    if type(AutoBand.online_monitor_groups) ~= "table" then
        AutoBand.online_monitor_groups = {}
    else
        for key, _ in pairs(AutoBand.online_monitor_groups) do
            AutoBand.online_monitor_groups[key] = nil
        end
    end
    if type(AutoBand.online_monitor_state) ~= "table" then
        AutoBand.online_monitor_state = {}
    else
        for key, _ in pairs(AutoBand.online_monitor_state) do
            AutoBand.online_monitor_state[key] = nil
        end
    end
    for key, entry in pairs(cleaned_saved_groups) do
        AutoBand.online_monitor_groups[key] = {
            name_s = entry.name_s or key,
            color = entry.color or AB_const.COLOR_SKY
        }
    end
    AutoBand.online_monitor_startup_pending = false
    AutoBand.online_monitor_startup_announced = false
    AutoBand.online_monitor_startup_delay_elapsed = 0

    if type(AutoBand.saved.realmrank_fallback_cache) ~= "table" then
        AutoBand.saved.realmrank_fallback_cache = {}
    end
    if type(AutoBand.saved.realmrank_fallback_last_cleanup_epoch_s) ~= "number" then
        AutoBand.saved.realmrank_fallback_last_cleanup_epoch_s = 0
    end
    if type(AutoBand.saved.realmrank_time_anchor_epoch_s) ~= "number" then
        AutoBand.saved.realmrank_time_anchor_epoch_s = nil
    elseif AutoBand.saved.realmrank_time_anchor_epoch_s <= 0 then
        AutoBand.saved.realmrank_time_anchor_epoch_s = nil
    end
    if type(AutoBand.saved.realmrank_time_anchor_game_s) ~= "number" then
        AutoBand.saved.realmrank_time_anchor_game_s = nil
    elseif AutoBand.saved.realmrank_time_anchor_game_s <= 0 then
        AutoBand.saved.realmrank_time_anchor_game_s = nil
    end

    if type(AutoBand.saved.realmrank_refresh_seconds) ~= "number" then
        AutoBand.saved.realmrank_refresh_seconds = REALMRANK_REFRESH_DEFAULT_SECONDS
    end
    if AutoBand.saved.realmrank_refresh_seconds < REALMRANK_REFRESH_MIN_SECONDS then
        AutoBand.saved.realmrank_refresh_seconds = REALMRANK_REFRESH_MIN_SECONDS
    elseif AutoBand.saved.realmrank_refresh_seconds > REALMRANK_REFRESH_MAX_SECONDS then
        AutoBand.saved.realmrank_refresh_seconds = REALMRANK_REFRESH_MAX_SECONDS
    end
end

local function has_online_enemy_templates()
    if type(Enemy) ~= "table" then
        return false
    end
    if Enemy.marks and type(Enemy.marks.templates) == "table" then
        return true
    end
    if Enemy.Settings and type(Enemy.Settings.markTemplates) == "table" then
        return true
    end
    return false
end
AutoBand.has_online_enemy_templates = has_online_enemy_templates

local function ensure_online_monitor_runtime()
    if type(AutoBand.online_monitor_groups) ~= "table" then
        AutoBand.online_monitor_groups = {}
    end
    if type(AutoBand.online_monitor_state) ~= "table" then
        AutoBand.online_monitor_state = {}
    end
    if type(AutoBand.online_monitor_elapsed) ~= "number" then
        AutoBand.online_monitor_elapsed = 0
    end
    if type(AutoBand.online_monitor_startup_pending) ~= "boolean" then
        AutoBand.online_monitor_startup_pending = false
    end
    if type(AutoBand.online_monitor_startup_announced) ~= "boolean" then
        AutoBand.online_monitor_startup_announced = false
    end
    if type(AutoBand.online_monitor_startup_delay_elapsed) ~= "number" then
        AutoBand.online_monitor_startup_delay_elapsed = 0
    end
end
AutoBand.ensure_online_monitor_runtime = ensure_online_monitor_runtime

local function get_online_monitor_count()
    ensure_online_monitor_runtime()
    local count = 0
    for key, _ in pairs(AutoBand.online_monitor_groups) do
        if type(key) == "string" and key ~= "" then
            count = count + 1
        end
    end
    return count
end
AutoBand.get_online_monitor_count = get_online_monitor_count

local function get_online_enemy_mark_groups(wanted_groups)
    if not has_online_enemy_templates() then
        return nil
    end

    local templates = nil
    if Enemy.marks and type(Enemy.marks.templates) == "table" then
        templates = Enemy.marks.templates
    elseif Enemy.Settings and type(Enemy.Settings.markTemplates) == "table" then
        templates = Enemy.Settings.markTemplates
    end
    if type(templates) ~= "table" then
        return nil
    end

    local groups = {}
    local sort_keys = {}
    for _, template in ipairs(templates) do
        local group_name_s = online_enemy_to_string(template and template.name or nil)
        if group_name_s and group_name_s ~= "" then
            local sort_key = normalize_online_group_key(group_name_s)
            local key = sort_key or string.lower(group_name_s)
            local members = {}
            local member_count = 0

            if wanted_groups == nil or wanted_groups[key] ~= nil then
                local function add_member(member_name)
                    local member_key = normalize_online_group_key(member_name)
                    if member_key and not members[member_key] then
                        local member_name_s = online_enemy_to_string(member_name) or member_key
                        members[member_key] = member_name_s
                        member_count = member_count + 1
                    end
                end

                if template and type(template.permanentTargets) == "table" then
                    for member_name, _ in pairs(template.permanentTargets) do
                        add_member(member_name)
                    end
                end

                if member_count == 0 and template and type(template._activeMarks) == "table" then
                    for _, mark in ipairs(template._activeMarks) do
                        if mark and mark.isPlayer and mark.objectName then
                            add_member(mark.objectName)
                        end
                    end
                end

            end

            local group = {
                key = key,
                name_s = group_name_s,
                members = members,
                member_count = member_count,
                color = normalize_online_group_color(template and template.color),
            }
            sort_keys[group] = sort_key or ""
            groups[#groups + 1] = group
        end
    end

    table.sort(groups, function(a, b)
        local a_name = sort_keys[a]
        local b_name = sort_keys[b]
        return a_name < b_name
    end)

    return groups
end

-- Read-only choices for the Realm page: Enemy markgroups plus saved monitored and
-- default groups that Enemy no longer lists (available = false). Monitored groups
-- come first; each section is sorted by name.
-- Metadata only: the empty wanted-group table skips every member traversal
-- (permanentTargets/_activeMarks). Never edits the monitor table or saved settings.
function AutoBand.get_online_markgroup_choices()
    ensure_online_monitor_runtime()
    local by_key = {}
    local out = {}
    local function add(key, name_s, available)
        if type(key) ~= "string" or key == "" then
            return
        end
        local entry = by_key[key]
        if entry then
            entry.available = entry.available or available
            return
        end
        entry = { key = key, name_s = name_s or key, available = available == true }
        by_key[key] = entry
        out[#out + 1] = entry
    end
    local groups = get_online_enemy_mark_groups({})
    if type(groups) == "table" then
        for _, group in ipairs(groups) do
            add(group.key, group.name_s, true)
        end
    end
    for key, entry in pairs(AutoBand.online_monitor_groups) do
        local normalized = normalize_online_group_key(key)
        add(normalized, type(entry) == "table" and online_enemy_to_string(entry.name_s or entry.name) or normalized, false)
    end
    local saved = AutoBand.saved or {}
    local default_key = type(saved.online_markgroup_default_key) == "string" and normalize_online_group_key(saved.online_markgroup_default_key) or nil
    if default_key then
        add(default_key, saved.online_markgroup_default_name or default_key, false)
    end
    for _, entry in ipairs(out) do
        entry.monitored = AutoBand.online_monitor_groups[entry.key] ~= nil
        entry.is_default = default_key ~= nil and entry.key == default_key
        entry.sort_key = normalize_online_group_key(entry.name_s) or entry.key
    end
    table.sort(out, function(a, b)
        if a.monitored ~= b.monitored then
            return a.monitored
        end
        if a.sort_key ~= b.sort_key then
            return a.sort_key < b.sort_key
        end
        return a.key < b.key
    end)
    return out, type(groups) == "table"
end

-- Use realm-rank CSV (saved in presets, as before). Turning it on is a recovery
-- action and is never gated; it loads nothing by itself (Refresh now does).
function AutoBand.set_realmrank_lookup_enabled(new_state, opts)
    opts = type(opts) == "table" and opts or {}
    if type(new_state) ~= "boolean" then
        return false
    end
    AutoBand.saved = AutoBand.saved or {}
    local changed = AutoBand.saved.realmrank_lookup_enabled ~= new_state
    AutoBand.saved.realmrank_lookup_enabled = new_state
    if changed and type(AutoBand.mark_template_settings_modified) == "function" then
        AutoBand.mark_template_settings_modified()
    end
    if not opts.silent then
        AB_util.print("Use realm-rank CSV: " .. tostring(new_state) ..
            (new_state and " (Refresh now or /ab csvrefresh loads it right away)." or "."))
    end
    if changed and not opts.skip_gui_refresh and type(AutoBand.refresh_settings_ui) == "function" then
        AutoBand.refresh_settings_ui()
    end
    return changed
end

-- Validated setter for the RR CSV refresh interval (seconds, 60-1800). Rejects
-- out-of-range or non-numeric input instead of clamping it.
function AutoBand.set_realmrank_refresh_seconds(value, opts)
    opts = opts or {}
    local n = tonumber(value)
    if n == nil or n ~= n or n ~= math.floor(n) or n < REALMRANK_REFRESH_MIN_SECONDS or n > REALMRANK_REFRESH_MAX_SECONDS then
        if not opts.silent then
            AB_util.print("[Error] Refresh interval must be a whole number of seconds from " ..
                REALMRANK_REFRESH_MIN_SECONDS .. " to " .. REALMRANK_REFRESH_MAX_SECONDS .. ".")
        end
        return false
    end
    AutoBand.saved = AutoBand.saved or {}
    local changed = AutoBand.saved.realmrank_refresh_seconds ~= n
    AutoBand.saved.realmrank_refresh_seconds = n
    if changed and not opts.silent then
        AB_util.print("Realm-rank CSV refresh interval: " .. n .. " seconds.")
    end
    return true, changed
end

local function find_online_enemy_group_by_key(groups, key)
    if type(groups) ~= "table" or not key then
        return nil
    end
    for _, group in ipairs(groups) do
        if group and group.key == key then
            return group
        end
    end
    return nil
end

local function print_online_enemy_group_list(groups)
    if type(groups) ~= "table" or #groups == 0 then
        AB_util.print("No Enemy markgroups found.")
        return
    end

    local default_key = nil
    if AutoBand.saved and type(AutoBand.saved.online_markgroup_default_key) == "string" then
        default_key = normalize_online_group_key(AutoBand.saved.online_markgroup_default_key)
    end

    AB_util.print("Enemy markgroups:")
    for _, group in ipairs(groups) do
        if group and group.name_s then
            local color = group.color or AB_const.COLOR_SKY
            local label = online_color_text(group.name_s, color, AB_const.COLOR_SKY)
            local suffix = " (" .. tostring(group.member_count or 0) .. " members)"
            if default_key and group.key == default_key then
                suffix = suffix .. " [default]"
            end
            AB_util.print("  " .. label .. suffix)
        end
    end
end

local function clear_online_default_group()
    if not AutoBand.saved then
        AutoBand.saved = {}
    end
    AutoBand.saved.online_markgroup_default_key = nil
    AutoBand.saved.online_markgroup_default_name = nil
end

local function normalize_online_member_sort_key(name_raw)
    local name_key = normalize_online_group_key(name_raw)
    if name_key and name_key ~= "" then
        return name_key
    end
    local name_string = online_enemy_to_string(name_raw) or ""
    local ok_lower, lowered = pcall(string.lower, name_string)
    if ok_lower and lowered then
        return lowered
    end
    return name_string
end

local function sync_online_monitors_saved()
    ensure_online_monitor_runtime()
    if type(AutoBand.saved) ~= "table" then
        AutoBand.saved = {}
    end

    local saved_groups = {}
    for key, entry in pairs(AutoBand.online_monitor_groups) do
        local normalized_key = normalize_online_group_key(key)
        if normalized_key then
            local saved_entry = {}
            local name_s = nil

            if type(entry) == "table" then
                name_s = online_enemy_to_string(entry.name_s or entry.name)
                if name_s then
                    name_s = string.gsub(name_s, "^%s+", "")
                    name_s = string.gsub(name_s, "%s+$", "")
                    if name_s == "" then
                        name_s = nil
                    end
                end

                local color = normalize_online_group_color(entry.color)
                if color then
                    saved_entry.color = color
                end
            end

            if name_s then
                saved_entry.name_s = name_s
            end
            saved_groups[normalized_key] = saved_entry
        end
    end

    AutoBand.saved.online_monitor_groups = saved_groups
end

local function clear_online_monitors()
    ensure_online_monitor_runtime()
    local count = 0
    for key, _ in pairs(AutoBand.online_monitor_groups) do
        AutoBand.online_monitor_groups[key] = nil
        count = count + 1
    end
    AutoBand.online_monitor_state = {}
    AutoBand.online_monitor_elapsed = 0
    AutoBand.online_monitor_startup_pending = false
    AutoBand.online_monitor_startup_announced = false
    AutoBand.online_monitor_startup_delay_elapsed = 0
    sync_online_monitors_saved()
    return count
end

-- Gate for adding a monitored markgroup, setting the default group and Check now:
-- Enemy markgroups plus usable fresh CSV. Read-only (see peek_realmrank_availability).
function AutoBand.peek_online_markgroup_availability()
    if not has_online_enemy_templates() then
        return false, "enemy_missing", "Enemy addon not loaded."
    end
    return AutoBand.peek_realmrank_availability()
end

-- Group name/key/colour only; the empty wanted-group table skips member traversal.
local function find_online_markgroup_metadata(key)
    return find_online_enemy_group_by_key(get_online_enemy_mark_groups({}), key)
end

-- Settings UI: add (enabled = true) or remove one monitored markgroup by key.
-- Removing never needs Enemy or the CSV, so saved monitors for groups that no
-- longer exist stay removable. Adding is gated before any lookup or change.
function AutoBand.set_online_monitor_group(key, enabled, opts)
    opts = type(opts) == "table" and opts or {}
    ensure_online_monitor_runtime()
    local normalized = normalize_online_group_key(key)
    if not normalized then
        return false, "invalid"
    end
    if enabled ~= true then
        local entry = AutoBand.online_monitor_groups[normalized]
        if entry == nil then
            return false, "not_monitored"
        end
        AutoBand.online_monitor_groups[normalized] = nil
        AutoBand.online_monitor_state[normalized] = nil
        if next(AutoBand.online_monitor_groups) == nil then
            AutoBand.online_monitor_startup_pending = false
            AutoBand.online_monitor_startup_announced = false
            AutoBand.online_monitor_startup_delay_elapsed = 0
        end
        sync_online_monitors_saved()
        if not opts.silent then
            local name_s = type(entry) == "table" and online_enemy_to_string(entry.name_s or entry.name) or nil
            AB_util.print("Online monitor removed: " .. tostring(name_s or normalized))
        end
        return true, "removed"
    end
    local available, status, reason = AutoBand.peek_online_markgroup_availability()
    if not available then
        if not opts.silent then
            AB_util.print("[Error] Online monitor not added: " .. tostring(reason))
        end
        return false, status
    end
    local group = find_online_markgroup_metadata(normalized)
    if not group then
        if not opts.silent then
            AB_util.print("[Error] Enemy markgroup not found: " .. tostring(key))
        end
        return false, "not_found"
    end
    local already = AutoBand.online_monitor_groups[group.key] ~= nil
    AutoBand.online_monitor_groups[group.key] = { name_s = group.name_s, color = group.color }
    if not already then
        AutoBand.online_monitor_state[group.key] = nil
    end
    sync_online_monitors_saved()
    if not opts.silent then
        AB_util.print("Online monitor added: " .. online_color_text(group.name_s, group.color, AB_const.COLOR_SKY) ..
            " (every " .. tostring(ONLINE_MONITOR_INTERVAL_SECONDS) .. "s).")
    end
    return true, already and "updated" or "added"
end

-- Settings UI: set (key) or clear (nil) the default markgroup for /ab online.
-- Clearing always works; setting is gated like adding a monitor.
function AutoBand.set_online_default_group(key, opts)
    opts = type(opts) == "table" and opts or {}
    if key == nil then
        clear_online_default_group()
        if not opts.silent then
            AB_util.print("Online default markgroup cleared.")
        end
        return true, "cleared"
    end
    local normalized = normalize_online_group_key(key)
    if not normalized then
        return false, "invalid"
    end
    local available, status, reason = AutoBand.peek_online_markgroup_availability()
    if not available then
        if not opts.silent then
            AB_util.print("[Error] Online default markgroup not set: " .. tostring(reason))
        end
        return false, status
    end
    local group = find_online_markgroup_metadata(normalized)
    if not group then
        if not opts.silent then
            AB_util.print("[Error] Enemy markgroup not found: " .. tostring(key))
        end
        return false, "not_found"
    end
    AutoBand.saved = AutoBand.saved or {}
    AutoBand.saved.online_markgroup_default_key = group.key
    AutoBand.saved.online_markgroup_default_name = group.name_s
    if not opts.silent then
        AB_util.print("Online default markgroup set to " .. online_color_text(group.name_s, group.color, AB_const.COLOR_SKY) .. ".")
    end
    return true, "set"
end

local sort_online_matches = nil

local function collect_online_group_matches(
    group,
    online_lookup,
    display_lookup,
    level_lookup,
    careerline_lookup,
    charid_lookup,
    careername_lookup,
    careericon_lookup,
    faction_lookup,
    role_lookup,
    options
)
    local matches = {}
    if type(group) ~= "table" or type(group.members) ~= "table" then
        return matches
    end
    if type(online_lookup) ~= "table" then
        return matches
    end

    display_lookup = type(display_lookup) == "table" and display_lookup or {}
    level_lookup = type(level_lookup) == "table" and level_lookup or {}
    careerline_lookup = type(careerline_lookup) == "table" and careerline_lookup or {}
    charid_lookup = type(charid_lookup) == "table" and charid_lookup or {}
    careername_lookup = type(careername_lookup) == "table" and careername_lookup or {}
    careericon_lookup = type(careericon_lookup) == "table" and careericon_lookup or {}
    faction_lookup = type(faction_lookup) == "table" and faction_lookup or {}
    role_lookup = type(role_lookup) == "table" and role_lookup or {}
    options = type(options) == "table" and options or {}
    local enemy_killspam_player_stats = nil
    if options.include_enemy_killspam == true then
        enemy_killspam_player_stats = get_enemy_killspam_player_stats()
    end

    for member_key, member_name in pairs(group.members) do
        local rr_number = tonumber(online_lookup[member_key])
        if rr_number ~= nil then
            rr_number = math.floor(rr_number)
        end
        if rr_number ~= nil and rr_number >= 0 then
            local display_name = display_lookup[member_key]
            if not display_name or display_name == "" then
                display_name = member_name or member_key
            end
            local level = tonumber(level_lookup[member_key])
            if level ~= nil then
                level = math.floor(level)
                if level < 0 then
                    level = nil
                end
            end
            local career_line = tonumber(careerline_lookup[member_key])
            if career_line ~= nil then
                career_line = math.floor(career_line)
                if career_line <= 0 then
                    career_line = nil
                end
            end
            local character_id = normalize_realmrank_character_id(charid_lookup[member_key])
            local career_name = trim_string(careername_lookup[member_key])
            local career_icon = trim_string(careericon_lookup[member_key])
            local faction = normalize_realmrank_faction(faction_lookup[member_key])
            local role = normalize_realmrank_role(role_lookup[member_key])
            local enemy_killspam_stats = nil
            if enemy_killspam_player_stats then
                enemy_killspam_stats = get_enemy_killspam_entry_for_names(
                    enemy_killspam_player_stats,
                    member_name,
                    display_name,
                    member_key
                )
            end
            matches[#matches + 1] = {
                key = member_key,
                display_name = display_name,
                rr = rr_number,
                level = level,
                career_line = career_line,
                character_id = character_id,
                career_name = career_name,
                career_icon = career_icon,
                faction = faction,
                role = role,
                enemy_killspam_stats = enemy_killspam_stats,
            }
        end
    end

    sort_online_matches(matches)

    return matches
end

sort_online_matches = function(matches)
    if type(matches) ~= "table" then
        return
    end
    table.sort(matches, function(a, b)
        local a_name = normalize_online_member_sort_key(a and a.display_name)
        local b_name = normalize_online_member_sort_key(b and b.display_name)
        if a_name == b_name then
            return tostring(a and a.key or "") < tostring(b and b.key or "")
        end
        return a_name < b_name
    end)
end

local function format_online_match_label(match, group_color)
    local label = (match and (match.display_name or match.key)) or "?"
    local class_prefix = realmrank_icon_for_detail(match)

    local detail_parts = {}
    local career_name = realmrank_name_for_detail(match)
    if (not class_prefix or class_prefix == "") and career_name and career_name ~= "" then
        detail_parts[#detail_parts + 1] = career_name
    end
    if match and match.level ~= nil then
        local cr_text = "CR" .. tostring(match.level)
        if match.rr ~= nil then
            cr_text = cr_text .. ","
        end
        detail_parts[#detail_parts + 1] = cr_text
    end
    if match and match.rr ~= nil then
        detail_parts[#detail_parts + 1] = "RR" .. tostring(match.rr)
    end
    if #detail_parts > 0 then
        label = label .. " (" .. table.concat(detail_parts, " ") .. ")"
    end
    local enemy_killspam_text = format_enemy_killspam_stats(match and match.enemy_killspam_stats)
    if enemy_killspam_text then
        label = label .. " " .. enemy_killspam_text
    end

    local link_data = nil
    if match and match.character_id ~= nil then
        link_data = online_killboard_link_data_for_character_id(match.character_id)
    end
    local colored_label = online_color_text(label, group_color, AB_const.COLOR_SKY, link_data)
    if class_prefix and class_prefix ~= "" then
        colored_label = class_prefix .. " " .. colored_label
    end
    return colored_label
end

local function print_online_snapshot_line()
    local generated_utc = AutoBand.realmrank_generated_utc
    if generated_utc and generated_utc ~= "" then
        local stale_suffix = ""
        if AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
            stale_suffix = " [stale]"
        end
        AB_util.print("Snapshot: " .. generated_utc .. stale_suffix)
        return true
    end
    return false
end

local function get_cache_first_snapshot_state(error_context)
    local snapshot_state = nil
    if type(AutoBand.get_realmrank_snapshot_state) == "function" then
        snapshot_state = AutoBand.get_realmrank_snapshot_state(true, { cache_first = true })
    end
    if type(snapshot_state) ~= "table" or snapshot_state.status ~= "ok" then
        local has_fallback_cache = has_realmrank_fallback_cache_entries()
        if has_fallback_cache then
            local miss_reason = AutoBand.realmrank_snapshot_miss_reason(snapshot_state and snapshot_state.status)
            AB_util.print("[Error] Unable to " .. tostring(error_context or "check snapshot") .. ": " .. miss_reason .. " (" .. REALMRANK_CSV_FILE_NAME .. ").")
        end
        return nil
    end
    return snapshot_state
end

local function print_online_match_chunks(matches, entry_color)
    if type(matches) ~= "table" or #matches == 0 then
        return
    end

    local chunk = {}
    local chunk_size = 3
    for i = 1, #matches do
        chunk[#chunk + 1] = format_online_match_label(matches[i], entry_color)
        if #chunk >= chunk_size then
            AB_util.print("  " .. table.concat(chunk, ", "))
            chunk = {}
        end
    end
    if #chunk > 0 then
        AB_util.print("  " .. table.concat(chunk, ", "))
    end
end

local function print_online_group_report(group_name_s, group_color, total_members, matches, options)
    matches = type(matches) == "table" and matches or {}
    sort_online_matches(matches)
    options = type(options) == "table" and options or {}

    local safe_group_name = group_name_s or "?"
    local safe_group_color = group_color or AB_const.COLOR_SKY
    local safe_total_members = tonumber(total_members) or 0

    AB_util.print(
        "Online markgroup " .. online_color_text(safe_group_name, safe_group_color, AB_const.COLOR_SKY) ..
        ": " .. tostring(#matches) .. "/" .. tostring(safe_total_members) .. " online."
    )

    if options.suppress_snapshot ~= true then
        print_online_snapshot_line()
    end

    if #matches == 0 then
        return
    end

    print_online_match_chunks(matches, safe_group_color)
end

local function get_friend_list_entries()
    if type(GetFriendsList) ~= "function" then
        return nil, "friends list API unavailable"
    end

    local ok_list, friends_raw = pcall(GetFriendsList)
    if not ok_list or type(friends_raw) ~= "table" then
        return nil, "friends list unavailable"
    end

    local entries = {}
    local seen = {}
    for _, friend in pairs(friends_raw) do
        local name_raw
        if type(friend) == "table" then
            name_raw = friend.name or friend.m_name or friend.m_memberName
        else
            name_raw = friend
        end

        local name_key, display_name = nil, nil
        if AutoBand and type(AutoBand.normalize_wb_player_name) == "function" then
            name_key, display_name = AutoBand.normalize_wb_player_name(name_raw)
        end
        if not name_key then
            name_key = normalize_online_group_key(name_raw)
            display_name = online_enemy_to_string(name_raw)
        end
        if name_key and not seen[name_key] then
            seen[name_key] = true
            if not display_name or display_name == "" then
                display_name = name_key
            end
            entries[#entries + 1] = {
                key = name_key,
                display_name = display_name,
            }
        end
    end

    sort_online_matches(entries)

    return entries, nil
end

local function build_online_monitor_snapshot(
    group_key,
    monitor_entry,
    group,
    online_lookup,
    csv_status,
    display_lookup,
    level_lookup,
    careerline_lookup,
    charid_lookup,
    careername_lookup,
    careericon_lookup,
    faction_lookup,
    role_lookup
)
    local snapshot = {
        key = group_key,
        display_name = (monitor_entry and monitor_entry.name_s) or group_key,
        color = (monitor_entry and monitor_entry.color) or AB_const.COLOR_SKY,
        status = "group_missing",
        total_members = 0,
        match_count = 0,
        match_lookup = {},
        match_detail_lookup = {},
        signature = "group_missing",
    }

    if type(group) ~= "table" then
        snapshot.signature = "group_missing|" .. tostring(group_key or "")
        return snapshot
    end

    if group.name_s and group.name_s ~= "" then
        snapshot.display_name = group.name_s
    end
    if group.color then
        snapshot.color = group.color
    end
    snapshot.total_members = tonumber(group.member_count) or AB_util.size_table(group.members)

    if csv_status and csv_status ~= "ok" then
        snapshot.status = csv_status
        snapshot.signature = snapshot.status .. "|" .. tostring(snapshot.total_members)
        return snapshot
    end

    if type(online_lookup) ~= "table" or next(online_lookup) == nil then
        snapshot.status = "csv_empty"
        snapshot.signature = snapshot.status .. "|" .. tostring(snapshot.total_members)
        return snapshot
    end

    local matches = collect_online_group_matches(
        group,
        online_lookup,
        display_lookup,
        level_lookup,
        careerline_lookup,
        charid_lookup,
        careername_lookup,
        careericon_lookup,
        faction_lookup,
        role_lookup
    )
    snapshot.status = "ok"
    snapshot.match_count = #matches
    local parts = { "ok", tostring(snapshot.total_members), tostring(snapshot.match_count) }
    for i = 1, #matches do
        local match = matches[i]
        local key = match.key
        local name = match.display_name or key
        snapshot.match_lookup[key] = name
        snapshot.match_detail_lookup[key] = {
            key = key,
            display_name = name,
            rr = match.rr,
            level = match.level,
            career_line = match.career_line,
            character_id = match.character_id,
            career_name = match.career_name,
            career_icon = match.career_icon,
            faction = match.faction,
            role = match.role,
        }
        parts[#parts + 1] =
            tostring(key) .. ":" ..
            tostring(match.rr or "") .. ":" ..
            tostring(match.level or "") .. ":" ..
            tostring(match.career_line or "") .. ":" ..
            tostring(match.character_id or "") .. ":" ..
            tostring(match.career_name or "") .. ":" ..
            tostring(match.career_icon or "") .. ":" ..
            tostring(match.faction or "") .. ":" ..
            tostring(match.role or "")
    end
    snapshot.signature = table.concat(parts, "|")
    return snapshot
end

local function sorted_online_monitor_keys()
    ensure_online_monitor_runtime()
    local keys = {}
    for key, _ in pairs(AutoBand.online_monitor_groups) do
        if type(key) == "string" and key ~= "" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function online_monitor_status_text(status)
    if status == "ok" then
        return "ok"
    end
    if status == "csv_unavailable" then
        return "CSV unavailable"
    end
    if status == "csv_empty" then
        return "CSV empty"
    end
    if status == "csv_stale" then
        return "CSV stale"
    end
    if status == "group_missing" then
        return "group missing"
    end
    return tostring(status or "unknown")
end

local function print_online_monitor_list(groups)
    ensure_online_monitor_runtime()
    local count = get_online_monitor_count()
    if count <= 0 then
        AB_util.print("Online monitor groups: (none)")
        return
    end

    local live_lookup = {}
    if type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group and group.key then
                live_lookup[group.key] = group
            end
        end
    end

    AB_util.print("Online monitor groups (every " .. tostring(ONLINE_MONITOR_INTERVAL_SECONDS) .. "s):")
    local keys = sorted_online_monitor_keys()
    for i = 1, #keys do
        local key = keys[i]
        local entry = AutoBand.online_monitor_groups[key]
        local live_group = live_lookup[key]
        local name_s = (live_group and live_group.name_s) or (type(entry) == "table" and entry.name_s) or key
        local color = (live_group and live_group.color) or (type(entry) == "table" and entry.color) or AB_const.COLOR_SKY
        local label = online_color_text(name_s, color, AB_const.COLOR_SKY)

        local suffix = ""
        local state = AutoBand.online_monitor_state[key]
        if type(state) == "table" then
            if state.status == "ok" then
                suffix = " (" .. tostring(state.match_count or 0) .. "/" .. tostring(state.total_members or 0) .. " online)"
            else
                suffix = " (" .. online_monitor_status_text(state.status) .. ")"
            end
        end
        AB_util.print("  " .. label .. suffix)
    end
end

local function print_online_monitor_change(prev, snapshot)
    if type(snapshot) ~= "table" then
        return
    end
    local monitor_tag = "[" .. online_color_text("monitor", AB_const.COLOR_SILVER, AB_const.COLOR_SILVER) .. "]"
    local label = online_color_text(snapshot.display_name or snapshot.key or "?", snapshot.color, AB_const.COLOR_SKY)
    if snapshot.status ~= "ok" then
        AB_util.print(monitor_tag .. " " .. label .. ": " .. online_monitor_status_text(snapshot.status))
        return
    end

    local old_lookup = {}
    local old_details = {}
    if type(prev) == "table" and prev.status == "ok" then
        if type(prev.match_lookup) == "table" then
            old_lookup = prev.match_lookup
        end
        if type(prev.match_detail_lookup) == "table" then
            old_details = prev.match_detail_lookup
        end
    end
    local new_lookup = type(snapshot.match_lookup) == "table" and snapshot.match_lookup or {}
    local new_details = type(snapshot.match_detail_lookup) == "table" and snapshot.match_detail_lookup or {}
    local added = {}
    local removed = {}
    local changed = {}

    for key, _ in pairs(new_lookup) do
        if old_lookup[key] == nil then
            local detail = new_details[key] or { key = key, display_name = new_lookup[key] or key }
            added[#added + 1] = detail
        end
    end
    for key, _ in pairs(old_lookup) do
        if new_lookup[key] == nil then
            local detail = old_details[key] or { key = key, display_name = old_lookup[key] or key }
            removed[#removed + 1] = detail
        end
    end
    for key, _ in pairs(new_lookup) do
        if old_lookup[key] ~= nil then
            local old_detail = old_details[key] or { key = key, display_name = old_lookup[key] or key }
            local new_detail = new_details[key] or { key = key, display_name = new_lookup[key] or key }
            local old_rr = tonumber(old_detail.rr)
            local new_rr = tonumber(new_detail.rr)
            local old_level = tonumber(old_detail.level)
            local new_level = tonumber(new_detail.level)
            if old_rr ~= nil then old_rr = math.floor(old_rr) end
            if new_rr ~= nil then new_rr = math.floor(new_rr) end
            if old_level ~= nil then old_level = math.floor(old_level) end
            if new_level ~= nil then new_level = math.floor(new_level) end
            local changed_detail =
                tostring(old_detail.display_name or "") ~= tostring(new_detail.display_name or "") or
                tostring(old_detail.rr or "") ~= tostring(new_detail.rr or "") or
                tostring(old_detail.level or "") ~= tostring(new_detail.level or "") or
                tostring(old_detail.career_line or "") ~= tostring(new_detail.career_line or "") or
                tostring(old_detail.character_id or "") ~= tostring(new_detail.character_id or "") or
                tostring(old_detail.career_name or "") ~= tostring(new_detail.career_name or "") or
                tostring(old_detail.career_icon or "") ~= tostring(new_detail.career_icon or "") or
                tostring(old_detail.faction or "") ~= tostring(new_detail.faction or "") or
                tostring(old_detail.role or "") ~= tostring(new_detail.role or "")
            if changed_detail then
                local ranked_up =
                    (old_rr ~= nil and new_rr ~= nil and new_rr > old_rr) or
                    (old_level ~= nil and new_level ~= nil and new_level > old_level)
                changed[#changed + 1] = {
                    detail = new_detail,
                    ranked_up = ranked_up
                }
            end
        end
    end

    local function sort_details(list)
        table.sort(list, function(a, b)
            local a_detail = (a and a.detail) or a
            local b_detail = (b and b.detail) or b
            local a_name = (a_detail and (a_detail.display_name or a_detail.key)) or ""
            local b_name = (b_detail and (b_detail.display_name or b_detail.key)) or ""
            local a_key = normalize_online_member_sort_key(a_name)
            local b_key = normalize_online_member_sort_key(b_name)
            if a_key == b_key then
                return tostring(a_detail and a_detail.key or "") < tostring(b_detail and b_detail.key or "")
            end
            return a_key < b_key
        end)
    end

    local function format_member_detail(detail)
        local label_text = (detail and (detail.display_name or detail.key)) or "?"
        local link_data = nil
        if detail and detail.character_id ~= nil then
            link_data = online_killboard_link_data_for_character_id(detail.character_id)
        end
        if link_data ~= nil then
            label_text = online_color_text(label_text, AB_const.COLOR_WHITE, AB_const.COLOR_WHITE, link_data)
        end
        local class_prefix = realmrank_icon_for_detail(detail)
        local parts = {}
        local career_name = realmrank_name_for_detail(detail)
        if (not class_prefix or class_prefix == "") and career_name and career_name ~= "" then
            parts[#parts + 1] = career_name
        end
        if detail and detail.level ~= nil then
            local cr_text = "CR" .. tostring(detail.level)
            if detail.rr ~= nil then
                cr_text = cr_text .. ","
            end
            parts[#parts + 1] = online_color_text(cr_text, AB_const.COLOR_SILVER, AB_const.COLOR_SILVER)
        end
        if detail and detail.rr ~= nil then
            parts[#parts + 1] = online_color_text("RR" .. tostring(detail.rr), AB_const.COLOR_SILVER, AB_const.COLOR_SILVER)
        end
        if #parts > 0 then
            label_text = label_text .. " (" .. table.concat(parts, " ") .. ")"
        end
        if class_prefix and class_prefix ~= "" then
            return class_prefix .. " " .. label_text
        end
        return label_text
    end

    sort_details(added)
    sort_details(removed)
    sort_details(changed)

    local prefix = monitor_tag .. " "
    local function print_member_change(detail, verb)
        AB_util.print(prefix .. format_member_detail(detail) .. " " .. verb .. " (" .. label .. ").")
    end
    for i = 1, #added do
        print_member_change(added[i], "came online")
    end
    for i = 1, #removed do
        print_member_change(removed[i], "went offline")
    end
    for i = 1, #changed do
        local change = changed[i]
        local verb = (type(change) == "table" and change.ranked_up == true) and "ranked up" or "updated"
        local detail = (type(change) == "table" and change.detail) or change
        print_member_change(detail, verb)
    end

    if #added == 0 and #removed == 0 and #changed == 0 then
        AB_util.print(prefix .. "roster updated (online set unchanged) (" .. label .. ").")
    end
end

local function collect_online_monitor_snapshot_details(snapshot)
    local details = {}
    if type(snapshot) ~= "table" or type(snapshot.match_detail_lookup) ~= "table" then
        return details
    end
    for key, detail in pairs(snapshot.match_detail_lookup) do
        if type(detail) == "table" then
            details[#details + 1] = detail
        else
            details[#details + 1] = {
                key = key,
                display_name = key
            }
        end
    end
    sort_online_matches(details)
    return details
end

local function print_online_monitor_startup_state(snapshot, options)
    if type(snapshot) ~= "table" or snapshot.status ~= "ok" then
        return false
    end
    options = type(options) == "table" and options or {}

    local details = collect_online_monitor_snapshot_details(snapshot)
    print_online_group_report(
        snapshot.display_name or snapshot.key or "?",
        snapshot.color,
        snapshot.total_members,
        details,
        { suppress_snapshot = options.suppress_snapshot == true }
    )
    return true
end

local function try_emit_online_monitor_startup_state()
    ensure_online_monitor_runtime()

    if AutoBand.online_monitor_startup_pending ~= true then
        return true
    end
    if AutoBand.online_monitor_startup_announced == true then
        AutoBand.online_monitor_startup_pending = false
        return true
    end

    local monitor_count = get_online_monitor_count()
    if monitor_count <= 0 then
        AutoBand.online_monitor_startup_pending = false
        AutoBand.online_monitor_startup_announced = true
        AutoBand.online_monitor_startup_delay_elapsed = 0
        return true
    end

    if not has_online_enemy_templates() then
        AutoBand.online_monitor_startup_pending = false
        AutoBand.online_monitor_startup_announced = true
        AutoBand.online_monitor_startup_delay_elapsed = 0
        return true
    end

    local groups = get_online_enemy_mark_groups(AutoBand.online_monitor_groups)
    if groups == nil then
        return false
    end

    local group_lookup = {}
    if type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group and group.key then
                group_lookup[group.key] = group
            end
        end
    end

    local snapshot_state = nil
    if type(AutoBand.get_realmrank_snapshot_state) == "function" then
        snapshot_state = AutoBand.get_realmrank_snapshot_state(true)
    end
    if type(snapshot_state) ~= "table" or snapshot_state.status ~= "ok" then
        AutoBand.online_monitor_startup_pending = false
        AutoBand.online_monitor_startup_announced = true
        AutoBand.online_monitor_startup_delay_elapsed = 0
        return true
    end

    local online_lookup = snapshot_state.online_lookup
    local display_lookup = snapshot_state.display_lookup
    local charid_lookup = snapshot_state.charid_lookup
    local level_lookup = snapshot_state.level_lookup
    local careerline_lookup = snapshot_state.careerline_lookup
    local careername_lookup = snapshot_state.careername_lookup
    local careericon_lookup = snapshot_state.careericon_lookup
    local faction_lookup = snapshot_state.faction_lookup
    local role_lookup = snapshot_state.role_lookup

    for key, _ in pairs(AutoBand.online_monitor_state) do
        if AutoBand.online_monitor_groups[key] == nil then
            AutoBand.online_monitor_state[key] = nil
        end
    end

    local startup_snapshots = {}
    local keys = sorted_online_monitor_keys()
    for i = 1, #keys do
        local key = keys[i]
        local monitor_entry = AutoBand.online_monitor_groups[key]
        local group = group_lookup[key]
        local snapshot = build_online_monitor_snapshot(
            key,
            monitor_entry,
            group,
            online_lookup,
            snapshot_state.status,
            display_lookup,
            level_lookup,
            careerline_lookup,
            charid_lookup,
            careername_lookup,
            careericon_lookup,
            faction_lookup,
            role_lookup
        )

        if type(group) == "table" and type(monitor_entry) == "table" then
            monitor_entry.name_s = snapshot.display_name
            monitor_entry.color = snapshot.color
        end

        AutoBand.online_monitor_state[key] = snapshot
        startup_snapshots[#startup_snapshots + 1] = snapshot
    end

    local startup_has_printable = false
    for i = 1, #startup_snapshots do
        if type(startup_snapshots[i]) == "table" and startup_snapshots[i].status == "ok" then
            startup_has_printable = true
            break
        end
    end

    if startup_has_printable then
        print_online_snapshot_line()
    end
    for i = 1, #startup_snapshots do
        print_online_monitor_startup_state(startup_snapshots[i], { suppress_snapshot = true })
    end

    AutoBand.online_monitor_startup_pending = false
    AutoBand.online_monitor_startup_announced = true
    AutoBand.online_monitor_startup_delay_elapsed = 0
    return true
end
AutoBand.try_emit_online_monitor_startup_state = try_emit_online_monitor_startup_state

local function run_online_monitor_tick()
    ensure_online_monitor_runtime()
    local monitor_count = get_online_monitor_count()
    if monitor_count <= 0 then
        return
    end
    if not has_online_enemy_templates() then
        return
    end

    -- Check the CSV before walking any markgroup members.
    local snapshot_state = nil
    if type(AutoBand.get_realmrank_snapshot_state) == "function" then
        snapshot_state = AutoBand.get_realmrank_snapshot_state(true)
    end
    if type(snapshot_state) ~= "table" or snapshot_state.status ~= "ok" then
        return
    end

    local groups = get_online_enemy_mark_groups(AutoBand.online_monitor_groups)
    local group_lookup = {}
    if type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group and group.key then
                group_lookup[group.key] = group
            end
        end
    end
    local online_lookup = snapshot_state.online_lookup
    local display_lookup = snapshot_state.display_lookup
    local charid_lookup = snapshot_state.charid_lookup
    local level_lookup = snapshot_state.level_lookup
    local careerline_lookup = snapshot_state.careerline_lookup
    local careername_lookup = snapshot_state.careername_lookup
    local careericon_lookup = snapshot_state.careericon_lookup
    local faction_lookup = snapshot_state.faction_lookup
    local role_lookup = snapshot_state.role_lookup

    for key, _ in pairs(AutoBand.online_monitor_state) do
        if AutoBand.online_monitor_groups[key] == nil then
            AutoBand.online_monitor_state[key] = nil
        end
    end

    local keys = sorted_online_monitor_keys()
    for i = 1, #keys do
        local key = keys[i]
        local monitor_entry = AutoBand.online_monitor_groups[key]
        local group = group_lookup[key]
        local snapshot = build_online_monitor_snapshot(
            key,
            monitor_entry,
            group,
            online_lookup,
            snapshot_state.status,
            display_lookup,
            level_lookup,
            careerline_lookup,
            charid_lookup,
            careername_lookup,
            careericon_lookup,
            faction_lookup,
            role_lookup
        )

        if type(group) == "table" and type(monitor_entry) == "table" then
            monitor_entry.name_s = snapshot.display_name
            monitor_entry.color = snapshot.color
        end

        local prev = AutoBand.online_monitor_state[key]
        if type(prev) == "table" then
            if prev.signature ~= snapshot.signature then
                print_online_monitor_change(prev, snapshot)
            end
        end
        AutoBand.online_monitor_state[key] = snapshot
    end
end
AutoBand.run_online_monitor_tick = run_online_monitor_tick

rr_module.const = {
    REALMRANK_REFRESH_DEFAULT_SECONDS = REALMRANK_REFRESH_DEFAULT_SECONDS,
    REALMRANK_REFRESH_MIN_SECONDS = REALMRANK_REFRESH_MIN_SECONDS,
    REALMRANK_REFRESH_MAX_SECONDS = REALMRANK_REFRESH_MAX_SECONDS,
    REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS = REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS,
    ONLINE_MONITOR_INTERVAL_SECONDS = ONLINE_MONITOR_INTERVAL_SECONDS,
    ONLINE_MONITOR_STARTUP_DELAY_SECONDS = ONLINE_MONITOR_STARTUP_DELAY_SECONDS,
    REALMRANK_CSV_FILE_NAME = REALMRANK_CSV_FILE_NAME,
    REALMRANK_REQUIREMENT_STEP = REALMRANK_REQUIREMENT_STEP,
}

rr_module.fn = {
    ensure_online_monitor_runtime = ensure_online_monitor_runtime,
    get_online_monitor_count = get_online_monitor_count,
    has_online_enemy_templates = has_online_enemy_templates,
    get_online_enemy_mark_groups = get_online_enemy_mark_groups,
    find_online_enemy_group_by_key = find_online_enemy_group_by_key,
    print_online_enemy_group_list = print_online_enemy_group_list,
    clear_online_default_group = clear_online_default_group,
    normalize_online_group_key = normalize_online_group_key,
    sync_online_monitors_saved = sync_online_monitors_saved,
    clear_online_monitors = clear_online_monitors,
    print_online_monitor_list = print_online_monitor_list,
    collect_online_group_matches = collect_online_group_matches,
    print_online_group_report = print_online_group_report,
    get_friend_list_entries = get_friend_list_entries,
    sort_online_matches = sort_online_matches,
    print_online_snapshot_line = print_online_snapshot_line,
    get_cache_first_snapshot_state = get_cache_first_snapshot_state,
    print_online_match_chunks = print_online_match_chunks,
    online_color_text = online_color_text,
    try_emit_online_monitor_startup_state = try_emit_online_monitor_startup_state,
    run_online_monitor_tick = run_online_monitor_tick,
}

local function realmrank_loader_print(message)
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

local function load_realmrank_submodule(file_name)
    if type(dofile) ~= "function" then
        return false
    end
    local ok, err = pcall(dofile, file_name)
    if not ok then
        realmrank_loader_print("[Error] Failed to load " .. tostring(file_name) .. ": " .. tostring(err))
        return false
    end
    return true
end

load_realmrank_submodule("AB_realmrank_runtime.lua")
load_realmrank_submodule("AB_realmrank_commands.lua")

core.normalize_generated_utc_text = normalize_generated_utc_text
core.format_epoch_seconds_utc = format_epoch_seconds_utc
core.normalize_realmrank_character_id = normalize_realmrank_character_id
AutoBand._core_api = core
