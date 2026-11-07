-- AB_stats_runtime.lua
-- Startup and monitor-shift runtime behavior for /ab stats.
-- Automatic reports maintain their own last_auto_* baseline separate from
-- manual /ab stats reads so each path can report elapsed time independently.

if type(AutoBand) ~= "table" then
    AutoBand = {}
end

local stats_module = AutoBand._realmstats_module or {}
local stats_const = stats_module.const or {}
local stats_fn = stats_module.fn or {}

local ONLINE_MONITOR_STARTUP_DELAY_SECONDS = stats_const.ONLINE_MONITOR_STARTUP_DELAY_SECONDS or 10
local REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT = stats_const.REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT or 2

local ensure_realmstats_startup_runtime = stats_fn.ensure_realmstats_startup_runtime
local realmstats_reset_startup_runtime = stats_fn.realmstats_reset_startup_runtime
local realmstats_copy_snapshot = stats_fn.realmstats_copy_snapshot
local realmstats_print_snapshot = stats_fn.realmstats_print_snapshot
local realmstats_get_shift_threshold_percent = stats_fn.realmstats_get_shift_threshold_percent
local realmstats_collect_shift_report = stats_fn.realmstats_collect_shift_report
local realmstats_get_report_uptime_seconds = stats_fn.realmstats_get_report_uptime_seconds
local realmstats_format_elapsed_since_uptime = stats_fn.realmstats_format_elapsed_since_uptime
local realmstats_format_threshold_percent = stats_fn.realmstats_format_threshold_percent
local realmstats_print_delta_report = stats_fn.realmstats_print_delta_report

if type(ensure_realmstats_startup_runtime) ~= "function" then
    ensure_realmstats_startup_runtime = function() end
end
if type(realmstats_reset_startup_runtime) ~= "function" then
    realmstats_reset_startup_runtime = function(_announced) end
end
if type(realmstats_copy_snapshot) ~= "function" then
    realmstats_copy_snapshot = function(snapshot)
        return snapshot
    end
end
if type(realmstats_print_snapshot) ~= "function" then
    realmstats_print_snapshot = function(_snapshot, _opts) end
end
if type(realmstats_get_shift_threshold_percent) ~= "function" then
    realmstats_get_shift_threshold_percent = function()
        return REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT
    end
end
if type(realmstats_collect_shift_report) ~= "function" then
    realmstats_collect_shift_report = function(_current, _previous, _threshold)
        return 0, {}
    end
end
if type(realmstats_get_report_uptime_seconds) ~= "function" then
    realmstats_get_report_uptime_seconds = function()
        return nil
    end
end
if type(realmstats_format_elapsed_since_uptime) ~= "function" then
    realmstats_format_elapsed_since_uptime = function(_previous_uptime_s, _current_uptime_s)
        return nil
    end
end
if type(realmstats_format_threshold_percent) ~= "function" then
    realmstats_format_threshold_percent = function(value)
        return tostring(value or REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT) .. "%"
    end
end
if type(realmstats_print_delta_report) ~= "function" then
    realmstats_print_delta_report = function(_current, _previous, _opts)
        return false
    end
end

local function realmstats_maybe_emit_initial_report(csv_loaded)
    if not AutoBand.saved or AutoBand.saved.realmstats_enabled ~= true then
        return false
    end
    if csv_loaded ~= true then
        return false
    end
    if AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
        return false
    end

    local snapshot = AutoBand.realmstats_snapshot
    if type(snapshot) ~= "table" or type(snapshot.overall) ~= "table" then
        return false
    end
    if type(AutoBand.realmstats_last_auto_snapshot) == "table" then
        return false
    end

    realmstats_print_snapshot(snapshot, { include_snapshot_row = false })
    AutoBand.realmstats_last_auto_snapshot = realmstats_copy_snapshot(snapshot)
    AutoBand.realmstats_last_auto_report_uptime_s = realmstats_get_report_uptime_seconds()
    return true
end

