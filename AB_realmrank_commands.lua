-- AB_realmrank_commands.lua
-- Command handlers for rank requirements and RR-backed online/friends lookups.
-- Rank setters also arm the short rank-enforcement grace window when /ab akl
-- is already enabled, so leaders can finish tweaking thresholds first.

if type(AutoBand) ~= "table" then
    AutoBand = {}
end

local rr_module = AutoBand._realmrank_module or {}
local rr_const = rr_module.const or {}
local rr_fn = rr_module.fn or {}

local ONLINE_MONITOR_INTERVAL_SECONDS = rr_const.ONLINE_MONITOR_INTERVAL_SECONDS or 60
local REALMRANK_CSV_FILE_NAME = rr_const.REALMRANK_CSV_FILE_NAME or "AutoBand_RealmRank.csv"
local CAREER_RANK_REQUIREMENT_MIN = rr_const.CAREER_RANK_REQUIREMENT_MIN or 1
local REALMRANK_REQUIREMENT_STEP = rr_const.REALMRANK_REQUIREMENT_STEP or 5
local RRCACHE_DEFAULT_LIST_LIMIT = 5
local RRCACHE_MAX_LIST_LIMIT = 20

local ensure_online_monitor_runtime = rr_fn.ensure_online_monitor_runtime
local get_online_enemy_mark_groups = rr_fn.get_online_enemy_mark_groups
local find_online_enemy_group_by_key = rr_fn.find_online_enemy_group_by_key
local print_online_enemy_group_list = rr_fn.print_online_enemy_group_list
local clear_online_default_group = rr_fn.clear_online_default_group
local normalize_online_group_key = rr_fn.normalize_online_group_key
local sync_online_monitors_saved = rr_fn.sync_online_monitors_saved
local clear_online_monitors = rr_fn.clear_online_monitors
local print_online_monitor_list = rr_fn.print_online_monitor_list
local collect_online_group_matches = rr_fn.collect_online_group_matches
local print_online_group_report = rr_fn.print_online_group_report
local get_friend_list_entries = rr_fn.get_friend_list_entries
local sort_online_matches = rr_fn.sort_online_matches
local print_online_snapshot_line = rr_fn.print_online_snapshot_line
local get_cache_first_snapshot_state = rr_fn.get_cache_first_snapshot_state
local print_online_match_chunks = rr_fn.print_online_match_chunks
local online_color_text = rr_fn.online_color_text

if type(ensure_online_monitor_runtime) ~= "function" then
    ensure_online_monitor_runtime = function() end
end
if type(get_online_enemy_mark_groups) ~= "function" then
    get_online_enemy_mark_groups = function() return nil end
end
if type(find_online_enemy_group_by_key) ~= "function" then
    find_online_enemy_group_by_key = function() return nil end
end
if type(print_online_enemy_group_list) ~= "function" then
    print_online_enemy_group_list = function() end
end
if type(clear_online_default_group) ~= "function" then
    clear_online_default_group = function() end
end
if type(normalize_online_group_key) ~= "function" then
    normalize_online_group_key = function(value)
        if type(value) ~= "string" then
            return nil
        end
        local ok_lower, lowered = pcall(string.lower, value)
        if ok_lower then
            return lowered
        end
        return nil
    end
end
if type(sync_online_monitors_saved) ~= "function" then
    sync_online_monitors_saved = function() end
end
if type(clear_online_monitors) ~= "function" then
    clear_online_monitors = function() return 0 end
end
if type(print_online_monitor_list) ~= "function" then
    print_online_monitor_list = function() end
end
if type(collect_online_group_matches) ~= "function" then
    collect_online_group_matches = function() return {} end
end
if type(print_online_group_report) ~= "function" then
    print_online_group_report = function() end
end
if type(get_friend_list_entries) ~= "function" then
    get_friend_list_entries = function() return nil, "friends helper unavailable" end
end
if type(sort_online_matches) ~= "function" then
    sort_online_matches = function() end
end
if type(print_online_snapshot_line) ~= "function" then
    print_online_snapshot_line = function() return false end
end
if type(get_cache_first_snapshot_state) ~= "function" then
    get_cache_first_snapshot_state = function(_error_context) return nil end
end
if type(print_online_match_chunks) ~= "function" then
    print_online_match_chunks = function() end
end
if type(online_color_text) ~= "function" then
    online_color_text = function(text)
        return tostring(text or "")
    end
end

local function online_monitor_usage()
    AB_util.print("Usage: /ab online monitor <group>[, <group>...]")
    AB_util.print("       /ab online monitor add <group>[, <group>...]")
    AB_util.print("       /ab online monitor remove <group>[, <group>...]")
    AB_util.print("       /ab online monitor list")
    AB_util.print("       /ab online monitor clear")
end

