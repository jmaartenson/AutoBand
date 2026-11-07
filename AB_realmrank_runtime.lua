-- AB_realmrank_runtime.lua
-- Runtime update orchestration for realm-rank/online monitor systems.

if type(AutoBand) ~= "table" then
    AutoBand = {}
end

local rr_module = AutoBand._realmrank_module or {}
local rr_const = rr_module.const or {}
local rr_fn = rr_module.fn or {}

local REALMRANK_REFRESH_DEFAULT_SECONDS = rr_const.REALMRANK_REFRESH_DEFAULT_SECONDS or 300
local REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS = rr_const.REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS or 1800
local ONLINE_MONITOR_INTERVAL_SECONDS = rr_const.ONLINE_MONITOR_INTERVAL_SECONDS or 60
local ONLINE_MONITOR_STARTUP_DELAY_SECONDS = rr_const.ONLINE_MONITOR_STARTUP_DELAY_SECONDS or 10

local function is_realmrank_work_suspended_for_combat()
    if type(AutoBand.should_suspend_realmrank_refresh_for_combat) == "function" then
        return AutoBand.should_suspend_realmrank_refresh_for_combat() == true
    end
    return false
end

local function mark_combat_resume_deferred(key)
    if type(AutoBand.mark_combat_resume_deferred) == "function" then
        AutoBand.mark_combat_resume_deferred(key)
    end
end

local function clear_combat_resume_deferred(key)
    if type(AutoBand.clear_combat_resume_deferred) == "function" then
        AutoBand.clear_combat_resume_deferred(key)
    end
end

local function is_combat_resume_ready(key, elapsed)
    if type(AutoBand.is_combat_resume_ready) == "function" then
        return AutoBand.is_combat_resume_ready(key, elapsed)
    end
    return true
end

local function reset_realmstats_startup_runtime()
    AutoBand.realmstats_startup_pending = false
    AutoBand.realmstats_startup_announced = false
    AutoBand.realmstats_startup_delay_elapsed = 0
    AutoBand.realmstats_startup_has_csv = false
    AutoBand.realmstats_startup_force_attempted = false
    clear_combat_resume_deferred("realmstats_startup")
end

local function tick_realmstats_startup_delay(elapsed)
    if type(AutoBand.is_realmrank_soft_disabled) == "function" and AutoBand.is_realmrank_soft_disabled() then
        AutoBand.realmstats_startup_pending = false
        AutoBand.realmstats_startup_announced = false
        AutoBand.realmstats_startup_delay_elapsed = 0
        AutoBand.realmstats_startup_has_csv = false
        AutoBand.realmstats_startup_force_attempted = false
        clear_combat_resume_deferred("realmstats_startup")
        return
    end

    local stats_startup_waiting =
        AutoBand.saved and
        AutoBand.saved.realmstats_enabled == true and
        AutoBand.saved.realmrank_lookup_enabled == true and
        AutoBand.realmstats_startup_pending == true and
        AutoBand.realmstats_startup_announced ~= true
    if not stats_startup_waiting then
        clear_combat_resume_deferred("realmstats_startup")
        return
    end

    AutoBand.realmstats_startup_delay_elapsed = (AutoBand.realmstats_startup_delay_elapsed or 0) + elapsed
    if AutoBand.realmstats_startup_delay_elapsed < ONLINE_MONITOR_STARTUP_DELAY_SECONDS then
        return
    end
    if is_realmrank_work_suspended_for_combat() then
        AutoBand.realmstats_startup_delay_elapsed = ONLINE_MONITOR_STARTUP_DELAY_SECONDS
        mark_combat_resume_deferred("realmstats_startup")
        return
    end
    if not is_combat_resume_ready("realmstats_startup", elapsed) then
        return
    end
    if type(AutoBand.realmstats_try_emit_startup_if_ready) == "function" then
        AutoBand.realmstats_try_emit_startup_if_ready()
    end
end