local function realmstats_try_emit_startup_if_ready()
    ensure_realmstats_startup_runtime()

    if type(AutoBand.is_realmrank_soft_disabled) == "function" and AutoBand.is_realmrank_soft_disabled() then
        realmstats_reset_startup_runtime(false)
        return false
    end

    if AutoBand.realmstats_startup_pending ~= true or AutoBand.realmstats_startup_announced == true then
        return false
    end
    if (AutoBand.realmstats_startup_delay_elapsed or 0) < ONLINE_MONITOR_STARTUP_DELAY_SECONDS then
        return false
    end

    if AutoBand.should_suspend_realmrank_refresh_for_combat and AutoBand.should_suspend_realmrank_refresh_for_combat() then
        AutoBand.realmstats_startup_delay_elapsed = ONLINE_MONITOR_STARTUP_DELAY_SECONDS
        return false
    end

    local csv_loaded = AutoBand.realmstats_startup_has_csv == true
    if not csv_loaded and AutoBand.realmstats_startup_force_attempted ~= true then
        if type(AutoBand.refresh_realmrank_cache) == "function" then
            csv_loaded = AutoBand.refresh_realmrank_cache(true) == true
            if csv_loaded and AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
                csv_loaded = false
            end
        end
        AutoBand.realmstats_startup_has_csv = csv_loaded == true
        AutoBand.realmstats_startup_force_attempted = true
    end

    local startup_printed = realmstats_maybe_emit_initial_report(csv_loaded == true)
    if startup_printed then
        realmstats_reset_startup_runtime(true)
        return true
    end

    return false
end

local function realmstats_maybe_report_shift(csv_loaded, csv_changed)
    if not AutoBand.saved or AutoBand.saved.realmstats_enabled ~= true then
        return
    end
    if csv_loaded ~= true then
        return
    end
    if AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
        return
    end

    local snapshot = AutoBand.realmstats_snapshot
    if type(snapshot) ~= "table" or type(snapshot.overall) ~= "table" then
        return
    end

    if type(AutoBand.realmstats_last_auto_snapshot) ~= "table" then
        AutoBand.realmstats_last_auto_snapshot = realmstats_copy_snapshot(snapshot)
        AutoBand.realmstats_last_auto_report_uptime_s = realmstats_get_report_uptime_seconds()
        return
    end

    if csv_changed ~= true then
        return
    end

    local threshold = realmstats_get_shift_threshold_percent()
    local max_shift, triggered_shifts = realmstats_collect_shift_report(snapshot, AutoBand.realmstats_last_auto_snapshot, threshold)
    if max_shift > threshold then
        local report_uptime_s = realmstats_get_report_uptime_seconds()
        local elapsed_text = realmstats_format_elapsed_since_uptime(
            AutoBand.realmstats_last_auto_report_uptime_s,
            report_uptime_s
        )
        local header = "Realm stats shift > " .. realmstats_format_threshold_percent(threshold) .. " since last report"
        if elapsed_text ~= nil then
            header = header .. " (" .. elapsed_text .. ")"
        end
        AB_util.print(header .. ":")
        if type(triggered_shifts) == "table" and #triggered_shifts > 0 then
            AB_util.print("Detected: " .. table.concat(triggered_shifts, "; "))
        end
        realmstats_print_snapshot(snapshot, { include_snapshot_row = true })
        realmstats_print_delta_report(snapshot, AutoBand.realmstats_last_auto_snapshot, {
            header_label = "Since last realm stats report",
            previous_report_uptime_s = AutoBand.realmstats_last_auto_report_uptime_s,
            current_report_uptime_s = report_uptime_s,
        })
        AutoBand.realmstats_last_auto_snapshot = realmstats_copy_snapshot(snapshot)
        AutoBand.realmstats_last_auto_report_uptime_s = report_uptime_s
    end
end

AutoBand.realmstats_try_emit_startup_if_ready = realmstats_try_emit_startup_if_ready
AutoBand.realmstats_maybe_report_shift = realmstats_maybe_report_shift