local function online_monitor_trim_query(value)
    local text = tostring(value or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function online_monitor_build_group_lookup(groups)
    local lookup = {}
    if type(groups) ~= "table" then
        return lookup
    end

    for _, group in ipairs(groups) do
        if type(group) == "table" and type(group.key) == "string" and group.key ~= "" then
            lookup[group.key] = group
        end
    end

    return lookup
end

local function online_monitor_add_unique(parsed, seen, item)
    if type(item) ~= "table" or type(item.key) ~= "string" or item.key == "" then
        return
    end
    if seen[item.key] then
        return
    end
    seen[item.key] = true
    parsed[#parsed + 1] = item
end

local function online_monitor_parse_tokens(args, start_index, lookup)
    local parsed = {}
    local seen = {}
    local index = start_index

    while index <= #args do
        local found = nil
        local found_end = nil
        local scan_end = #args

        while scan_end >= index do
            local candidate = table.concat(args, " ", index, scan_end)
            local key = normalize_online_group_key(candidate)
            if key and lookup[key] then
                found = lookup[key]
                found_end = scan_end
                break
            end
            scan_end = scan_end - 1
        end

        if not found then
            return nil
        end

        online_monitor_add_unique(parsed, seen, found)
        index = found_end + 1
    end

    return parsed
end

local function online_monitor_parse_delimited(raw_query, lookup)
    local parsed = {}
    local seen = {}

    for segment in string.gmatch(raw_query, "[^,;]+") do
        local query = online_monitor_trim_query(segment)
        if query ~= "" then
            local key = normalize_online_group_key(query)
            local group = key and lookup[key] or nil
            if not group then
                return nil, query
            end
            online_monitor_add_unique(parsed, seen, group)
        end
    end

    if #parsed <= 0 then
        return nil, raw_query
    end

    return parsed, nil
end

local function online_monitor_parse_add_groups(args, start_index, groups)
    local raw_query = online_monitor_trim_query(table.concat(args, " ", start_index))
    if raw_query == "" then
        return nil, nil
    end

    local lookup = online_monitor_build_group_lookup(groups)
    local exact_key = normalize_online_group_key(raw_query)
    if exact_key and lookup[exact_key] then
        return { lookup[exact_key] }, nil
    end

    if string.find(raw_query, "[,;]") then
        return online_monitor_parse_delimited(raw_query, lookup)
    end

    local parsed = online_monitor_parse_tokens(args, start_index, lookup)
    if parsed and #parsed > 0 then
        return parsed, nil
    end

    return nil, raw_query
end

local function online_monitor_build_remove_lookup(groups)
    local lookup = online_monitor_build_group_lookup(groups)

    ensure_online_monitor_runtime()
    if type(AutoBand.online_monitor_groups) == "table" then
        for raw_key, entry in pairs(AutoBand.online_monitor_groups) do
            local key = normalize_online_group_key(raw_key)
            if key then
                local name_s = key
                local color = nil
                if type(entry) == "table" then
                    name_s = entry.name_s or key
                    color = entry.color
                end
                lookup[key] = {
                    key = key,
                    name_s = name_s,
                    color = color
                }
            end
        end
    end

    return lookup
end

local function online_monitor_parse_remove_queries(args, start_index, groups)
    local raw_query = online_monitor_trim_query(table.concat(args, " ", start_index))
    if raw_query == "" then
        return nil
    end

    local lookup = online_monitor_build_remove_lookup(groups)
    local exact_key = normalize_online_group_key(raw_query)
    if exact_key and lookup[exact_key] then
        return { lookup[exact_key] }
    end

    if string.find(raw_query, "[,;]") then
        local parsed = {}
        local seen = {}
        for segment in string.gmatch(raw_query, "[^,;]+") do
            local query = online_monitor_trim_query(segment)
            local key = normalize_online_group_key(query)
            if key and not seen[key] then
                local item = lookup[key] or {
                    key = key,
                    name_s = query
                }
                parsed[#parsed + 1] = item
                seen[key] = true
            end
        end
        if #parsed > 0 then
            return parsed
        end
    else
        local parsed = online_monitor_parse_tokens(args, start_index, lookup)
        if parsed and #parsed > 0 then
            return parsed
        end
    end

    if exact_key then
        return {
            {
                key = exact_key,
                name_s = raw_query
            }
        }
    end

    return nil
end

local function rrcache_usage()
    AB_util.print("Usage: /ab rrcache [summary|oldest [count]|newest [count]]")
end

local function rrcache_parse_limit(raw)
    if raw == nil or raw == "" then
        return RRCACHE_DEFAULT_LIST_LIMIT
    end

    local value = tonumber(raw)
    if value == nil then
        return nil
    end

    value = math.floor(value)
    if value < 1 or value > RRCACHE_MAX_LIST_LIMIT then
        return nil
    end

    return value
end

local function rrcache_format_age(age_seconds)
    local age = tonumber(age_seconds)
    if age == nil then
        return "unknown"
    end

    age = math.floor(age)
    if age < 0 then
        age = 0
    end

    local days = math.floor(age / (24 * 60 * 60))
    age = age - (days * 24 * 60 * 60)
    local hours = math.floor(age / (60 * 60))
    age = age - (hours * 60 * 60)
    local minutes = math.floor(age / 60)
    local seconds = age - (minutes * 60)

    if days > 0 then
        if hours > 0 then
            return tostring(days) .. "d " .. tostring(hours) .. "h"
        end
        return tostring(days) .. "d"
    end
    if hours > 0 then
        if minutes > 0 then
            return tostring(hours) .. "h " .. tostring(minutes) .. "m"
        end
        return tostring(hours) .. "h"
    end
    if minutes > 0 then
        return tostring(minutes) .. "m"
    end
    return tostring(seconds) .. "s"
end

local function rrcache_plural(count, singular, plural)
    if tonumber(count) == 1 then
        return singular
    end
    return plural or (singular .. "s")
end

local function rrcache_should_show_key(item)
    if type(item) ~= "table" then
        return false
    end

    local key = item.key
    local display_name = item.display_name
    if type(key) ~= "string" or key == "" or type(display_name) ~= "string" or display_name == "" then
        return false
    end
    if key == display_name then
        return false
    end

    local ok_lower, lowered = pcall(string.lower, display_name)
    if ok_lower and lowered == key then
        return false
    end

    return true
end

local function rrcache_print_summary(summary)
    if type(summary) ~= "table" then
        AB_util.print("[Error] RR fallback cache summary is unavailable.")
        return
    end

    AB_util.print(
        "RR fallback cache: raw " .. tostring(summary.raw_count or 0) ..
        ", valid " .. tostring(summary.valid_count or 0) ..
        ", expired " .. tostring(summary.expired_count or 0) ..
        ", invalid " .. tostring(summary.invalid_count or 0) ..
        ", over-cap " .. tostring(summary.over_cap_count or 0) .. "."
    )

    if (summary.valid_count or 0) > 0 then
        if (summary.valid_known_age_count or 0) > 0 then
            local age_line =
                "Valid ages: newest " .. rrcache_format_age(summary.newest_valid_age_seconds) ..
                ", oldest " .. rrcache_format_age(summary.oldest_valid_age_seconds)
            if summary.average_valid_age_seconds ~= nil then
                age_line = age_line .. ", avg " .. rrcache_format_age(summary.average_valid_age_seconds)
            end
            if (summary.valid_known_age_count or 0) < (summary.valid_count or 0) then
                local unknown_count = (summary.valid_count or 0) - (summary.valid_known_age_count or 0)
                age_line = age_line .. " (" .. tostring(unknown_count) .. " unknown)"
            end
            AB_util.print(age_line .. ".")
            local buckets = summary.age_bucket_counts or {}
            AB_util.print(
                "Buckets: <1h " .. tostring(buckets.under_1h or 0) ..
                ", <1d " .. tostring(buckets.under_1d or 0) ..
                ", <7d " .. tostring(buckets.under_7d or 0) ..
                ", <=14d " .. tostring(buckets.under_14d or 0) ..
                ", unknown " .. tostring(buckets.unknown or 0) .. "."
            )
        else
            AB_util.print("Valid ages: unavailable (cache clock is not seeded yet).")
        end
    end

    local policy_days = math.floor((tonumber(summary.policy_max_age_seconds) or 0) / (24 * 60 * 60))
    local last_cleanup_text = "never recorded"
    if summary.last_cleanup_utc and summary.last_cleanup_utc ~= "" then
        last_cleanup_text = summary.last_cleanup_utc
        if summary.last_cleanup_age_seconds ~= nil then
            last_cleanup_text = last_cleanup_text .. " (" .. rrcache_format_age(summary.last_cleanup_age_seconds) .. " ago)"
        end
    end

    AB_util.print(
        "Last cleanup: " .. last_cleanup_text ..
        ". Policy: max age " .. tostring(policy_days) ..
        "d, cleanup every " .. rrcache_format_age(summary.policy_clean_interval_seconds) ..
        ", cap " .. tostring(summary.policy_max_entries or 0) .. "."
    )

    if (summary.over_cap_count or 0) > 0 then
        AB_util.print(
            "At current size, cleanup would trim " .. tostring(summary.over_cap_count) ..
            " oldest valid " .. rrcache_plural(summary.over_cap_count, "entry", "entries") ..
            " to reach the cap."
        )
    end
end

local function rrcache_print_entries(summary, mode)
    if type(summary) ~= "table" then
        AB_util.print("[Error] RR fallback cache summary is unavailable.")
        return
    end

    local entries = summary.oldest_valid_entries or {}
    local label = "oldest"
    if mode == "newest" then
        entries = summary.newest_valid_entries or {}
        label = "newest"
    end

    if (summary.valid_count or 0) <= 0 then
        AB_util.print(
            "RR fallback cache has no valid entries (" ..
            tostring(summary.expired_count or 0) .. " expired, " ..
            tostring(summary.invalid_count or 0) .. " invalid)."
        )
        return
    end

    AB_util.print(
        "RR fallback cache " .. label .. " valid entries: showing " ..
        tostring(#entries) .. "/" .. tostring(summary.valid_count or 0) .. "."
    )

    for i = 1, #entries do
        local item = entries[i]
        local line = "  " .. tostring(i) .. ". " .. tostring(item.display_name or item.key or "?")
        if rrcache_should_show_key(item) then
            line = line .. " [" .. tostring(item.key) .. "]"
        end
        if item and item.rr ~= nil then
            line = line .. " RR" .. tostring(item.rr)
        end
        if item and item.last_seen_utc ~= nil then
            line = line .. ", seen " .. tostring(item.last_seen_utc)
        end
        if item and item.age_seconds ~= nil then
            line = line .. " (" .. rrcache_format_age(item.age_seconds) .. " ago)"
        end
        AB_util.print(line)
    end

    if (summary.expired_count or 0) > 0 or (summary.invalid_count or 0) > 0 then
        AB_util.print(
            "Skipped " .. tostring(summary.expired_count or 0) .. " expired and " ..
            tostring(summary.invalid_count or 0) .. " invalid cached " ..
            rrcache_plural((summary.expired_count or 0) + (summary.invalid_count or 0), "entry", "entries") .. "."
        )
    end
end

local function cmd_online_monitor(args, groups)
    ensure_online_monitor_runtime()
    local subcmd = args[2] and tostring(args[2]):lower() or "list"
    local is_removal = subcmd == "clear" or subcmd == "reset" or subcmd == "off" or subcmd == "none" or
        subcmd == "remove" or subcmd == "delete" or subcmd == "del" or subcmd == "rm"

    -- Without Enemy (or with no markgroups) only removals work: saved monitors for
    -- groups that no longer exist must stay removable.
    if type(groups) ~= "table" or #groups == 0 then
        if not is_removal then
            return
        end
        groups = {}
    end

    if subcmd == "list" or subcmd == "ls" then
        print_online_monitor_list(groups)
        return
    end

    if subcmd == "clear" or subcmd == "reset" or subcmd == "off" or subcmd == "none" then
        local cleared = clear_online_monitors()
        AB_util.print("Online monitor cleared (" .. tostring(cleared) .. " group(s)).")
        return
    end

    if subcmd == "remove" or subcmd == "delete" or subcmd == "del" or subcmd == "rm" then
        local queries = nil
        if #args >= 3 then
            queries = online_monitor_parse_remove_queries(args, 3, groups)
        end
        if type(queries) ~= "table" or #queries <= 0 then
            online_monitor_usage()
            return
        end

        local removed_count = 0
        for i = 1, #queries do
            local query = queries[i]
            local query_key = query and query.key
            local query_name = (query and query.name_s) or query_key
            if not query_key then
                AB_util.print("[Error] Invalid monitor group: " .. tostring(query_name))
            elseif AutoBand.online_monitor_groups[query_key] == nil then
                AB_util.print("Online monitor was not tracking: " .. tostring(query_name))
            else
                AutoBand.online_monitor_groups[query_key] = nil
                AutoBand.online_monitor_state[query_key] = nil
                removed_count = removed_count + 1
                AB_util.print("Online monitor removed: " .. tostring(query_name))
            end
        end

        if removed_count > 0 then
            if next(AutoBand.online_monitor_groups) == nil then
                AutoBand.online_monitor_startup_pending = false
                AutoBand.online_monitor_startup_announced = false
                AutoBand.online_monitor_startup_delay_elapsed = 0
            end
            sync_online_monitors_saved()
        end
        return
    end

    local groups_to_add = nil
    local missing_query = nil
    if subcmd == "add" then
        if #args >= 3 then
            groups_to_add, missing_query = online_monitor_parse_add_groups(args, 3, groups)
        end
    else
        groups_to_add, missing_query = online_monitor_parse_add_groups(args, 2, groups)
    end

    if missing_query then
        AB_util.print("[Error] Enemy markgroup not found: " .. tostring(missing_query))
        print_online_enemy_group_list(groups)
        return
    end

    if type(groups_to_add) ~= "table" or #groups_to_add <= 0 then
        online_monitor_usage()
        print_online_monitor_list(groups)
        return
    end

    local results = {}
    for i = 1, #groups_to_add do
        local group = groups_to_add[i]
        local already = AutoBand.online_monitor_groups[group.key] ~= nil
        AutoBand.online_monitor_groups[group.key] = {
            name_s = group.name_s,
            color = group.color
        }
        if not already then
            AutoBand.online_monitor_state[group.key] = nil
        end
        results[#results + 1] = {
            group = group,
            already = already
        }
    end

    sync_online_monitors_saved()

    for i = 1, #results do
        local result = results[i]
        local group = result.group
        if result.already then
            AB_util.print("Online monitor updated: " .. online_color_text(group.name_s, group.color, AB_const.COLOR_SKY) .. ".")
        else
            AB_util.print(
                "Online monitor added: " ..
                online_color_text(group.name_s, group.color, AB_const.COLOR_SKY) ..
                " (every " .. tostring(ONLINE_MONITOR_INTERVAL_SECONDS) .. "s)."
            )
        end
    end
end

function AutoBand.get_low_rank(wb_obj, opts)
    opts = type(opts) == "table" and opts or {}
    local include_unknown_rr = opts.include_unknown_rr == true
    if (not wb_obj) then
        wb_obj = AutoBand.get_wb()
    end
    if not wb_obj or type(wb_obj.foreach_player) ~= "function" then
        return {}, {}
    end
    local list = {}
    local unresolved = {}
    wb_obj:foreach_player(
        function(_gid, player)
            if not player or not player.name then
                return
            end
            local needed = AutoBand.get_effective_saved_rank_requirement_for_role(player.role)
            local rank_state = AutoBand.get_rank_requirement_status_for_player(player, needed, { treat_unknown_rr_as_below = false })
            if rank_state.below_required then
                table.insert(list, {
                    name = player.name,
                    role = player.role,
                    level = player.level,
                    required_rank = rank_state.required_rank,
                    required_metric = rank_state.required_metric,
                    rank_value = rank_state.rank_value,
                    rr_source = rank_state.rr_source
                })
            elseif include_unknown_rr and rank_state.required_metric == "RR" and not rank_state.has_rank_info then
                table.insert(unresolved, {
                    name = player.name,
                    role = player.role,
                    level = player.level,
                    required_rank = rank_state.required_rank,
                    required_metric = rank_state.required_metric
                })
            end
        end
    )
    return list, unresolved
end

function AutoBand.cmd_list_rank(_args)
    local str = ""
    local players, unresolved = AutoBand.get_low_rank(nil, { include_unknown_rr = true })
    if (#players > 0) then
        table.sort(players, function(p1, p2)
            local a_rank = tonumber(p1.rank_value) or tonumber(p1.level) or 0
            local b_rank = tonumber(p2.rank_value) or tonumber(p2.level) or 0
            if a_rank ~= b_rank then
                return a_rank > b_rank
            end
            return tostring(p1.name) < tostring(p2.name)
        end)
        for _, player in ipairs(players) do
            local metric = player.required_metric or AutoBand.get_rank_requirement_metric_label(player.required_rank)
            local rank_value = tonumber(player.rank_value)
            if rank_value == nil then
                rank_value = tonumber(player.level) or 0
            end
            str = str .. tostring(player.name) .. "(" .. metric .. " " .. tostring(rank_value) .. " < " .. tostring(player.required_rank) .. ") "
        end
        AB_util.print(AB_const.HEADER_MARGIN ..
            " Players below configured rank requirements " ..
            AB_const.HEADER_MARGIN ..
            " (#" .. #players .. ")")
        AB_util.print(str)
    else
        AB_util.print("No players are currently below configured rank requirements.")
    end
    if unresolved and #unresolved > 0 then
        local unresolved_names = {}
        for i = 1, #unresolved do
            unresolved_names[#unresolved_names + 1] = tostring(unresolved[i].name)
        end
        table.sort(unresolved_names)
        AB_util.print("RR pending (deferred until rank updates arrive): " .. table.concat(unresolved_names, ", "))
    end
end

local function maybe_refresh_config_tab_after_rank_change()
    if type(AutoBand.refresh_settings_ui) == "function" then
        AutoBand.refresh_settings_ui()
    end
end

local function get_rank_requirement_role_label(role_key)
    if role_key == AB_const.TANK then
        return "tank"
    end
    if role_key == AB_const.HEALER then
        return "healer"
    end
    if role_key == "dps" then
        return "dps"
    end
    return nil
end

local function uppercase_first_ascii(text)
    if type(text) ~= "string" or text == "" then
        return text
    end
    return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

local function get_saved_rank_requirement_triplet()
    if type(AutoBand.get_saved_rank_requirements) == "function" then
        return AutoBand.get_saved_rank_requirements(AutoBand.saved or {})
    end
    local saved = AutoBand.saved or {}
    local legacy_rank = AutoBand.normalize_rank_requirement_value(saved.min_rank, AB_const.MINIMUM_RANK)
    return
        AutoBand.normalize_rank_requirement_value(saved.min_rank_tank, legacy_rank),
        AutoBand.normalize_rank_requirement_value(saved.min_rank_healer, AB_const.MINIMUM_RANK_HEALER),
        AutoBand.normalize_rank_requirement_value(saved.min_rank_dps, legacy_rank)
end

local function set_saved_rank_requirement_triplet(tank_rank, healer_rank, dps_rank)
    if type(AutoBand.set_saved_rank_requirements) == "function" then
        return AutoBand.set_saved_rank_requirements(tank_rank, healer_rank, dps_rank, AutoBand.saved or {})
    end
    AutoBand.saved.min_rank_tank = AutoBand.normalize_rank_requirement_value(tank_rank, AB_const.MINIMUM_RANK_TANK)
    AutoBand.saved.min_rank_healer = AutoBand.normalize_rank_requirement_value(healer_rank, AB_const.MINIMUM_RANK_HEALER)
    AutoBand.saved.min_rank_dps = AutoBand.normalize_rank_requirement_value(dps_rank, AB_const.MINIMUM_RANK_DPS)
    if type(AutoBand.sync_legacy_rank_requirement_fields) == "function" then
        AutoBand.sync_legacy_rank_requirement_fields(AutoBand.saved)
    end
    return AutoBand.saved.min_rank_tank, AutoBand.saved.min_rank_healer, AutoBand.saved.min_rank_dps
end

local function print_rank_requirement_summary()
    local tank_rank, healer_rank, dps_rank = AutoBand.get_effective_saved_rank_requirements()
    if tank_rank == healer_rank and healer_rank == dps_rank then
        AB_util.print("Minimum rank requirement: " .. AutoBand.format_rank_requirement_value(tank_rank))
        return
    end
    AB_util.print("Minimum rank requirement (tank): " .. AutoBand.format_rank_requirement_value(tank_rank))
    AB_util.print("Minimum rank requirement (healer): " .. AutoBand.format_rank_requirement_value(healer_rank))
    AB_util.print("Minimum rank requirement (dps): " .. AutoBand.format_rank_requirement_value(dps_rank))
end

local function parse_rank_requirement_argument(args, role_key)
    if args[1] == nil then
        AB_util.print("[error] Missing argument")
        return nil
    end

    local role_label = get_rank_requirement_role_label(role_key)
    local raw = args[1]
    local n = tonumber(raw)
    if n == nil then
        if role_label then
            AB_util.print("[error] Invalid " .. role_label .. " rank value: " .. tostring(raw))
        else
            AB_util.print("[error] Invalid rank value: " .. tostring(raw))
        end
        return nil
    end

    n = math.floor(n)
    if n < CAREER_RANK_REQUIREMENT_MIN or n > AB_const.MAXIMUM_RANK then
        if role_label then
            AB_util.print("[error] Invalid " .. role_label .. " rank value: " .. tostring(n) .. ". Use 1-40 for CR, 45-70 for RR.")
        else
            AB_util.print("[error] Invalid rank value: " .. tostring(n) .. ". Use 1-40 for CR, 45-70 for RR.")
        end
        return nil
    end

    if not AutoBand.is_valid_rank_requirement_step(n) then
        if role_label then
            AB_util.print("[error] " .. uppercase_first_ascii(role_label) .. " RR requirements above 40 must use " .. tostring(REALMRANK_REQUIREMENT_STEP) .. "-point increments (45/50/55/60/65/70).")
        else
            AB_util.print("[error] RR requirements above 40 must use " .. tostring(REALMRANK_REQUIREMENT_STEP) .. "-point increments (45/50/55/60/65/70).")
        end
        return nil
    end

    if AutoBand.is_realmrank_requirement_value(n) then
        local ok_rr, miss_reason = AutoBand.can_use_realmrank_requirement(true)
        if not ok_rr then
            if role_label then
                AB_util.print("[error] Cannot set " .. role_label .. " RR requirement above 40: " .. tostring(miss_reason) .. ". Please restart the rank updater and run /ab csvrefresh.")
            else
                AB_util.print("[error] Cannot set RR requirement above 40: " .. tostring(miss_reason) .. ". Please restart the rank updater and run /ab csvrefresh.")
            end
            return nil
        end
    end

    return n
end

function AutoBand.cmd_rank(args)
    local n = parse_rank_requirement_argument(args, nil)
    if n == nil then
        return
    end

    local tank_rank, healer_rank, dps_rank = get_saved_rank_requirement_triplet()
    local changed = tank_rank ~= n or dps_rank ~= n
    set_saved_rank_requirement_triplet(n, healer_rank, n)
    if changed and type(AutoBand.arm_rank_requirement_grace) == "function" then
        AutoBand.arm_rank_requirement_grace()
    end
    AB_util.print("Minimum rank requirement (tank+dps): " .. AutoBand.format_rank_requirement_value(n))
    print_rank_requirement_summary()
    if AutoBand and AutoBand.mark_template_settings_modified then
        AutoBand.mark_template_settings_modified()
    end
    maybe_refresh_config_tab_after_rank_change()
end

local function set_role_rank_requirement(role_key, args)
    local n = parse_rank_requirement_argument(args, role_key)
    if n == nil then
        return
    end

    local tank_rank, healer_rank, dps_rank = get_saved_rank_requirement_triplet()
    local changed
    if role_key == AB_const.TANK then
        changed = tank_rank ~= n
        tank_rank = n
    elseif role_key == AB_const.HEALER then
        changed = healer_rank ~= n
        healer_rank = n
    else
        changed = dps_rank ~= n
        dps_rank = n
    end
    set_saved_rank_requirement_triplet(tank_rank, healer_rank, dps_rank)
    if changed and type(AutoBand.arm_rank_requirement_grace) == "function" then
        AutoBand.arm_rank_requirement_grace()
    end
    AB_util.print("Minimum rank requirement (" .. tostring(get_rank_requirement_role_label(role_key)) .. "): " .. AutoBand.format_rank_requirement_value(n))
    print_rank_requirement_summary()
    if AutoBand and AutoBand.mark_template_settings_modified then
        AutoBand.mark_template_settings_modified()
    end
    maybe_refresh_config_tab_after_rank_change()
end

function AutoBand.cmd_rank_tank(args)
    set_role_rank_requirement(AB_const.TANK, args)
end

function AutoBand.cmd_rank_healer(args)
    set_role_rank_requirement(AB_const.HEALER, args)
end

function AutoBand.cmd_rank_dps(args)
    set_role_rank_requirement("dps", args)
end

function AutoBand.cmd_kick_rank(_args)
    if not AutoBand.require_warband_features_enabled("kicking warband members") then
        return
    end

    if (not AutoBand.is_wb_leader()) then
        AB_util.print("[error] You need to be a wb leader")
        return
    end
    local players, unresolved = AutoBand.get_low_rank(nil, { include_unknown_rr = true })
    if (#players > 0) then
        AB_util.print("Kicking players below rank requirements")
        for _, player in ipairs(players) do
            local needed = AutoBand.normalize_rank_requirement_value(player.required_rank, AutoBand.get_effective_saved_rank_requirement_for_role(player.role))
            local metric = player.required_metric or AutoBand.get_rank_requirement_metric_label(needed)
            AutoBand.enqueue_kick(player.name,
                "you don't meet the " .. metric .. " requirement (" .. tostring(needed) .. "+)")
        end
    else
        AB_util.print("No players currently fail the configured rank requirements.")
    end
    if unresolved and #unresolved > 0 then
        AB_util.print("Skipped " .. tostring(#unresolved) .. " player(s) with RR still unconfirmed.")
    end
    AB_util.print("Rank kick complete")
end

function AutoBand.cmd_rrlookup(args)
    local name_arg = nil
    if type(args) == "table" then
        name_arg = args[1]
    end

    if not name_arg or tostring(name_arg) == "" then
        AB_util.print("Usage: /ab rrlookup <name>")
        return
    end

    if type(AutoBand.refresh_realmrank_cache) ~= "function" or type(AutoBand.get_realm_rank_for_name) ~= "function" then
        AB_util.print("[Error] Realm-rank lookup is unavailable in this build.")
        return
    end

    local name_text = tostring(name_arg)
    local loaded = false
    if type(AutoBand.ensure_realmrank_snapshot_loaded) == "function" then
        loaded = AutoBand.ensure_realmrank_snapshot_loaded(false) == true
    elseif type(AutoBand.refresh_realmrank_cache) == "function" then
        loaded = AutoBand.refresh_realmrank_cache(true) == true
    end

    local lookup_result = nil
    if AutoBand.get_realm_rank_lookup_result then
        lookup_result = AutoBand.get_realm_rank_lookup_result(name_text, {
            allow_cache_fallback = true
        })
        if lookup_result and lookup_result.source == "csv" then
            -- /ab rrlookup should only seed/refresh fallback cache when CSV provided the hit.
            local touched = AutoBand.get_realm_rank_lookup_result(name_text, {
                allow_cache_fallback = false,
                touch_cache = true,
                skip_cleanup = true
            })
            if touched then
                lookup_result = touched
            end
        end
    end
    local rr
    local level = nil
    local csv_name
    local character_id
    local career_icon = nil
    if lookup_result then
        rr = lookup_result.rr
        level = tonumber(lookup_result.level)
        if level ~= nil then
            level = math.floor(level)
            if level < 0 then
                level = nil
            end
        end
        csv_name = lookup_result.display_name
        character_id = lookup_result.character_id
        if lookup_result.career_icon ~= nil then
            career_icon = tostring(lookup_result.career_icon)
            if career_icon == "" then
                career_icon = nil
            end
        end
    else
        rr = AutoBand.get_realm_rank_for_name(name_text)
        if AutoBand.get_realmrank_display_name_for_name then
            csv_name = AutoBand.get_realmrank_display_name_for_name(name_text)
        end
        if AutoBand.get_realmrank_character_id_for_name then
            character_id = AutoBand.get_realmrank_character_id_for_name(name_text)
        end
    end
    local _, display_name = AutoBand.normalize_wb_player_name(name_text)
    if rr ~= nil and csv_name and csv_name ~= "" then
        display_name = csv_name
    elseif not display_name or display_name == "" then
        display_name = name_text
    end
    local name_link_data = nil
    if type(AutoBand.build_killboard_link_data_for_character_id) == "function" then
        name_link_data = AutoBand.build_killboard_link_data_for_character_id(character_id)
    end
    local lookup_name_text = online_color_text(display_name, AB_const.COLOR_SKY, AB_const.COLOR_WHITE, name_link_data)
    if career_icon then
        lookup_name_text = career_icon .. " " .. lookup_name_text
    end

    local data_time_text
    if lookup_result and lookup_result.source == "cache" then
        if lookup_result.cache_seen_utc and lookup_result.cache_seen_utc ~= "" then
            data_time_text = "rr-cache seen " .. lookup_result.cache_seen_utc
        else
            data_time_text = "rr-cache"
        end
    else
        local generated_utc = AutoBand.realmrank_generated_utc
        if generated_utc and generated_utc ~= "" then
            data_time_text = generated_utc
        else
            data_time_text = "unknown"
        end
    end

    local lookup_prefix = "Lookup RR: "
    if rr ~= nil then
        local rank_text = ""
        if level ~= nil then
            rank_text = rank_text .. online_color_text("CR" .. tostring(level) .. ",", AB_const.COLOR_SILVER, AB_const.COLOR_SILVER) .. " "
        end
        rank_text = rank_text .. online_color_text("RR" .. tostring(rr), AB_const.COLOR_SILVER, AB_const.COLOR_SILVER)
        AB_util.print(
            lookup_prefix ..
            lookup_name_text .. ": " ..
            rank_text .. " " ..
            online_color_text("(from " .. data_time_text .. ")", AB_const.COLOR_GRAY, AB_const.COLOR_GRAY)
        )
    else
        local miss_text = "not in CSV"
        if not loaded then
            miss_text = "CSV unavailable"
        end
        AB_util.print(
            lookup_prefix ..
            lookup_name_text .. ": " ..
            online_color_text(miss_text, AB_const.COLOR_ORANGE, AB_const.COLOR_WHITE) .. " " ..
            online_color_text("(from " .. data_time_text .. ")", AB_const.COLOR_GRAY, AB_const.COLOR_GRAY)
        )
    end
end

function AutoBand.cmd_rrcache(args)
    if type(AutoBand.get_realmrank_fallback_cache_summary) ~= "function" then
        AB_util.print("[Error] RR fallback cache inspection is unavailable in this build.")
        return
    end

    args = type(args) == "table" and args or {}
    local action = args[1]
    if action ~= nil then
        action = tostring(action)
        local ok_lower, lowered = pcall(string.lower, action)
        if ok_lower and lowered ~= nil then
            action = lowered
        end
    end

    local list_mode
    if action == "oldest" or action == "old" or action == "stale" then
        list_mode = "oldest"
    elseif action == "newest" or action == "new" or action == "fresh" then
        list_mode = "newest"
    elseif action == nil or action == "" or action == "summary" or action == "status" or action == "info" or action == "show" then
        list_mode = nil
    else
        rrcache_usage()
        return
    end

    local limit = rrcache_parse_limit(args[2])
    if limit == nil then
        rrcache_usage()
        return
    end

    local summary = AutoBand.get_realmrank_fallback_cache_summary(limit)
    if list_mode == nil then
        rrcache_print_summary(summary)
        return
    end

    rrcache_print_entries(summary, list_mode)
end

function AutoBand.cmd_rrrefresh(args)
    args = args or {}
    if #args > 0 then
        AB_util.print("Usage: /ab csvrefresh")
        return
    end

    if type(AutoBand.refresh_realmrank_cache) ~= "function" then
        AB_util.print("[Error] Realm-rank refresh is unavailable in this build.")
        return
    end

    local loaded, changed = AutoBand.refresh_realmrank_cache(true)
    if type(AutoBand.refresh_realmrank_ui_if_visible) == "function" then
        AutoBand.refresh_realmrank_ui_if_visible()
    end
    if loaded ~= true then
        AB_util.print("[Error] Realm-rank CSV refresh failed (" .. REALMRANK_CSV_FILE_NAME .. "). Is the poller running?")
        return
    end

    local generated_utc = AutoBand.realmrank_generated_utc
    if generated_utc == nil or generated_utc == "" then
        generated_utc = "unknown"
    end

    local stale_suffix = ""
    if AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
        stale_suffix = " [stale]"
    end

    local changed_text = "unchanged"
    if changed == true then
        changed_text = "updated"
    end

    AB_util.print(
        "Realm-rank CSV refreshed: " .. changed_text ..
        " (" .. tostring(AutoBand.realmrank_row_count or 0) .. " rows, " ..
        generated_utc .. stale_suffix .. ")."
    )
end

local function cmd_online_usage_with_groups(groups)
    AB_util.print("Usage: /ab online <group> | /ab online list | /ab online default <group|clear> | /ab online monitor ...")
    print_online_enemy_group_list(groups)
end

local function cmd_online_handle_default(args, groups)
    local default_arg = nil
    if #args >= 2 then
        default_arg = table.concat(args, " ", 2)
    end

    if not default_arg or default_arg == "" then
        local default_name = AutoBand.saved and AutoBand.saved.online_markgroup_default_name
        local default_key = AutoBand.saved and AutoBand.saved.online_markgroup_default_key
        if default_name and default_name ~= "" then
            AB_util.print("Online default markgroup: " .. default_name)
        elseif default_key and default_key ~= "" then
            AB_util.print("Online default markgroup key: " .. default_key)
        else
            AB_util.print("Online default markgroup is not set.")
        end
        return
    end

    local normalized_default_arg = normalize_online_group_key(default_arg)
    if normalized_default_arg == "clear" or normalized_default_arg == "none" or normalized_default_arg == "off" then
        clear_online_default_group()
        AB_util.print("Online default markgroup cleared.")
        return
    end

    if type(groups) ~= "table" or #groups == 0 then
        return
    end

    local group = find_online_enemy_group_by_key(groups, normalized_default_arg)
    if not group then
        AB_util.print("[Error] Enemy markgroup not found: " .. tostring(default_arg))
        print_online_enemy_group_list(groups)
        return
    end

    AutoBand.saved = AutoBand.saved or {}
    AutoBand.saved.online_markgroup_default_key = group.key
    AutoBand.saved.online_markgroup_default_name = group.name_s
    AB_util.print("Online default markgroup set to " .. online_color_text(group.name_s, group.color, AB_const.COLOR_SKY) .. ".")
end

local function cmd_online_resolve_query(args)
    local query = nil
    if #args > 0 then
        query = table.concat(args, " ")
    end
    if not query or query == "" then
        if AutoBand.saved and type(AutoBand.saved.online_markgroup_default_key) == "string" then
            query = AutoBand.saved.online_markgroup_default_key
        end
    end
    return query
end

local function cmd_online_print_group_report(groups, query)
    local query_key = normalize_online_group_key(query)
    local group = find_online_enemy_group_by_key(groups, query_key)
    if not group then
        AB_util.print("[Error] Enemy markgroup not found: " .. tostring(query))
        print_online_enemy_group_list(groups)
        return
    end

    local snapshot_state = get_cache_first_snapshot_state("check online members")
    if type(snapshot_state) ~= "table" then
        return
    end

    local display_lookup = snapshot_state.display_lookup
    local charid_lookup = snapshot_state.charid_lookup
    local level_lookup = snapshot_state.level_lookup
    local careerline_lookup = snapshot_state.careerline_lookup
    local careername_lookup = snapshot_state.careername_lookup
    local careericon_lookup = snapshot_state.careericon_lookup
    local faction_lookup = snapshot_state.faction_lookup
    local role_lookup = snapshot_state.role_lookup
    local matches = collect_online_group_matches(
        group,
        snapshot_state.online_lookup,
        display_lookup,
        level_lookup,
        careerline_lookup,
        charid_lookup,
        careername_lookup,
        careericon_lookup,
        faction_lookup,
        role_lookup,
        { include_enemy_killspam = true }
    )
    print_online_group_report(
        group.name_s,
        group.color,
        tonumber(group.member_count) or AB_util.size_table(group.members),
        matches
    )
end

-- Settings UI "List": prints the monitored groups from metadata only (no member
-- traversal); works without Enemy so stale monitors stay visible.
function AutoBand.print_online_monitor_summary()
    print_online_monitor_list(get_online_enemy_mark_groups({}))
end

-- Settings UI "Check now" for one markgroup key. The gate runs first: nothing is
-- collected or printed beyond the reason unless Enemy and fresh CSV are available.
function AutoBand.check_online_markgroup(key)
    local available, status, reason = false, "unavailable", "unavailable"
    if type(AutoBand.peek_online_markgroup_availability) == "function" then
        available, status, reason = AutoBand.peek_online_markgroup_availability()
    end
    if not available then
        AB_util.print("[Error] Unable to check online members: " .. tostring(reason))
        return false, status
    end
    local query_key = normalize_online_group_key(key)
    if not query_key then
        return false, "invalid"
    end
    cmd_online_print_group_report(get_online_enemy_mark_groups(), query_key)
    return true, "ok"
end

function AutoBand.cmd_online(args)
    args = args or {}
    local action = args[1] and tostring(args[1]):lower() or nil

    local groups = get_online_enemy_mark_groups()
    if action == "monitor" or action == "mon" then
        cmd_online_monitor(args, groups)
        if type(AutoBand.refresh_settings_ui) == "function" then
            AutoBand.refresh_settings_ui()
        end
        return
    end

    if groups == nil then
        -- Enemy addon not installed/initialized: command is optional and should
        -- quietly no-op without chat noise. Clearing a saved default still works.
        if action == "default" and #args >= 2 then
            local default_arg = normalize_online_group_key(table.concat(args, " ", 2))
            if default_arg == "clear" or default_arg == "none" or default_arg == "off" then
                cmd_online_handle_default(args, groups)
                if type(AutoBand.refresh_settings_ui) == "function" then
                    AutoBand.refresh_settings_ui()
                end
            end
        end
        return
    end

    if action == "list" or action == "groups" then
        print_online_enemy_group_list(groups)
        return
    end

    if action == "default" then
        cmd_online_handle_default(args, groups)
        if type(AutoBand.refresh_settings_ui) == "function" then
            AutoBand.refresh_settings_ui()
        end
        return
    end

    if type(groups) ~= "table" or #groups == 0 then
        return
    end

    local query = cmd_online_resolve_query(args)
    if not query or query == "" then
        cmd_online_usage_with_groups(groups)
        return
    end

    cmd_online_print_group_report(groups, query)
end

function AutoBand.cmd_friends(args)
    args = args or {}
    if #args > 0 then
        AB_util.print("Usage: /ab friends")
        return
    end

    local friends, friend_err = get_friend_list_entries()
    if type(friends) ~= "table" then
        AB_util.print("[Error] Unable to read friends list: " .. tostring(friend_err or "unavailable") .. ".")
        return
    end
    if #friends == 0 then
        AB_util.print("No friends found in your friends list.")
        return
    end

    local snapshot_state = get_cache_first_snapshot_state("check friends")
    if type(snapshot_state) ~= "table" then
        return
    end

    local display_lookup = snapshot_state.display_lookup
    local charid_lookup = snapshot_state.charid_lookup
    local level_lookup = snapshot_state.level_lookup
    local careerline_lookup = snapshot_state.careerline_lookup
    local careername_lookup = snapshot_state.careername_lookup or {}
    local careericon_lookup = snapshot_state.careericon_lookup or {}
    local faction_lookup = snapshot_state.faction_lookup or {}
    local role_lookup = snapshot_state.role_lookup or {}
    local matches = {}

    for i = 1, #friends do
        local friend = friends[i]
        local friend_key = friend and friend.key
        if friend_key then
            local rr_number = tonumber(snapshot_state.online_lookup[friend_key])
            if rr_number ~= nil then
                rr_number = math.floor(rr_number)
            end
            if rr_number ~= nil and rr_number >= 0 then
                local display_name = display_lookup[friend_key]
                if not display_name or display_name == "" then
                    display_name = friend.display_name or friend_key
                end
                local level = tonumber(level_lookup[friend_key])
                if level ~= nil then
                    level = math.floor(level)
                    if level < 0 then
                        level = nil
                    end
                end
                local career_line = tonumber(careerline_lookup[friend_key])
                if career_line ~= nil then
                    career_line = math.floor(career_line)
                    if career_line <= 0 then
                        career_line = nil
                    end
                end
                local character_id = nil
                if type(charid_lookup) == "table" then
                    character_id = tonumber(charid_lookup[friend_key])
                    if character_id ~= nil then
                        character_id = math.floor(character_id)
                        if character_id <= 0 then
                            character_id = nil
                        end
                    end
                end
                local career_name = nil
                if type(careername_lookup) == "table" then
                    career_name = tostring(careername_lookup[friend_key] or "")
                    if career_name == "" then
                        career_name = nil
                    end
                end
                local career_icon = nil
                if type(careericon_lookup) == "table" then
                    career_icon = tostring(careericon_lookup[friend_key] or "")
                    if career_icon == "" then
                        career_icon = nil
                    end
                end
                local faction = nil
                if type(faction_lookup) == "table" then
                    faction = tostring(faction_lookup[friend_key] or "")
                    if faction == "" then
                        faction = nil
                    end
                end
                local role = nil
                if type(role_lookup) == "table" then
                    role = tostring(role_lookup[friend_key] or "")
                    if role == "" then
                        role = nil
                    end
                end
                matches[#matches + 1] = {
                    key = friend_key,
                    display_name = display_name,
                    rr = rr_number,
                    level = level,
                    career_line = career_line,
                    character_id = character_id,
                    career_name = career_name,
                    career_icon = career_icon,
                    faction = faction,
                    role = role,
                }
            end
        end
    end

    sort_online_matches(matches)

    AB_util.print("Friends in RR CSV: " .. tostring(#matches) .. "/" .. tostring(#friends) .. " found.")

    print_online_snapshot_line()

    if #matches == 0 then
        return
    end

    print_online_match_chunks(matches, AB_const.COLOR_SKY)
end