local function maybe_report_realmstats_after_refresh(csv_fresh, csv_changed)
    if not (AutoBand.saved and AutoBand.saved.realmstats_enabled == true) then
        return
    end

    if AutoBand.realmstats_startup_pending == true and AutoBand.realmstats_startup_announced ~= true then
        if csv_fresh then
            AutoBand.realmstats_startup_has_csv = true
        end
        if not is_combat_resume_ready("realmstats_startup", 0) then
            return
        end
        if type(AutoBand.realmstats_try_emit_startup_if_ready) == "function" then
            AutoBand.realmstats_try_emit_startup_if_ready()
        end
        if AutoBand.realmstats_startup_pending ~= true and type(AutoBand.realmstats_maybe_report_shift) == "function" then
            AutoBand.realmstats_maybe_report_shift(csv_fresh, csv_changed)
        end
        return
    end

    if type(AutoBand.realmstats_maybe_report_shift) == "function" then
        AutoBand.realmstats_maybe_report_shift(csv_fresh, csv_changed)
    end
end

local function tick_realmrank_refresh(elapsed)
    if not (AutoBand.saved and AutoBand.saved.realmrank_lookup_enabled == true) then
        AutoBand.realmrank_refresh_elapsed = 0
        reset_realmstats_startup_runtime()
        clear_combat_resume_deferred("realmrank_refresh")
        return
    end

    if type(AutoBand.is_realmrank_soft_disabled) == "function" and AutoBand.is_realmrank_soft_disabled() then
        AutoBand.realmrank_refresh_elapsed = 0
        reset_realmstats_startup_runtime()
        clear_combat_resume_deferred("realmrank_refresh")
        return
    end

    local rr_refresh_interval = REALMRANK_REFRESH_DEFAULT_SECONDS
    if type(AutoBand.get_realmrank_refresh_interval_seconds) == "function" then
        rr_refresh_interval = AutoBand.get_realmrank_refresh_interval_seconds()
    end
    local csv_auto_suppressed =
        type(AutoBand.is_realmrank_csv_auto_refresh_suppressed) == "function" and
        AutoBand.is_realmrank_csv_auto_refresh_suppressed() == true
    local effective_refresh_interval = rr_refresh_interval
    if csv_auto_suppressed and effective_refresh_interval < REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS then
        effective_refresh_interval = REALMRANK_MISSING_CSV_AUTO_RETRY_SECONDS
    end

    AutoBand.realmrank_refresh_elapsed = (AutoBand.realmrank_refresh_elapsed or 0) + elapsed
    if AutoBand.realmrank_refresh_elapsed < effective_refresh_interval then
        return
    end

    if is_realmrank_work_suspended_for_combat() then
        AutoBand.realmrank_refresh_elapsed = effective_refresh_interval
        mark_combat_resume_deferred("realmrank_refresh")
        return
    end

    if not is_combat_resume_ready("realmrank_refresh", elapsed) then
        AutoBand.realmrank_refresh_elapsed = effective_refresh_interval
        return
    end

    AutoBand.realmrank_refresh_elapsed = 0
    local csv_loaded, csv_changed = AutoBand.refresh_realmrank_cache(csv_auto_suppressed)
    local csv_fresh = csv_loaded == true
    if csv_fresh and AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
        csv_fresh = false
    end
    if type(AutoBand.refresh_realmrank_ui_if_visible) == "function" then
        AutoBand.refresh_realmrank_ui_if_visible()
    end
    maybe_report_realmstats_after_refresh(csv_fresh, csv_changed)

    if AutoBand.cleanup_realmrank_fallback_cache then
        AutoBand.cleanup_realmrank_fallback_cache(false)
    end
end

local function tick_online_monitor_runtime(elapsed)
    local has_online_monitors =
        type(AutoBand.online_monitor_groups) == "table" and
        next(AutoBand.online_monitor_groups) ~= nil
    if not has_online_monitors then
        AutoBand.online_monitor_elapsed = 0
        AutoBand.online_monitor_startup_delay_elapsed = 0
        clear_combat_resume_deferred("online_monitor_startup")
        clear_combat_resume_deferred("online_monitor_tick")
        return
    end

    local enemy_templates_ready = false
    if type(AutoBand.has_online_enemy_templates) == "function" then
        enemy_templates_ready = AutoBand.has_online_enemy_templates() == true
    end
    if not enemy_templates_ready then
        AutoBand.online_monitor_elapsed = 0
        AutoBand.online_monitor_startup_pending = false
        AutoBand.online_monitor_startup_announced = true
        AutoBand.online_monitor_startup_delay_elapsed = 0
        clear_combat_resume_deferred("online_monitor_startup")
        clear_combat_resume_deferred("online_monitor_tick")
        return
    end

    if AutoBand.online_monitor_startup_pending == true and AutoBand.online_monitor_startup_announced ~= true then
        AutoBand.online_monitor_startup_delay_elapsed = (AutoBand.online_monitor_startup_delay_elapsed or 0) + elapsed
        if AutoBand.online_monitor_startup_delay_elapsed >= ONLINE_MONITOR_STARTUP_DELAY_SECONDS then
            if is_realmrank_work_suspended_for_combat() then
                AutoBand.online_monitor_startup_delay_elapsed = ONLINE_MONITOR_STARTUP_DELAY_SECONDS
                mark_combat_resume_deferred("online_monitor_startup")
            elseif not is_combat_resume_ready("online_monitor_startup", elapsed) then
                return
            else
                local startup_printed = false
                if type(rr_fn.try_emit_online_monitor_startup_state) == "function" then
                    startup_printed = rr_fn.try_emit_online_monitor_startup_state() == true
                elseif type(AutoBand.try_emit_online_monitor_startup_state) == "function" then
                    startup_printed = AutoBand.try_emit_online_monitor_startup_state() == true
                end
                if startup_printed then
                    AutoBand.online_monitor_startup_delay_elapsed = 0
                else
                    AutoBand.online_monitor_startup_delay_elapsed = ONLINE_MONITOR_STARTUP_DELAY_SECONDS
                end
            end
        end
    end

    AutoBand.online_monitor_elapsed = (AutoBand.online_monitor_elapsed or 0) + elapsed
    if AutoBand.online_monitor_elapsed < ONLINE_MONITOR_INTERVAL_SECONDS then
        return
    end

    if is_realmrank_work_suspended_for_combat() then
        AutoBand.online_monitor_elapsed = ONLINE_MONITOR_INTERVAL_SECONDS
        mark_combat_resume_deferred("online_monitor_tick")
        return
    end

    if not is_combat_resume_ready("online_monitor_tick", elapsed) then
        AutoBand.online_monitor_elapsed = ONLINE_MONITOR_INTERVAL_SECONDS
        return
    end

    AutoBand.online_monitor_elapsed = 0
    if type(rr_fn.run_online_monitor_tick) == "function" then
        rr_fn.run_online_monitor_tick()
    elseif type(AutoBand.run_online_monitor_tick) == "function" then
        AutoBand.run_online_monitor_tick()
    end
end

function AutoBand.realmrank_handle_world_entry()
    if type(AutoBand.ensure_online_monitor_runtime) == "function" then
        AutoBand.ensure_online_monitor_runtime()
    end
    if type(AutoBand.ensure_realmstats_startup_runtime) == "function" then
        AutoBand.ensure_realmstats_startup_runtime()
    end

    local suppress_monitor_rearm =
        AutoBand.online_monitor_startup_announced == true and
        type(AutoBand.online_monitor_state) == "table" and
        next(AutoBand.online_monitor_state) ~= nil

    if not suppress_monitor_rearm then
        local monitor_count = 0
        if type(AutoBand.get_online_monitor_count) == "function" then
            monitor_count = tonumber(AutoBand.get_online_monitor_count()) or 0
        end
        local enemy_templates_ready = false
        if type(AutoBand.has_online_enemy_templates) == "function" then
            enemy_templates_ready = AutoBand.has_online_enemy_templates() == true
        end
        if monitor_count > 0 and enemy_templates_ready then
            AutoBand.online_monitor_startup_pending = true
            AutoBand.online_monitor_startup_announced = false
            AutoBand.online_monitor_startup_delay_elapsed = 0
            clear_combat_resume_deferred("online_monitor_startup")
        else
            AutoBand.online_monitor_startup_pending = false
            AutoBand.online_monitor_startup_announced = false
            AutoBand.online_monitor_startup_delay_elapsed = 0
            clear_combat_resume_deferred("online_monitor_startup")
        end
    end

    local realmstats_can_start =
        AutoBand.saved and
        AutoBand.saved.realmstats_enabled == true and
        AutoBand.saved.realmrank_lookup_enabled == true and
        (type(AutoBand.is_realmrank_soft_disabled) ~= "function" or AutoBand.is_realmrank_soft_disabled() ~= true)
    local realmstats_already_announced =
        AutoBand.realmstats_startup_announced == true and
        type(AutoBand.realmstats_last_auto_snapshot) == "table"

    if realmstats_can_start and not realmstats_already_announced then
        AutoBand.realmstats_startup_pending = true
        AutoBand.realmstats_startup_announced = false
        AutoBand.realmstats_startup_delay_elapsed = 0
        AutoBand.realmstats_startup_has_csv = false
        AutoBand.realmstats_startup_force_attempted = false
        AutoBand.realmstats_last_auto_snapshot = nil
        AutoBand.realmstats_last_auto_report_uptime_s = nil
        clear_combat_resume_deferred("realmstats_startup")
    elseif not realmstats_can_start then
        AutoBand.realmstats_startup_pending = false
        AutoBand.realmstats_startup_announced = false
        AutoBand.realmstats_startup_delay_elapsed = 0
        AutoBand.realmstats_startup_has_csv = false
        AutoBand.realmstats_startup_force_attempted = false
        AutoBand.realmstats_last_auto_snapshot = nil
        AutoBand.realmstats_last_auto_report_uptime_s = nil
        clear_combat_resume_deferred("realmstats_startup")
    end

    local should_seed_startup_snapshot =
        AutoBand.saved and
        AutoBand.saved.realmrank_lookup_enabled == true and
        (type(AutoBand.is_realmrank_soft_disabled) ~= "function" or AutoBand.is_realmrank_soft_disabled() ~= true) and
        (
            AutoBand.online_monitor_startup_pending == true or
            AutoBand.realmstats_startup_pending == true
        )
    if should_seed_startup_snapshot and
       (type(AutoBand.has_realmrank_snapshot_rows) ~= "function" or AutoBand.has_realmrank_snapshot_rows() ~= true) and
       (type(AutoBand.is_realmrank_csv_auto_refresh_suppressed) ~= "function" or AutoBand.is_realmrank_csv_auto_refresh_suppressed() ~= true) and
       (type(AutoBand.should_suspend_realmrank_refresh_for_combat) ~= "function" or AutoBand.should_suspend_realmrank_refresh_for_combat() ~= true) and
       type(AutoBand.refresh_realmrank_cache) == "function" then
        local seeded = AutoBand.refresh_realmrank_cache(true) == true
        if seeded and AutoBand.is_realmrank_data_stale and AutoBand.is_realmrank_data_stale() then
            seeded = false
        end
        if AutoBand.realmstats_startup_pending == true then
            AutoBand.realmstats_startup_has_csv = seeded == true
        end
    end
end

-- Runtime tick entrypoint. Keep ordering stable: stats startup, CSV refresh, monitor tick.
function AutoBand.realmrank_update_runtime(elapsed)
    tick_realmstats_startup_delay(elapsed)
    tick_realmrank_refresh(elapsed)
    tick_online_monitor_runtime(elapsed)
end
