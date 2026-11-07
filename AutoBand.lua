-- AutoBand.lua

AutoBand = { previous_instance = type(AutoBand) == "table" and AutoBand or nil }
AutoBand.command_definition_hooks = {}
tanks_t_old = {}
healers_t_old = {}
dps_t_old = {}
mdps_t_old = {}
rdps_t_old = {}
roles_last = {}
toofar = {}
toofar_old = {}
toofar_not_changed = {}
warned = {}
ab_auto_note_counter = 12
AutoBand.CareerLineToNameMap = {}
AutoBand.original_add_group_menu_items = AutoBand.previous_instance and AutoBand.previous_instance.original_add_group_menu_items or nil
AutoBand.original_show_menu = AutoBand.previous_instance and AutoBand.previous_instance.original_show_menu or nil
AutoBand.original_playerwindow_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.original_playerwindow_leave_group or nil
AutoBand.original_groupwindow_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.original_groupwindow_leave_group or nil
AutoBand.original_battlegrouphud_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.original_battlegrouphud_leave_group or nil
AutoBand.previous_modified_show_menu = AutoBand.previous_instance and AutoBand.previous_instance.ModifiedShowMenu or nil
AutoBand.previous_modified_add_group_menu_items = AutoBand.previous_instance and AutoBand.previous_instance.ModifiedAddGroupMenuItems or nil
AutoBand.previous_playerwindow_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.OnPlayerWindowLeaveGroup or nil
AutoBand.previous_groupwindow_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.OnGroupWindowLeaveGroup or nil
AutoBand.previous_battlegrouphud_leave_group = AutoBand.previous_instance and AutoBand.previous_instance.OnBattlegroupHUDLeaveGroup or nil
AutoBand.previous_instance = nil
AutoBand.right_clicked_player_name = nil

local AVAILABLE_COLORS = AB_const.AVAILABLE_COLORS
local MAX_MAP_POINTS = 511
local DISTANCE_FIX_COEFFICIENT = 1 / 1.06
local MapPointTypeFilter = {
    [SystemData.MapPips.PLAYER] = true,
    [SystemData.MapPips.GROUP_MEMBER] = true,
    [SystemData.MapPips.WARBAND_MEMBER] = true,
    [SystemData.MapPips.DESTRUCTION_ARMY] = true,
    [SystemData.MapPips.ORDER_ARMY] = true
}
local PARTYNOTE_SUPPRESS_SECONDS = 10
local PARTYNOTE_IN_COMBAT_SECONDS = 30
local PARTYNOTE_VERIFY_SECONDS = 30
local PARTYNOTE_OPENPARTY_VERIFY_TIMEOUT_SECONDS = 10
local PARTYNOTE_SUPPRESS_TICKS = math.ceil(PARTYNOTE_SUPPRESS_SECONDS / AB_const.HEARTBEAT)
local PARTYNOTE_IN_COMBAT_TICKS = math.ceil(PARTYNOTE_IN_COMBAT_SECONDS / AB_const.HEARTBEAT)
local PARTYNOTE_VERIFY_TICKS = math.ceil(PARTYNOTE_VERIFY_SECONDS / AB_const.HEARTBEAT)
local PARTYNOTE_OPENPARTY_VERIFY_TIMEOUT_TICKS =
    math.max(1, math.ceil(PARTYNOTE_OPENPARTY_VERIFY_TIMEOUT_SECONDS / AB_const.HEARTBEAT))
local PARTYNOTE_MAX_LEN = 69
local ALT_SPEC_PROBE_SECONDS = 10
-- Social list snapshots are event-driven. The autokick loop reuses the
-- normalized sets below and only refreshes them on first use, after relevant
-- social/guild events, or after a throttled retry when the client returned
-- nil/false-empty data.
local AB_SOCIAL_LIST_BOOTSTRAP_REFRESH_SECONDS = 5
local AB_SOCIAL_LIST_BOOTSTRAP_MAX_ATTEMPTS = 12
local AB_SOCIAL_LIST_BACKGROUND_REFRESH_SECONDS = 60
local AB_SOCIAL_LIST_CACHE_GRACE_SECONDS = 60
local AB_SOCIAL_LIST_CACHE_GRACE_READS = 12
local AB_SOCIAL_LIST_RETRY_SECONDS = 15
local AB_WBLEADERS_BACKGROUND_REFRESH_SECONDS = 60
local AB_WBLEADER_TELL_ALERT_HIGHLIGHT_SECONDS = 8
AutoBand.COMBAT_RESUME_JITTER_MAX_SECONDS = 15
local ROLE_UPDATE_INTERVAL = 1
local ARRIVAL_SEED_MAX_ATTEMPTS = 5
local FORM_WARBAND_DELAY_TICKS = 10
local BACKFILL_ROUTE_STATUS_MAX_ENTRIES = 6
local ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS = 2
local PREFIX_LINK_DATA_OPEN_GUI = "AUTOBAND_PREFIX_OPEN_GUI"
local KILLBOARD_LINK_DATA_TAG = "AUTOBAND_KILLBOARD_CHAR"
local KILLBOARD_CHARACTER_URL_PREFIX = "https://killboard.returnofreckoning.com/character/"
local STATS_GRAPH_LINK_DATA_TAG = "AUTOBAND_STATS_GRAPH"
local STATS_GRAPH_URL = "https://maartenson.net/ror_graph.html"
local COPY_LINK_WINDOW_NAME = "AutoBandCopyLinkWindow"

local function BuildMapPointLookup()
    local lookup = {}
    for i = 1, MAX_MAP_POINTS do
        local mpd = GetMapPointData("EA_Window_OverheadMapMapDisplay", i)
        if mpd and MapPointTypeFilter[mpd.pointType] and mpd.name then
            local fixed = AutoBand.FixString(mpd.name)
            if fixed then
                lookup[fixed] = mpd
            end
        end
    end

    return lookup
end

local function clear_partynote_live_verify_state()
    AutoBand.pending_partynote_live_verify = false
    AutoBand.pending_partynote_live_verify_ticks = 0
end

-- Gate expensive partynote refresh work behind meaningful roster/settings/listing changes.
local function mark_partynote_dirty()
    AutoBand.partynote_state_dirty = true
end

function AutoBand.random_combat_resume_delay(max_seconds)
    local max_delay = tonumber(max_seconds)
    if max_delay == nil then
        max_delay = tonumber(AutoBand.COMBAT_RESUME_JITTER_MAX_SECONDS) or 15
    end
    if max_delay <= 0 then
        return 0
    end
    if type(math) == "table" and type(math.random) == "function" then
        local ok_random, raw_random = pcall(math.random)
        raw_random = ok_random and tonumber(raw_random) or nil
        if raw_random ~= nil then
            if raw_random < 0 then
                raw_random = 0
            elseif raw_random > 1 then
                raw_random = raw_random - math.floor(raw_random)
            end
            return raw_random * max_delay
        end
    end
    return 0
end

function AutoBand.clear_combat_resume_deferred(key)
    if type(key) ~= "string" or key == "" then
        return
    end
    if type(AutoBand.combat_resume_waits) == "table" then
        AutoBand.combat_resume_waits[key] = nil
    end
end

function AutoBand.mark_combat_resume_deferred(key)
    if type(key) ~= "string" or key == "" then
        return
    end
    if type(AutoBand.combat_resume_waits) ~= "table" then
        AutoBand.combat_resume_waits = {}
    end
    AutoBand.combat_resume_waits[key] = false
end

function AutoBand.is_combat_resume_ready(key, elapsed, max_seconds)
    if type(key) ~= "string" or key == "" then
        return true
    end

    local wait_remaining = AutoBand.combat_resume_waits
    if type(wait_remaining) ~= "table" or wait_remaining[key] == nil then
        return true
    end
    local remaining = tonumber(wait_remaining[key])
    if remaining == nil then
        remaining = AutoBand.random_combat_resume_delay(max_seconds)
    end

    local tick_elapsed = tonumber(elapsed) or 0
    if tick_elapsed < 0 then
        tick_elapsed = 0
    end
    remaining = remaining - tick_elapsed
    if remaining <= 0 then
        AutoBand.clear_combat_resume_deferred(key)
        return true
    end

    wait_remaining[key] = remaining
    return false
end

local function ab_register_optional_event_handler(event_name, handler_name)
    if type(RegisterEventHandler) ~= "function" then
        return false
    end
    if not (SystemData and SystemData.Events) then
        return false
    end

    local event_id = SystemData.Events[event_name]
    if event_id == nil then
        return false
    end

    local ok_register = pcall(RegisterEventHandler, event_id, handler_name)
    return ok_register == true
end

local function ab_unregister_optional_event_handler(event_name, handler_name)
    if type(UnregisterEventHandler) ~= "function" then
        return false
    end
    if not (SystemData and SystemData.Events) then
        return false
    end

    local event_id = SystemData.Events[event_name]
    if event_id == nil then
        return false
    end

    local ok_unregister = pcall(UnregisterEventHandler, event_id, handler_name)
    return ok_unregister == true
end

local AB_PLAYER_STATE_EVENT_HANDLERS = {
    { event = "ENTER_WORLD", handler = "AutoBand.OnPlayerEnteringWorldOrReload" },
    { event = "INTERFACE_RELOADED", handler = "AutoBand.OnPlayerEnteringWorldOrReload" },
}

local AB_WARBAND_EVENT_HANDLERS = {
    { event = "LOADING_BEGIN", handler = "AutoBand.zonevote_reset_sor" },
    { event = "GROUP_LEAVE", handler = "AutoBand.OnGroupLeave" },
    { event = "GROUP_UPDATED", handler = "AutoBand.OnBattleGroupDataChanged" },
    { event = "BATTLEGROUP_UPDATED", handler = "AutoBand.OnBattleGroupDataChanged" },
    { event = "SOCIAL_OPENPARTY_UPDATED", handler = "AutoBand.OnOpenPartyUpdated" },
    { event = "SOCIAL_FRIENDS_UPDATED", handler = "AutoBand.OnSocialFriendsUpdated" },
    { event = "SOCIAL_IGNORE_UPDATED", handler = "AutoBand.OnSocialIgnoreUpdated" },
    { event = "GUILD_REFRESH", handler = "AutoBand.OnGuildMembershipUpdated" },
    { event = "GUILD_INFO_UPDATED", handler = "AutoBand.OnGuildMembershipUpdated" },
    { event = "GUILD_ROSTER_INIT", handler = "AutoBand.OnGuildMembershipUpdated" },
    { event = "GUILD_MEMBER_UPDATED", handler = "AutoBand.OnGuildMembershipUpdated" },
    { event = "GUILD_MEMBER_ADDED", handler = "AutoBand.OnGuildMembershipUpdated" },
    { event = "GUILD_MEMBER_REMOVED", handler = "AutoBand.OnGuildMembershipUpdated" },
}

local AB_WBLEADER_TELL_EVENT_HANDLER = {
    event = "CHAT_TEXT_ARRIVED",
    handler = "AutoBand.OnWBLeaderTellChatText"
}

local AB_WARBAND_MUTATING_COMMANDS = {
    apply = true,
    kf = true,
    searchroles = true,
    searchrole = true,
    sr = true,
    zonekick = true,
    zk = true,
    rankkick = true,
    org = true,
    ["end"] = true,
}

function AutoBand.init()
    --------------------------------------------------------------------------
    -- 1) MODULE VARIABLES
    --------------------------------------------------------------------------
    AutoBand.allow_guild_prefix_override = false
    AutoBand.cache_dirty                 = true
    AutoBand.cached_wb                   = nil
    AutoBand.cmd_queue                   = {}
    AutoBand.cmd_current                 = nil
    AutoBand.current_purpose             = nil
    AutoBand.debugon                     = false
    AutoBand.elapsed                     = 0
    AutoBand.combat_resume_waits         = {}
    AutoBand.social_list_bootstrap_pending = false
    AutoBand.social_list_bootstrap_elapsed = 0
    AutoBand.social_list_bootstrap_attempts = 0
    AutoBand.social_list_bootstrap_targets = nil
    AutoBand.social_list_refresh_elapsed = 0
    AutoBand.wbleaders_background_refresh_elapsed = 0
    AutoBand.wbleader_tell_event_registered = false
    AutoBand.wbleader_tell_alert_highlight_remaining = 0
    if type(AutoBand.zonevote_reset_state) == "function" then
        AutoBand.zonevote_reset_state()
    end
    AutoBand.inWarband                   = false
    AutoBand.was_wb_leader               = false
    AutoBand.last_wb_leader_name_lower   = nil
    AutoBand.last_wb_player_count        = 0
    AutoBand.wb_roster_signature         = nil
    AutoBand.wb_roster_snapshot_lookup   = {}
    AutoBand.wb_roster_snapshot_count    = 0
    AutoBand.wb_roster_snapshot_stamp    = 0
    AutoBand.wb_roster_generation        = 0
    AutoBand.alt_spec_signature          = nil
    AutoBand.alt_spec_snapshot_lookup    = {}
    AutoBand.alt_spec_snapshot_count     = 0
    AutoBand.alt_spec_snapshot_stamp     = 0
    AutoBand.alt_spec_snapshot_signature = ""
    AutoBand.alt_spec_snapshot_generation = 0
    AutoBand.alt_spec_snapshot_dirty     = true
    AutoBand.alt_spec_snapshot_next_probe_s = nil
    AutoBand.suppressRoleNotifs          = false
    AutoBand.suppressCounter             = 0
    AutoBand.role_update_elapsed         = 0
    AutoBand.faction                     = nil
    AutoBand.factionDetermined           = false
    AutoBand.gizilon                     = false
    AutoBand.has_shortslash              = false
    AutoBand.live_org_verbose            = false
    AutoBand.need_role_update            = false
    AutoBand.player_career_line_for_race = nil
    AutoBand.player_career_line_for_role = nil
    AutoBand.race                        = nil
    AutoBand.raceDetermined              = false
    AutoBand.role                        = nil
    AutoBand.roleDetermined              = false
    AutoBand.pending_search_roles_args   = nil
    AutoBand.pending_search_roles_delay  = 0
    AutoBand.pending_search_roles_attempts = 0
    AutoBand.party_note_last_text        = nil
    AutoBand.party_note_last_roster_signature = nil
    AutoBand.party_note_last_alt_signature = nil
    AutoBand.party_note_last_sent_ticks  = PARTYNOTE_SUPPRESS_TICKS
    AutoBand.party_note_last_check_ticks = PARTYNOTE_VERIFY_TICKS
    AutoBand.pending_partynote_refresh   = 0
    AutoBand.force_partynote_refresh     = false
    AutoBand.partynote_state_dirty       = true
    clear_partynote_live_verify_state()
    AutoBand.pending_group_leave_broadcast = nil
    AutoBand.pending_arrival_seed        = false
    AutoBand.pending_arrival_seed_attempts = 0
    AutoBand.wb_arrival_order            = {}
    AutoBand.wb_arrival_lookup           = {}
    AutoBand.wb_arrival_meta             = {}
    AutoBand.backfill_notice_state       = {}
    AutoBand.social_list_cache           = {}
    AutoBand.rank_requirement_grace_until_s = nil
    AutoBand.rank_requirement_grace_ticks_remaining = 0
    AutoBand.social_priority_grace_until_s = nil
    AutoBand.social_priority_grace_ticks_remaining = 0
    AutoBand.template_active_key         = AB_const.EMPTY_TEMPLATE
    AutoBand.chat_hyperlink_handler_installed = false
    AutoBand.chat_hyperlink_original_lbutton_up = nil
    AutoBand.copy_link_window_initialized = false
    AutoBand.player_state_events_registered = false
    AutoBand.warband_events_registered = false
    AutoBand.pm_block_dropped_count      = 0
    AutoBand.pm_block_notice_shown       = false
    if type(AutoBand.realmrank_init_runtime_state) == "function" then
        AutoBand.realmrank_init_runtime_state()
    end
    if type(AutoBand.realmstats_init_runtime_state) == "function" then
        AutoBand.realmstats_init_runtime_state()
    end

--------------------------------------------------------------------------
-- 2) PERSISTENT SETTINGS
--------------------------------------------------------------------------
    -- A) CORE "SAVED" TABLE & CUSTOM ROLES
    AutoBand.saved               = AutoBand.saved or {}
    AutoBand.saved.custom_roles  = AutoBand.saved.custom_roles or {}
    if AutoBand.saved.wbleader_min_members == nil then
        AutoBand.saved.wbleader_min_members = 6
    end
    if AutoBand.saved.wbleader_notify_enabled == nil then
        AutoBand.saved.wbleader_notify_enabled = false
    end
    if AutoBand.saved.wbleader_tell_alert_enabled == nil then
        AutoBand.saved.wbleader_tell_alert_enabled = false
    end
    if type(AutoBand.saved.wbleader_min_members) ~= "number" or
       AutoBand.saved.wbleader_min_members < 1 or AutoBand.saved.wbleader_min_members > 24 then
        AB_util.print("[Warning] Saved WB lead minimum member count was invalid. Resetting to 6.")
        AutoBand.saved.wbleader_min_members = 6
    else
        AutoBand.saved.wbleader_min_members = math.floor(AutoBand.saved.wbleader_min_members)
    end

    -- A.1) ROLE COMPOSITION LIMITS
    AutoBand.saved.max_tanks   = AutoBand.saved.max_tanks   or AB_const.DEFAULT_MAX_TANKS
    AutoBand.saved.max_healers = AutoBand.saved.max_healers or AB_const.DEFAULT_MAX_HEALERS
    AutoBand.saved.max_dps     = AutoBand.saved.max_dps     or AB_const.DEFAULT_MAX_DPS

    -- Validate that loaded/default roles add up to 24
    if AutoBand.saved.max_tanks + AutoBand.saved.max_healers + AutoBand.saved.max_dps ~= 24 then
        AB_util.print("[Warning] Saved role counts did not sum to 24. Resetting to defaults (" .. AB_const.DEFAULT_MAX_TANKS .. "-" .. AB_const.DEFAULT_MAX_HEALERS .. "-" .. AB_const.DEFAULT_MAX_DPS .. ").")
        AutoBand.saved.max_tanks   = AB_const.DEFAULT_MAX_TANKS
        AutoBand.saved.max_healers = AB_const.DEFAULT_MAX_HEALERS
        AutoBand.saved.max_dps     = AB_const.DEFAULT_MAX_DPS
    end

    -- B) CORE TOGGLES
    -- Optional PM blocking defaults to off; preserve either saved boolean choice.
    if type(AutoBand.saved.block_outgoing_pms) ~= "boolean" then
        if AutoBand.saved.block_outgoing_pms ~= nil then
            AB_util.print("[Warning] Invalid Block AutoBand PMs setting; reset to off.")
        end
        AutoBand.saved.block_outgoing_pms = false
    end
    if AutoBand.saved.warband_enabled        == nil then AutoBand.saved.warband_enabled        = true                       end
    if AutoBand.saved.autokick_enabled        == nil then AutoBand.saved.autokick_enabled        = AB_const.AUTOKICK          end
    if AutoBand.saved.autokick_toofar_enabled == nil then AutoBand.saved.autokick_toofar_enabled = AB_const.AUTOKICKTOOFAR    end
    if AutoBand.saved.autokick_low_rank_enabled == nil then AutoBand.saved.autokick_low_rank_enabled = AB_const.KICKLOWRNK        end
    if AutoBand.saved.autonote_enabled        == nil then AutoBand.saved.autonote_enabled        = AB_const.AUTONOTE          end
    if AutoBand.saved.autopartynote_enabled   == nil then AutoBand.saved.autopartynote_enabled   = AB_const.AUTOPARTYNOTE     end
    if AutoBand.saved.notify_buffs_enabled    == nil then AutoBand.saved.notify_buffs_enabled    = true                       end
    if AutoBand.saved.autokick_we_wh_enabled  == nil then AutoBand.saved.autokick_we_wh_enabled  = AB_const.AUTOKICK_WE_WH    end
    if AutoBand.saved.autokick_rvrzone_enabled== nil then AutoBand.saved.autokick_rvrzone_enabled= AB_const.AUTOKICKRVRZONE   end
    if AutoBand.saved.bw_sorc_as_mdps         == nil then AutoBand.saved.bw_sorc_as_mdps         = AB_const.BW_SORC_AS_MDPS   end
    if AutoBand.saved.restrict_same_race      == nil then AutoBand.saved.restrict_same_race      = AB_const.RESTRICT_RACE     end
    if AutoBand.saved.use_common_race_names   == nil then AutoBand.saved.use_common_race_names   = AB_const.USE_COMMON_RACE_NAMES end
    if AutoBand.saved.backfill_enabled == nil then
        -- Migrate the older backfill saved setting key into the current flag.
        local legacy_backfill_key = "backfill_" .. "ex" .. "perimental_enabled"
        if AutoBand.saved[legacy_backfill_key] ~= nil then
            AutoBand.saved.backfill_enabled = AutoBand.saved[legacy_backfill_key] == true
        else
            AutoBand.saved.backfill_enabled = AB_const.BACKFILL
        end
    end
    AutoBand.saved["backfill_" .. "ex" .. "perimental_enabled"] = nil
    if AutoBand.saved.backfill_no_headsups_enabled == nil then AutoBand.saved.backfill_no_headsups_enabled = AB_const.BACKFILL_NO_HEADS_UPS end
    if AutoBand.saved.autokick_ignorelist_enabled == nil then AutoBand.saved.autokick_ignorelist_enabled = AB_const.AUTOKICK_IGNORELIST end

    -- C) KICK TIMERS & RANK RULES
    AutoBand.saved.autokick_period   = AutoBand.saved.autokick_period   or AB_const.KICK_PERIOD
    AutoBand.saved.min_rank          = AutoBand.saved.min_rank          or AB_const.MINIMUM_RANK
    AutoBand.saved.min_rank_tank     = AutoBand.saved.min_rank_tank     or AutoBand.saved.min_rank or AB_const.MINIMUM_RANK_TANK
    AutoBand.saved.min_rank_healer   = AutoBand.saved.min_rank_healer   or AB_const.MINIMUM_RANK_HEALER
    AutoBand.saved.min_rank_dps      = AutoBand.saved.min_rank_dps      or AutoBand.saved.min_rank or AB_const.MINIMUM_RANK_DPS

    if type(AutoBand.realmrank_init_saved_rank_settings) == "function" then
        AutoBand.realmrank_init_saved_rank_settings()
    end

    -- D) TEMPLATES & ORGANIZATION ALGORITHM
    AutoBand.saved.default_template = AutoBand.saved.default_template or AB_const.EMPTY_TEMPLATE
    AutoBand.saved.active_template_selection = AutoBand.saved.active_template_selection or AB_const.EMPTY_TEMPLATE
    AutoBand.saved.templates        = AutoBand.saved.templates        or {}
    AutoBand.saved.normal_template_settings = AutoBand.saved.normal_template_settings or nil
    AutoBand.saved.org_algo_mode    = AutoBand.saved.org_algo_mode    or AB_const.DEFAULT_ORG_ALGO
    AutoBand.saved.org_algo_role    = AutoBand.saved.org_algo_role    or AB_const.DEFAULT_ORG_ROLE

    -- E) ICON & SOCIAL PRIORITY
    if AutoBand.saved.displayicon                 == nil then AutoBand.saved.displayicon                 = true                              end
    if AutoBand.saved.right_click_organize_include_templates == nil then AutoBand.saved.right_click_organize_include_templates = false end
    AutoBand.saved.right_click_organize = nil
    AutoBand.saved.middle_click_organize_range = nil
    if AutoBand.saved.guild_priority_enabled      == nil then AutoBand.saved.guild_priority_enabled      = AB_const.GUILDPRIORITY            end

    -- F) KICK FUNCTION SPECIFICS
    if AutoBand.saved.kick_func_enabled == nil then
        AutoBand.saved.kick_func_enabled = {}
        for k, v in pairs(AB_const.KICK_FUNC_DEFAULT) do
            AutoBand.saved.kick_func_enabled[k] = v
        end
    end

    -- G) ALT SPEC CHECK & ROLE PRINTING
    if AutoBand.saved.alt_speccheck_enabled == nil then AutoBand.saved.alt_speccheck_enabled = AB_const.ALTCHECK  end
    if AutoBand.saved.exclude_realm_healer_alt_spec == nil then AutoBand.saved.exclude_realm_healer_alt_spec = AB_const.EXCLUDE_REALM_HEALER_ALT_SPEC end
    if AutoBand.saved.printrole_enabled     == nil then AutoBand.saved.printrole_enabled     = AB_const.PRINTROLE end
    if AutoBand.saved.print_arrival_notify_tags_enabled == nil then AutoBand.saved.print_arrival_notify_tags_enabled = AB_const.PRINT_ARRIVAL_NOTIFY_TAGS end
    if AutoBand.saved.autoform_search_enabled == nil then AutoBand.saved.autoform_search_enabled = AB_const.AUTOFORM_SEARCH end
    if AutoBand.saved.search_discord_req_enabled == nil then AutoBand.saved.search_discord_req_enabled = AB_const.SEARCH_DISCORD_REQ end
    if AutoBand.saved.search_no_mic_enabled == nil then AutoBand.saved.search_no_mic_enabled = AB_const.SEARCH_NO_MIC end
    AutoBand.saved.soft_dependency_background_enabled = nil
    if type(AutoBand.realmstats_init_saved_state) == "function" then
        AutoBand.realmstats_init_saved_state()
    end
    if type(AutoBand.realmrank_init_saved_state) == "function" then
        AutoBand.realmrank_init_saved_state()
    end

    -- H) DPS WEIGHTING SETTINGS
    if AutoBand.saved.dps_weighting_enabled == nil then AutoBand.saved.dps_weighting_enabled = AB_const.DPS_WEIGHTING_ENABLED end
    AutoBand.saved.max_mdps = AutoBand.saved.max_mdps or AB_const.DEFAULT_MAX_MDPS
    AutoBand.saved.max_rdps = AutoBand.saved.max_rdps or AB_const.DEFAULT_MAX_RDPS

    -- Ensure consistency on load: mdps + rdps must sum to the *current* max_dps
    if AutoBand.saved.max_mdps + AutoBand.saved.max_rdps ~= AutoBand.saved.max_dps then
        AB_util.print("[Warning] Saved mDPS/rDPS counts did not sum to max DPS (" .. AutoBand.saved.max_dps .. "). Resetting mDPS/rDPS based on current max DPS.")
        AutoBand.saved.max_rdps = math.floor(AutoBand.saved.max_dps / 2)
        AutoBand.saved.max_mdps = AutoBand.saved.max_dps - AutoBand.saved.max_rdps
    end

    -- I) PREFIX & COLOR SETTINGS
    if AutoBand.saved.prefix_text        == nil then AutoBand.saved.prefix_text        = AB_const.DEFAULT_PREFIX_TEXT       end
    if AutoBand.saved.prefix_color_name  == nil then AutoBand.saved.prefix_color_name  = AB_const.DEFAULT_PREFIX_COLOR_NAME end
    if AutoBand.saved.lead_color_name    == nil then AutoBand.saved.lead_color_name    = AB_const.DEFAULT_LEAD_COLOR_NAME   end
    if AutoBand.saved.prefix_use_guild   == nil then AutoBand.saved.prefix_use_guild   = AB_const.DEFAULT_PREFIX_USE_GUILD  end

    -- Validate loaded prefix on init, fallback to default if invalid
    if #AutoBand.saved.prefix_text > AB_const.MAX_PREFIX_LENGTH then
        AB_util.print("[Warning] Saved prefix text was too long (>" .. AB_const.MAX_PREFIX_LENGTH .. " characters). Resetting to default.")
        AutoBand.saved.prefix_text = AB_const.DEFAULT_PREFIX_TEXT
    end
    if AutoBand.saved.prefix_text == "" then
        AB_util.print("[Warning] Saved prefix text was empty. Resetting to default.")
        AutoBand.saved.prefix_text = AB_const.DEFAULT_PREFIX_TEXT
    end

    -- Validate loaded colors on init, fallback to default if invalid
    if not AVAILABLE_COLORS[AutoBand.saved.prefix_color_name:lower()] then
        AB_util.print("[Warning] Saved prefix color '" .. AutoBand.saved.prefix_color_name .. "' is invalid. Resetting to default.")
        AutoBand.saved.prefix_color_name = AB_const.DEFAULT_PREFIX_COLOR_NAME
    else
        AutoBand.saved.prefix_color_name = AutoBand.saved.prefix_color_name:lower()
    end

    if not AVAILABLE_COLORS[AutoBand.saved.lead_color_name:lower()] then
        AB_util.print("[Warning] Saved lead color '" .. AutoBand.saved.lead_color_name .. "' is invalid. Resetting to default.")
        AutoBand.saved.lead_color_name = AB_const.DEFAULT_LEAD_COLOR_NAME
    else
        AutoBand.saved.lead_color_name = AutoBand.saved.lead_color_name:lower()
    end

    -- J) DISTANCE SETTING
    if AutoBand.saved.toofar_radius_setting == nil then
        AutoBand.saved.toofar_radius_setting = AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    end
    -- Validate loaded setting to ensure it's one of the known keys
    if not AB_const.TOOFAR_DISTANCE_VALUES[AutoBand.saved.toofar_radius_setting] then
        AB_util.print("[Warning] Saved 'toofar' radius setting '" .. tostring(AutoBand.saved.toofar_radius_setting) .. "' is invalid. Resetting to default (" .. AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING .. ").")
        AutoBand.saved.toofar_radius_setting = AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    end
    if AutoBand.saved.range_sort_distance_threshold == nil then
        AutoBand.saved.range_sort_distance_threshold = AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
    end
    if type(AutoBand.saved.range_sort_distance_threshold) ~= "number" or AutoBand.saved.range_sort_distance_threshold < 0 then
        AB_util.print("[Warning] Invalid 'range_sort_distance_threshold' (" .. tostring(AutoBand.saved.range_sort_distance_threshold) .. "). Resetting to default (" .. AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD .. ").")
        AutoBand.saved.range_sort_distance_threshold = AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
    end


    -- K) DEBUG SETTINGS
    AutoBand.saved.dumps        = AutoBand.saved.dumps or {}
    AutoBand.saved.dumped_wb    = AutoBand.saved.dumped_wb or nil
    AutoBand.saved.default_dump = AutoBand.saved.default_dump or nil

    if type(AutoBand.saved.live_org_verbose) ~= "boolean" then
        AutoBand.saved.live_org_verbose = false
    end
    AutoBand.live_org_verbose = AutoBand.saved.live_org_verbose
    if type(AutoBand.migrate_social_priority_saved_state) == "function" then
        AutoBand.migrate_social_priority_saved_state()
    end
    if AutoBand.saved.normal_template_settings == nil and type(AutoBand.capture_template_settings_snapshot) == "function" then
        AutoBand.saved.normal_template_settings = AutoBand.capture_template_settings_snapshot()
    end
    if type(AutoBand.restore_saved_template_selection) == "function" then
        AutoBand.restore_saved_template_selection()
    end

    --------------------------------------------------------------------------
    -- 3) CREATE ZONE ID SET & REGISTER SLASH COMMANDS
    --------------------------------------------------------------------------
    AutoBand.allowed_rvr_zones_set = {}
    for _, zone_id in ipairs(AB_const.ZONEIDS) do
        AutoBand.allowed_rvr_zones_set[zone_id] = true
    end

    LibSlash.RegisterSlashCmd("autoband", function(msg) AutoBand.parse_cmd(msg) end)
    if not LibSlash.IsSlashCmdRegistered("ab") then
        LibSlash.RegisterSlashCmd("ab", function(msg) AutoBand.parse_cmd(msg) end)
        AutoBand.has_shortslash = true
    end

    AutoBand.BuildCareerLineToNameMap()

    --------------------------------------------------------------------------
    -- 4) COMMAND LIST INITIALIZATION
    --    (help/info/UI, templates, kicking, zone, ranks, warband org, debug)
    --------------------------------------------------------------------------
    AutoBand.cmd = {
        -- Help/Info & UI
        [""]      = { f = AutoBand.cmd_usage,         help = "",                            print_id = 10 },
        ["help"]  = { f = AutoBand.cmd_usage,         help = "show command list",           print_id = 11 },
        ["info"]  = { f = AutoBand.cmd_status,        help = "show version/mode/caps summary", print_id = 12 },
        ["status"]= { f = AutoBand.cmd_status,        help = "" },
        ["show"]  = { f = AutoBand.cmd_toggle_gui,    help = "open/close GUI",              print_id = 13 },
        ["settings"] = { f = AutoBand.cmd_show,       help = "print current settings to chat", print_id = 13.1 },
        ["icon"]  = { f = AutoBand.cmd_toggle_icon,   help = "show/hide minimap icon",      print_id = 14 },
        ["wbleadtells"] = { f = AutoBand.cmd_toggle_wbleader_tell_alert, help = "toggle WB-Leader tell alerts", print_id = 15 },
        ["wbleadtell"] = { f = AutoBand.cmd_toggle_wbleader_tell_alert, help = "" },
        ["leadertells"] = { f = AutoBand.cmd_toggle_wbleader_tell_alert, help = "" },
        ["leadertell"] = { f = AutoBand.cmd_toggle_wbleader_tell_alert, help = "" },
        ["testwbleadtell"] = { f = AutoBand.cmd_test_wbleader_tell_alert, help = "" },
        ["wbleadtelltest"] = { f = AutoBand.cmd_test_wbleader_tell_alert, help = "" },
        ["enabled"] = { f = AutoBand.cmd_warband_enabled, help = "[on|off] toggle WB automation", print_id = 16 },
        ["enable"]  = { f = AutoBand.cmd_warband_enable,  help = "enable WB automation", print_id = 16.1 },
        ["disable"] = { f = AutoBand.cmd_warband_disable, help = "disable WB automation", print_id = 16.2 },
        ["disabled"] = { f = AutoBand.cmd_warband_disable, help = "" },
        ["nopm"] = { f = AutoBand.cmd_block_pms, help = "[on|off|status] block AutoBand's outgoing PMs", print_id = 16.3 },
        ["blocktells"] = { f = AutoBand.cmd_block_pms, help = "" },
        ["blockpms"] = { f = AutoBand.cmd_block_pms, help = "" },

        -- Config Commands
        ["setprefix"]        = { f = AutoBand.cmd_set_prefix,          help = "<string> set the chat prefix text",               print_id = 17 },
        ["prefix"]           = { f = AutoBand.cmd_set_prefix,          help = "" },
        ["resetprefix"]      = { f = AutoBand.cmd_reset_prefix,        help = "reset chat prefix text to default",               print_id = 18 },
        ["prefixreset"]      = { f = AutoBand.cmd_reset_prefix,        help = "" },
        ["listcolors"]       = { f = AutoBand.cmd_list_colors,         help = "list available color names",                      print_id = 19 },
        ["prefixcolors"]     = { f = AutoBand.cmd_list_colors,         help = "" },
        ["listcolor"]        = { f = AutoBand.cmd_list_colors,         help = "" },
        ["prefixcolor"]      = { f = AutoBand.cmd_set_prefix_color,    help = "<color_name> set prefix color",                   print_id = 20 },
        ["colorprefix"]      = { f = AutoBand.cmd_set_prefix_color,    help = "" },
        ["setprefixcolor"]   = { f = AutoBand.cmd_set_prefix_color,    help = "" },
        ["resetprefixcolor"] = { f = AutoBand.cmd_reset_prefix_color,  help = "reset prefix color to default",                   print_id = 21 },
        ["prefixcolorreset"] = { f = AutoBand.cmd_reset_prefix_color,  help = "" },
        ["prefixguild"]      = { f = AutoBand.cmd_toggle_prefix_guild, help = "use guild name as prefix in advertisement",       print_id = 22 },
        ["guildprefix"]      = { f = AutoBand.cmd_toggle_prefix_guild, help = "" },
        ["leadcolor"]        = { f = AutoBand.cmd_set_lead_color,      help = "<color_name> set WB lead mention color",          print_id = 23 },
        ["colorlead"]        = { f = AutoBand.cmd_set_lead_color,      help = "" },
        ["setleadcolor"]     = { f = AutoBand.cmd_set_lead_color,      help = "" },
        ["resetleadcolor"]   = { f = AutoBand.cmd_reset_lead_color,    help = "reset WB lead mention color to default",          print_id = 24 },
        ["leadcolorreset"]   = { f = AutoBand.cmd_reset_lead_color,    help = "" },

        -- Templates
        ["list"]    = { f = AutoBand.cmd_list_template,   help = "list all templates",                       print_id = 25 },
        ["save"]    = { f = AutoBand.cmd_save_template,   help = "<name> save current WB template + settings preset", print_id = 26 },
        ["apply"]   = { f = AutoBand.cmd_apply_template,  help = "<name> apply saved template preset",       print_id = 27 },
        ["default"] = { f = AutoBand.cmd_default_template,help = "set/clear default template",               print_id = 28 },
        ["mode"]    = { f = AutoBand.cmd_mode,            help = "<num> distribution algorithm mode",        print_id = 29 },

        -- Kick / Auto-Kick
        ["kf"]          = { f = AutoBand.cmd_kick_toofar,            help = "kick all far players",                           print_id = 30 },
        ["ak"]          = { f = AutoBand.cmd_flag_autokick,          help = "toggle autokick low-rank/excess roles",          print_id = 31 },
        ["akl"]         = { f = AutoBand.cmd_flag_autokick_lowrnk,   help = "toggle autokick low-rank players",               print_id = 32 },
        ["akf"]         = { f = AutoBand.cmd_flag_autokick_toofar,   help = "toggle autokick toofar",                         print_id = 33 },
        ["kicktimeout"] = { f = AutoBand.cmd_autokick_timeout,       help = "<mins> autokick toofar timeout",                 print_id = 34 },

        ["settoofardistance"] = {
            f = AutoBand.cmd_set_toofar_distance,
            help = function()
                local settings_with_values = {}
                for k_setting, v_distance in pairs(AB_const.TOOFAR_DISTANCE_VALUES) do
                    table.insert(settings_with_values, { key = k_setting, distance = v_distance })
                end
                table.sort(settings_with_values, function(a, b)
                    return a.distance < b.distance
                end)
                local sorted_keys = {}
                for _, setting_info in ipairs(settings_with_values) do
                    table.insert(sorted_keys, setting_info.key)
                end
                return "<" .. table.concat(sorted_keys, "|") .. "> set 'too far' kick radius"
            end,
            print_id = 35
        },
        ["setdistance"]          = { f = AutoBand.cmd_set_toofar_distance, help = "" },
        ["setdist"]              = { f = AutoBand.cmd_set_toofar_distance, help = "" },
        ["settoofardist" ]       = { f = AutoBand.cmd_set_toofar_distance, help = "" },
        ["toofardist"]           = { f = AutoBand.cmd_set_toofar_distance, help = "" },
        ["tfd"]                  = { f = AutoBand.cmd_set_toofar_distance, help = "" },
        ["setdistancethreshold"] = { f = AutoBand.cmd_set_range_sort_distance_threshold, help = "<units> set distance threshold for '/ab org distance'",   print_id = 36 },
        ["setdisthres"]          = { f = AutoBand.cmd_set_range_sort_distance_threshold, help = "" },

        ["wewhk"]       = { f = AutoBand.cmd_toggle_autokick_we_wh,      help = "toggle autokick WE/WH",                          print_id = 37 },
        ["wek"]         = { f = AutoBand.cmd_toggle_autokick_we_wh,      help = "" },
        ["whk"]         = { f = AutoBand.cmd_toggle_autokick_we_wh,      help = "" },
        ["akz"]         = { f = AutoBand.cmd_flag_autokick_rvrzone,      help = "toggle autokick players in scenarios",           print_id = 38 },
        ["akignore"]    = { f = AutoBand.cmd_toggle_autokick_ignorelist, help = "toggle autokick ignored players",                print_id = 39 },
        ["backfill"]    = { f = AutoBand.cmd_toggle_backfill, help = "toggle backfill; rank-only keeps 2 slots open", print_id = 39.5 },
        ["bfill"]       = { f = AutoBand.cmd_toggle_backfill, help = "" },
        ["bf"]          = { f = AutoBand.cmd_toggle_backfill, help = "" },
        ["an"]          = { f = AutoBand.cmd_flag_autonote,              help = "toggle autosearch in Region for roles",          print_id = 40 },
        ["partynote"]   = { f = AutoBand.cmd_toggle_partynote,           help = "toggle auto update /partynote",                  print_id = 40.5 },
        ["pn"]          = { f = AutoBand.cmd_toggle_partynote,           help = "" },
        ["autoform"]    = { f = AutoBand.cmd_toggle_autoform_search,     help = "toggle autoform WB when searching roles",        print_id = 49 },
        ["form"]        = { f = AutoBand.cmd_form,                       help = "form open party + convert to warband",           print_id = 49.2 },
        ["formwb"]      = { f = AutoBand.cmd_form,                       help = "" },
        ["wbform"]      = { f = AutoBand.cmd_form,                       help = "" },
        ["searchroles"] = { f = AutoBand.cmd_search_roles,               help = "<region|t4|lfg> search in chans",                print_id = 41 },
        ["searchrole"]  = { f = AutoBand.cmd_search_roles,               help = "" },
        ["sr"]          = { f = AutoBand.cmd_search_roles,               help = "" },
        ["guildpriority"] = { f = AutoBand.cmd_flag_guildpriority,       help = "<off|prefer|protect|promote> set guild priority mode", print_id = 42 },
        ["gp"]          = { f = AutoBand.cmd_flag_guildpriority,         help = "" },
        ["friendpriority"] = { f = AutoBand.cmd_flag_friendpriority,     help = "<off|prefer|protect|promote> set friend priority mode", print_id = 42.1 },
        ["fp"]          = { f = AutoBand.cmd_flag_friendpriority,        help = "" },
        ["guildgrouping"] = { f = AutoBand.cmd_toggle_guild_grouping, help = "<on|off> toggle grouping guildies together during organize", print_id = 42.2 },
        ["gg"]          = { f = AutoBand.cmd_toggle_guild_grouping, help = "" },
        ["dpsweight"]   = {
            f    = AutoBand.cmd_toggle_dps_weighting,
            help = function()
                return "<on|off> toggle mDPS/rDPS weighting for " ..
                       AutoBand.saved.max_tanks .. "-" ..
                       AutoBand.saved.max_healers .. "-" ..
                       AutoBand.saved.max_dps
            end,
            print_id = 43
        },
        ["dw"]       = { f = AutoBand.cmd_toggle_dps_weighting, help = "" },
        ["setdps"]   = {
            f    = AutoBand.cmd_set_dps_weights,
            help = function()
                return "<mdps> <rdps> set desired counts (sum must be " .. AutoBand.saved.max_dps .. ")"
            end,
            print_id = 44
        },
        ["setroles"] = { f = AutoBand.cmd_setroles, help = "<tanks> <healers> <dps> set role limits (sum must be 24)", print_id = 45 },
        ["resetroles"] = { f = AutoBand.cmd_resetroles, help = "reset role limits to default (" .. AB_const.DEFAULT_MAX_TANKS .. "-" .. AB_const.DEFAULT_MAX_HEALERS .. "-" .. AB_const.DEFAULT_MAX_DPS .. ")", print_id = 46 },
        ["bwsmdps"] = { f = AutoBand.cmd_toggle_bw_sorc_mdps, help = "treat BW/Sorc as mDPS", print_id = 47 },
        ["bwm"] = { f = AutoBand.cmd_toggle_bw_sorc_mdps, help = "" },
        ["sorcm"] = { f = AutoBand.cmd_toggle_bw_sorc_mdps, help = "" },
        ["restrictrace"] = { f = AutoBand.cmd_toggle_restrict_race, help = "restricting WB to leader's race", print_id = 48 },
        ["rr"] = { f = AutoBand.cmd_toggle_restrict_race, help = "" },
        ["raceonly"] = { f = AutoBand.cmd_toggle_restrict_race, help = "" },

        -- Zone
        ["zone"] = { f = AutoBand.cmd_list_zone, help = "list players not in leader's zone", print_id = 50 },
        ["zones"] = { f = AutoBand.cmd_list_zone, help = "" },
        ["zonekick"] = { f = AutoBand.cmd_kick_notinzone, help = "kick players not in leader's zone", print_id = 51 },
        ["zk"] = { f = AutoBand.cmd_kick_notinzone, help = "" },
        ["adzone"] = { f = AutoBand.cmd_advert_zone, help = "[zoneId] show the current or given advertise zone suffix", print_id = 51.5 },
        ["az"] = { f = AutoBand.cmd_advert_zone, help = "" },
        -- Ranks
        ["rank"] = { f = AutoBand.cmd_list_rank, help = "list players below required rank (CR/RR)", print_id = 60 },
        ["minrank"] = { f = AutoBand.cmd_rank, help = "<num> set tank+dps rank req (1-40 CR, 45-70 RR)", print_id = 61 },
        ["minranktank"] = { f = AutoBand.cmd_rank_tank, help = "<num> min tank rank req (1-40 CR, 45-70 RR)", print_id = 62 },
        ["minrankt"] = { f = AutoBand.cmd_rank_tank, help = "" },
        ["minrankhealer"] = { f = AutoBand.cmd_rank_healer, help = "<num> min healer rank req (1-40 CR, 45-70 RR)", print_id = 63 },
        ["minrankheal"] = { f = AutoBand.cmd_rank_healer, help = "" },
        ["minrankh"] = { f = AutoBand.cmd_rank_healer, help = "" },
        ["minrankdps"] = { f = AutoBand.cmd_rank_dps, help = "<num> min dps rank req (1-40 CR, 45-70 RR)", print_id = 64 },
        ["minrankd"] = { f = AutoBand.cmd_rank_dps, help = "" },
        ["rankkick"] = { f = AutoBand.cmd_kick_rank, help = "kick players below required rank", print_id = 65 },

        -- Warband Organization
        ["org"] = { f = AutoBand.cmd_organize, help = "[template] [distance] - organize warband. 'distance' prioritizes near players", print_id = 70 },
        ["buffnotify"] = { f = AutoBand.cmd_toggle_buffnotify, help = "toggle notifying wb after org", print_id = 71 },
        ["bn"] = { f = AutoBand.cmd_toggle_buffnotify, help = "" },
        ["alt"] = { f = AutoBand.cmd_alt_speccheck, help = "toggle alt-spec check", print_id = 72 },
        ["wb"] = { f = AutoBand.wb, help = "information about the warband", print_id = 73 },
        ["roles"] = { f = AutoBand.cmd_list_roles, help = "<role> list players and their roles", print_id = 74 },
        ["role"] = { f = AutoBand.cmd_list_roles, help = "" },
        ["pr"] = { f = AutoBand.cmd_flag_printrole, help = "toggle printing of role assignments", print_id = 75 },
        ["arrtag"] = { f = AutoBand.cmd_toggle_arrival_notify_tags, help = "<on|off> toggle (arr x/x) in role notifications", print_id = 75.5 },
        ["arrivaltag"] = { f = AutoBand.cmd_toggle_arrival_notify_tags, help = "" },
        ["customrole"] = { f = AutoBand.cmd_custom_role, help = "<add|remove|delete|list> manage role overrides", print_id = 76 },
        ["customroles"] = { f = AutoBand.cmd_custom_role, help = "" },
        ["cr"] = { f = AutoBand.cmd_custom_role, help = "" },
        ["arrival"] = { f = AutoBand.cmd_arrival, help = "<list|swap|move|reset> manage warband arrival order", print_id = 76.5 },
        ["arrivals"] = { f = AutoBand.cmd_arrival, help = "" },
        ["joinorder"] = { f = AutoBand.cmd_arrival, help = "" },
        ["jo"] = { f = AutoBand.cmd_arrival, help = "" },
        ["purpose"] = { f = AutoBand.cmd_set_purpose, help = "<" .. AB_const.GetPurposeNames() .. "|clear> set wb purpose", print_id = 77 },
        ["purposelist"] = { f = AutoBand.cmd_list_purposes, help = "list available warband purposes", print_id = 78 },
        ["end"] = { f = AutoBand.cmd_end, help = "end warband, kick all", print_id = 79 },
        ["printguild"] = { f = AutoBand.cmd_print_guild, help = "prints your current guild info", print_id = 80 },
        ["guildprint"] = { f = AutoBand.cmd_print_guild, help = "" },
        ["listaltspecs"] = { f = AutoBand.cmd_list_alt_specs, help = "list players with reassinged roles", print_id = 81 },
        ["listalts"] = { f = AutoBand.cmd_list_alt_specs, help = "" },
        ["listalt"] = { f = AutoBand.cmd_list_alt_specs, help = "" },
        ["rrlookup"] = { f = AutoBand.cmd_rrlookup, help = "<name> lookup realm-rank (cache-first; rr-cache fallback)", print_id = 81.5 },
        ["rrl"] = { f = AutoBand.cmd_rrlookup, help = "" },
        ["lookup"] = { f = AutoBand.cmd_rrlookup, help = "" },
        ["rrcache"] = { f = AutoBand.cmd_rrcache, help = "[summary|oldest [count]|newest [count]] inspect saved RR fallback cache", print_id = 81.55 },
        ["rrc"] = { f = AutoBand.cmd_rrcache, help = "" },
        ["csvrefresh"] = { f = AutoBand.cmd_rrrefresh, help = "force refresh RealmRank CSV snapshot now", print_id = 81.6 },
        ["rrrefresh"] = { f = AutoBand.cmd_rrrefresh, help = "" },
        ["rrr"] = { f = AutoBand.cmd_rrrefresh, help = "" },
        ["refreshrr"] = { f = AutoBand.cmd_rrrefresh, help = "" },
        ["stats"] = { f = AutoBand.cmd_stats, help = "[now|info|enable|disable|toggle|threshold <pct>|<pct>|breakdown [tier]] show realm online stats; monitor shifts; on-demand career/role breakdown", print_id = 81.7 },
        ["online"] = { f = AutoBand.cmd_online, help = "[group|list|default <group>|default clear|monitor <group>[, <group>...]|add|remove|list|clear] show online Enemy markgroup members (class icon, CR, RR, Enemy K/D when available)", print_id = 82 },
        ["onl"] = { f = AutoBand.cmd_online, help = "" },
        ["friends"] = { f = AutoBand.cmd_friends, help = "show friends present in RR CSV snapshot (class icon, CR, RR)", print_id = 82.2 },
        ["friend"] = { f = AutoBand.cmd_friends, help = "" },
        ["fr"] = { f = AutoBand.cmd_friends, help = "" },

        -- Debug
        ["debug"] = { f = AutoBand.cmd_debug, help = "", print_id = 100 },
        ["dump"] = { f = AutoBand.cmd_dump, help = "", print_id = 101 },
        ["cleardump"] = { f = AutoBand.cmd_cleardumps, help = "", print_id = 102 },
        ["listdump"] = { f = AutoBand.cmd_list_dump, help = "", print_id = 103 },
        ["loaddump"] = { f = AutoBand.cmd_load_dump, help = "", print_id = 104 },
        ["tempdump"] = { f = AutoBand.cmd_dump_from_template, help = "", print_id = 105 },
        ["dumpguild"] = { f = AutoBand.cmd_dump_guild_data, help = "", print_id = 106 },
        ["dumpplayer"] = { f = AutoBand.cmd_dump_player_data, help = "", print_id = 107 },
        ["dumpwarband"] = { f = AutoBand.cmd_dump_warband_data, help = "", print_id = 108 },
        ["dumpparty"] = { f = AutoBand.cmd_dump_party_data, help = "", print_id = 109 },
        ["dumpignorelist"] = { f = AutoBand.cmd_dump_ignore_list, help = "", print_id = 110 },
        ["socialcache"] = { f = AutoBand.cmd_dump_social_cache, help = "[guild|friends|ignore|all] dump AutoBand's cached social lists", print_id = 110.1 },
        ["dumpsocial"] = { f = AutoBand.cmd_dump_social_cache, help = "" },
        ["socialrefresh"] = { f = AutoBand.cmd_refresh_social_cache, help = "[guild|friends|ignore|all] force refresh AutoBand's cached social lists", print_id = 110.2 },
        ["refreshsocial"] = { f = AutoBand.cmd_refresh_social_cache, help = "" },
        ["orgverbose"] = { f = AutoBand.cmd_toggle_live_org_verbose, help = "", print_id = 111 },
        ["openparty"] = { f = AutoBand.cmd_open_party_status, help = "", print_id = 112 },
        ["promopopup"] = { f = AutoBand.cmd_promotion_popup_preview, help = "[player_count] show promotion safety popup preview", print_id = 112.1 },
        ["testpromopopup"] = { f = AutoBand.cmd_promotion_popup_preview, help = "" },
    }

    -- Feature modules can extend the slash-command table without pushing their
    -- command definitions back into this core file.
    for i = 1, #AutoBand.command_definition_hooks do
        local hook = AutoBand.command_definition_hooks[i]
        if type(hook) == "function" then
            local ok_hook, err = pcall(hook, AutoBand.cmd)
            if not ok_hook then
                AB_util.print("[Warning] Command registration hook failed: " .. tostring(err))
            end
        end
    end

    AutoBand.cmd_ordered = {}
    for key, cmd in pairs(AutoBand.cmd) do
        -- Handle help text potentially being a function
        local help_text = ""
        if type(cmd.help) == "function" then
            help_text = cmd.help()
        elseif type(cmd.help) == "string" then
            help_text = cmd.help
        end
        if cmd.print_id ~= nil then
            cmd.key            = key
            cmd.resolved_help  = help_text -- Store resolved help text for sorting/display
            table.insert(AutoBand.cmd_ordered, cmd)
        end
    end
    table.sort(AutoBand.cmd_ordered, function(a, b)
        return a.print_id < b.print_id
    end)

    --------------------------------------------------------------------------
    -- 6) REGISTER LAYOUT WINDOW
    --------------------------------------------------------------------------
    LayoutEditor.RegisterWindow("AutoBandMapIcon", L"AutoBand", L"AutoBand Button", false, false, true, nil)

    --------------------------------------------------------------------------
    -- 7) APPLY WARBAND ENABLED STATE
    --------------------------------------------------------------------------
    AutoBand.apply_warband_enabled_state()

    --------------------------------------------------------------------------
    -- 7.5) REGISTER CHAT LINK HANDLER AND OPTIONAL TELL ALERT HANDLER
    --------------------------------------------------------------------------
    AutoBand.TryRegisterPrefixLinkHandler()
    AutoBand.RefreshWBLeaderTellEventSubscription()
    AutoBand.RefreshChatChannelEventSubscription()

    --------------------------------------------------------------------------
    -- 8) PRINT LOADED MESSAGE
    --------------------------------------------------------------------------
    local slash = AutoBand.has_shortslash and " or /ab" or ""
    AB_util.print("AutoBand v" .. AB_const.VERSION .. " loaded. Type /autoband" .. slash .. " for instructions.")
end

function AutoBand.BuildCareerLineToNameMap()
    if not GameData or not GameData.CareerLine then
        -- This case should ideally not happen if GameData is loaded
        AB_util.print("[Warning] GameData.CareerLine not available for building career name map.")
        return
    end
    for name_str, line_val in pairs(GameData.CareerLine) do
        local name_parts = {}
        for part in name_str:gmatch("([^_]+)") do -- Split by underscore
            if #part > 0 then
                table.insert(name_parts, part:sub(1,1):upper() .. part:sub(2):lower()) -- Title case each part
            end
        end
        AutoBand.CareerLineToNameMap[line_val] = table.concat(name_parts, " ")
    end
end

function AutoBand.GetCareerName(career_line_id)
    if AutoBand.CareerLineToNameMap and AutoBand.CareerLineToNameMap[career_line_id] then
        return AutoBand.CareerLineToNameMap[career_line_id]
    end
    return "Unknown Career (" .. tostring(career_line_id) .. ")"
end

function AutoBand.cmd_toggle_live_org_verbose(_args)
    AutoBand.live_org_verbose = not AutoBand.live_org_verbose
    if AutoBand.saved then
        AutoBand.saved.live_org_verbose = AutoBand.live_org_verbose
    end
    AB_util.print("Live Organize Verbose Printing: " .. tostring(AutoBand.live_org_verbose))
end

function AutoBand.cmd_list_alt_specs(_args)
    local wb_obj = AutoBand.get_wb()
    if not wb_obj or wb_obj.player_count == 0 then
        AB_util.print("Not in a warband or warband is empty.")
        return
    end

    if not next(AutoBand.CareerLineToNameMap) then -- Ensure map is built
        AutoBand.BuildCareerLineToNameMap()
    end

    local reassigned_players_info = {}
    local count = 0
    local ror_gs_available = RoRGroupScoreboard and RoRGroupScoreboard.playersDataRaw

    wb_obj:foreach_player(function(_gid, player_data_from_wb)
        local player_name_str = tostring(player_data_from_wb.name)
        local player_name_lower = player_name_str:lower()

        local original_career_line = player_data_from_wb.careerLine
        local original_default_role = AB_const.CAREERLINE_MAP[original_career_line]
        local current_assigned_role = player_data_from_wb.role -- Final role from AutoBand

        if original_default_role ~= current_assigned_role then
            local reason_tag = ""
            local custom_role_setting = AutoBand.saved.custom_roles[player_name_lower]

            -- Determine the primary reason for the role change based on AutoBand's logic priority
            if custom_role_setting and custom_role_setting == current_assigned_role then
                reason_tag = "(custom role)"
            else
                local is_bw_sorc_career = (original_career_line == GameData.CareerLine.BRIGHT_WIZARD or original_career_line == GameData.CareerLine.SORCERER)
                if AutoBand.saved.bw_sorc_as_mdps and is_bw_sorc_career and current_assigned_role == AB_const.MDPS then
                    if AutoBand.faction == AB_const.ORDER then
                        reason_tag = "(BW as mDPS)"
                    elseif AutoBand.faction == AB_const.DESTRUCTION then
                        reason_tag = "(Sorc as mDPS)"
                    else
                        reason_tag = "(BW/Sorc as mDPS)"
                    end
                elseif AutoBand.saved.alt_speccheck_enabled then
                    -- If alt_speccheck is on, it's the next most likely cause if not BW/Sorc or Custom
                    local career_after_getarchetype = AB_wb:getArcheType(player_data_from_wb) -- Uses RoRGS internally
                    local role_from_getarchetype = AB_util.career_category(career_after_getarchetype)

                    if role_from_getarchetype == current_assigned_role then -- Check if this step was the one setting the final role
                        local is_confirmed_ror_alt_spec = false
                        if ror_gs_available then
                            for _, ror_player_data in pairs(RoRGroupScoreboard.playersDataRaw) do
                                if ror_player_data.name == towstring(player_name_str) and ror_player_data.archtype > 0 then
                                    -- Confirm if the game's alt-spec data aligns with getArchetype's decision
                                    local ror_gs_implied_career = original_career_line
                                    if original_career_line == GameData.CareerLine.ZEALOT then ror_gs_implied_career = GameData.CareerLine.MAGUS
                                    elseif original_career_line == GameData.CareerLine.WARRIOR_PRIEST then ror_gs_implied_career = GameData.CareerLine.SLAYER
                                    elseif original_career_line == GameData.CareerLine.RUNE_PRIEST then ror_gs_implied_career = GameData.CareerLine.ENGINEER
                                    elseif original_career_line == GameData.CareerLine.ARCHMAGE then ror_gs_implied_career = GameData.CareerLine.ENGINEER
                                    elseif original_career_line == GameData.CareerLine.SHAMAN then ror_gs_implied_career = GameData.CareerLine.MAGUS
                                    elseif original_career_line == GameData.CareerLine.DISCIPLE then ror_gs_implied_career = GameData.CareerLine.CHOPPA
                                    elseif original_career_line == GameData.CareerLine.SQUIG_HERDER then ror_gs_implied_career = GameData.CareerLine.CHOPPA
                                    elseif original_career_line == GameData.CareerLine.SHADOW_WARRIOR then ror_gs_implied_career = GameData.CareerLine.SLAYER
                                    end
                                    if ror_gs_implied_career == career_after_getarchetype then
                                        is_confirmed_ror_alt_spec = true
                                    end
                                    break
                                end
                            end
                        end
                        if is_confirmed_ror_alt_spec then
                            reason_tag = "(spec check)"
                        end
                    end
                end
            end

            if reason_tag == "" then -- Fallback if no specific toggle/override matched the final role change
                reason_tag = "(AutoBand)"
            end

            table.insert(reassigned_players_info, {
                name = player_name_str,
                original_career_name = AutoBand.GetCareerName(original_career_line),
                original_role = original_default_role,
                current_role = current_assigned_role,
                reason = reason_tag
            })
            count = count + 1
        end
    end)

    if count > 0 then
        AB_util.print("Players with reassigned roles (original -> reassigned [reason]):")
        for _, p_info in ipairs(reassigned_players_info) do
            local msg = string.format("- %s (%s): %s -> %s %s",
                p_info.name, -- Already a Lua string
                p_info.original_career_name,
                p_info.original_role or "N/A",
                p_info.current_role or "N/A",
                p_info.reason
            )
            AB_util.print(towstring(msg))
        end
    else
        AB_util.print("No players with reassigned roles found.")
    end

    if not ror_gs_available then
        AB_util.print("WARNING: RoRGroupScoreboard data (from GroupScoreboard addon) not available.")
    end
end

function AutoBand.cmd_set_range_sort_distance_threshold(args)
    local new_threshold_str = args[1]
    if not new_threshold_str then
        AB_util.print("[Error] Missing argument. Usage: /ab setdistancethreshold <units> (alias: /ab setdisthres)")
        AB_util.print("Current /ab org distance threshold: " .. AutoBand.saved.range_sort_distance_threshold .. " units.")
        return
    end

    local new_threshold = tonumber(new_threshold_str)
    -- Ensure it's a finite number and not negative. Allow 0; no upper limit.
    if not new_threshold or type(new_threshold) ~= "number" or new_threshold ~= new_threshold or
       new_threshold == math.huge or new_threshold < 0 then
        AB_util.print("[Error] Invalid threshold value: '" .. new_threshold_str .. "'. Must be a non-negative number.")
        return
    end

    AutoBand.saved.range_sort_distance_threshold = math.floor(new_threshold) -- Store as an integer
    AB_util.print("/ab org distance threshold set to: " .. AutoBand.saved.range_sort_distance_threshold .. " units.")
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui({ distance_changed = true })

end

function AutoBand.cmd_print_guild(_args)
  if not GameData or not GameData.Guild or not GameData.Guild.m_GuildID or GameData.Guild.m_GuildID == 0 or not GameData.Guild.m_GuildName then
    AB_util.print("[Error] Could not retrieve guild information. Are you in a guild?")
    return
  end

  local guild_id_num = GameData.Guild.m_GuildID
  local guild_id_str = tostring(guild_id_num)
  local guild_name_str = tostring(GameData.Guild.m_GuildName)

  if AutoBand.is_starter_guild and AutoBand.is_starter_guild() then
    AB_util.print("Starter guild detected (" .. guild_name_str .. "); AutoBand treats this as no guild.")
    return
  end

  local prefix_color_name = AutoBand.saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME
  local color_rgb = AB_const.AVAILABLE_COLORS[prefix_color_name] or AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_PREFIX_COLOR_NAME]
  local r, g, b = color_rgb[1], color_rgb[2], color_rgb[3]
  local link_color_str = string.format("%d,%d,%d", r, g, b)

    -- The raw LINK tag structure (without the outer [])
  local link_tag_content = string.format("LINK data=\"GUILD:%s\" text=\"%s\" color=\"%s\"",
                     guild_id_str,
                     guild_name_str,
                     link_color_str)

  local clickable_link_raw = string.format("<%s>", link_tag_content) -- This is the actual clickable part

    local output_message = L"Guild Info:\n" ..
                           L"  - ID: " .. towstring(guild_id_str) .. L"\n" ..
                           L"  - Name: " .. towstring(guild_name_str) .. L"\n" ..
                           L"  - Color RGB (from AutoBand settings): " .. towstring(link_color_str) .. L"\n" ..
                           L"  - Raw LINK Tag Content: " .. towstring(link_tag_content) .. L"\n" ..
                           L"  - Clickable Link: [" .. towstring(clickable_link_raw) .. L"]"

    AB_util.print(output_message)
end

local function join_list_with_conjunction(items, conjunction)
    local count = #items
    if count == 0 then
        return ""
    end
    if count == 1 then
        return items[1]
    end
    if count == 2 then
        return items[1] .. " " .. conjunction .. " " .. items[2]
    end
    return table.concat(items, ", ", 1, count - 1) .. ", " .. conjunction .. " " .. items[count]
end

-- Settings window refresh: redraw only the visible page plus the shell strip and
-- footer. Hidden pages are redrawn on Show(), so nothing addresses hidden widgets.
-- Refreshes are read-only and never fire combo handlers or chat commands.
-- opts.prefix_text_changed / opts.distance_changed: that saved text value changed,
-- so its edit box may be rewritten (otherwise text being typed is kept).
function AutoBand.refresh_settings_ui(opts)
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshVisiblePage) == "function" then
        AutoBandWindow.RefreshVisiblePage(opts)
    end
end

-- Event-driven (group/warband/vote lifecycle): re-evaluate only the visible page's
-- action buttons. No per-frame polling; a hidden window does nothing.
function AutoBand.refresh_settings_actions()
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshActionAvailability) == "function" then
        AutoBandWindow.RefreshActionAvailability()
    end
end

local function refresh_config_tab()
    AutoBand.refresh_settings_ui()
end

function AutoBand.mark_template_settings_modified()
    AutoBand.template_settings_dirty = true
    mark_partynote_dirty()
    local active_key = AutoBand.template_active_key
    if (active_key == nil or active_key == AB_const.EMPTY_TEMPLATE or active_key == AB_const.CURRENT_WB) and
       type(AutoBand.capture_template_settings_snapshot) == "function"
    then
        AutoBand.saved.normal_template_settings = AutoBand.capture_template_settings_snapshot()
    end
    if type(AutoBandWindowTemplate) == "table" then
        if type(AutoBandWindowTemplate.mark_modified) == "function" then
            AutoBandWindowTemplate.mark_modified()
        else
            AutoBandWindowTemplate.modified = true
            if type(ButtonSetDisabledFlag) == "function" and AutoBandWindowTemplate.savebutton_name then
                ButtonSetDisabledFlag(AutoBandWindowTemplate.savebutton_name, false)
            end
        end
    end
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshPresetLabel) == "function" then
        AutoBandWindow.RefreshPresetLabel()
    end
end

local function set_toggle(flag_name, new_state, opts, label)
    opts = opts or {}
    new_state = new_state == true
    local changed = AutoBand.saved[flag_name] ~= new_state
    AutoBand.saved[flag_name] = new_state
    if changed and not opts.silent and label then
        AB_util.print(label .. tostring(new_state))
    end
    if changed and not opts.skip_template_dirty then
        AutoBand.mark_template_settings_modified()
    end
    if changed and not opts.skip_gui_refresh then
        refresh_config_tab()
    end
    return changed
end

function AutoBand.is_warband_enabled()
    if not AutoBand.saved then
        return true
    end
    return AutoBand.saved.warband_enabled ~= false
end

function AutoBand.require_warband_features_enabled(action_label)
    if AutoBand.is_warband_enabled() then
        return true
    end

    local suffix = ""
    if action_label and tostring(action_label) ~= "" then
        suffix = " before " .. tostring(action_label)
    end
    AB_util.print("AutoBand warband features are disabled. Use /ab enable" .. suffix .. ".")
    return false
end

local function refresh_warband_enabled_ui()
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshWarbandEnabledState) == "function" then
        AutoBandWindow.RefreshWarbandEnabledState()
    end
end

function AutoBand.set_warband_enabled(new_state, opts)
    opts = opts or {}
    new_state = new_state == true
    AutoBand.saved = AutoBand.saved or {}

    local changed = AutoBand.saved.warband_enabled ~= new_state
    AutoBand.saved.warband_enabled = new_state
    AutoBand.warband_disabled_enqueue_warned = false

    if type(AutoBand.apply_warband_enabled_state) == "function" then
        AutoBand.apply_warband_enabled_state({ refresh_now = new_state })
    end

    if changed and not opts.silent then
        if new_state then
            AB_util.print("AutoBand warband automation: enabled.")
        else
            AB_util.print("AutoBand warband automation: disabled. Race/role and RR CSV/stats stay active.")
        end
    elseif not changed and not opts.silent then
        if new_state then
            AB_util.print("AutoBand warband automation already enabled.")
        else
            AB_util.print("AutoBand warband automation already disabled. Race/role and RR CSV/stats stay active.")
        end
    end
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshGlobalStrip) == "function" then
        AutoBandWindow.RefreshGlobalStrip()
    end

    return changed
end

local function parse_warband_enabled_arg(raw)
    if raw == nil then
        return nil
    end
    local arg = tostring(raw):lower()
    if arg == "on" or arg == "true" or arg == "1" or arg == "enable" or arg == "enabled" then
        return true
    elseif arg == "off" or arg == "false" or arg == "0" or arg == "disable" or arg == "disabled" then
        return false
    end
    return nil
end

function AutoBand.cmd_warband_enabled(args)
    args = args or {}
    local requested = parse_warband_enabled_arg(args[1])
    if args[1] ~= nil and requested == nil then
        AB_util.print("Usage: /ab enabled [on|off] or /ab enable|disable")
        return
    end
    if requested == nil then
        requested = not AutoBand.is_warband_enabled()
    end
    AutoBand.set_warband_enabled(requested)
end

function AutoBand.cmd_warband_enable(_args)
    AutoBand.set_warband_enabled(true)
end

function AutoBand.cmd_warband_disable(_args)
    AutoBand.set_warband_enabled(false)
end

function AutoBand.set_autokick_enabled(new_state, opts)
    local msg = "Auto enforcing " .. AutoBand.saved.max_tanks .. "-" .. AutoBand.saved.max_healers .. "-" .. AutoBand.saved.max_dps .. " WB (autokick): "
    return set_toggle("autokick_enabled", new_state, opts, msg)
end

function AutoBand.set_autokick_low_rank_enabled(new_state, opts)
    return set_toggle("autokick_low_rank_enabled", new_state, opts, "Auto kick players below rank req: ")
end

function AutoBand.set_autokick_we_wh_enabled(new_state, opts)
    return set_toggle("autokick_we_wh_enabled", new_state, opts, AB_const.GetAutoKickStealthersLabel("Auto kick") .. ": ")
end

function AutoBand.set_autokick_ignorelist_enabled(new_state, opts)
    return set_toggle("autokick_ignorelist_enabled", new_state, opts, "Auto kick ignored players: ")
end

function AutoBand.set_autokick_rvrzone_enabled(new_state, opts)
    return set_toggle("autokick_rvrzone_enabled", new_state, opts, "Auto kick players in scenarios: ")
end

function AutoBand.set_backfill_enabled(new_state, opts)
    local changed = set_toggle("backfill_enabled", new_state, opts, "BackFill: ")
    if changed and AutoBand.saved.backfill_enabled ~= true then
        AutoBand.backfill_notice_state = {}
    end
    return changed
end

function AutoBand.set_backfill_no_headsups_enabled(new_state, opts)
    local changed = set_toggle("backfill_no_headsups_enabled", new_state, opts, "BackFill no heads-ups: ")
    if changed then
        AutoBand.backfill_notice_state = {}
    end
    return changed
end

function AutoBand.set_use_common_race_names(new_state, opts)
    return set_toggle("use_common_race_names", new_state, opts, "Use common race names: ")
end

local function set_social_priority_mode(source_key, new_mode, opts)
    opts = opts or {}

    local mode_field = "guild_priority_mode"
    local legacy_enabled_field = "guild_priority_enabled"
    if source_key == "friend" then
        mode_field = "friend_priority_mode"
        legacy_enabled_field = "friend_priority_enabled"
    end
    local normalized = AutoBand.normalize_social_priority_mode(new_mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    local changed = AutoBand.saved[mode_field] ~= normalized

    AutoBand.saved[mode_field] = normalized
    AutoBand.saved[legacy_enabled_field] = normalized ~= AB_const.SOCIAL_PRIORITY_MODE_OFF

    if changed and type(AutoBand.arm_social_priority_grace) == "function" then
        AutoBand.arm_social_priority_grace()
    end
    if changed and not opts.silent then
        local prefix = "Guild"
        if source_key == "friend" then
            prefix = "Friend"
        end
        AB_util.print(prefix .. " priority mode: " .. AutoBand.get_social_priority_mode_label(normalized))
    end
    if changed and not opts.skip_template_dirty then
        AutoBand.mark_template_settings_modified()
    end
    if changed and not opts.skip_gui_refresh then
        refresh_config_tab()
    end

    return changed
end

function AutoBand.set_guild_priority_mode(new_mode, opts)
    return set_social_priority_mode("guild", new_mode, opts)
end

function AutoBand.set_friend_priority_mode(new_mode, opts)
    return set_social_priority_mode("friend", new_mode, opts)
end

function AutoBand.set_guild_grouping_enabled(new_state, opts)
    return set_toggle("guild_grouping_enabled", new_state, opts, "Group guildies together during organize: ")
end

function AutoBand.set_autokick_toofar_enabled(new_state, opts)
    opts = opts or {}
    new_state = new_state == true
    local changed = AutoBand.saved.autokick_toofar_enabled ~= new_state
    AutoBand.saved.autokick_toofar_enabled = new_state
    if changed then
        if not opts.silent then
            if AutoBand.is_warband_enabled() and AutoBand.is_wb_leader() then
                local prefix_raw_wspace = AutoBand.GetFormattedPrefixRaw(true)
                local current_distance_str = AutoBand.get_current_toofar_distance() .. " units"
                if new_state then
                    AutoBand.enqueue_command("/wb " .. prefix_raw_wspace .. "Autokick players too far (current max: " .. current_distance_str .. ") ENABLED! Follow the leader PLEASE!")
                else
                    AutoBand.enqueue_command("/wb " .. prefix_raw_wspace .. "Autokick players too far DISABLED!")
                end
            end
            AB_util.print("Auto kick too far players: " .. tostring(new_state))
        end
        if not new_state then
            warned = {}
            toofar = {}
            toofar_old = {}
            toofar_not_changed = {}
        end
        if not opts.skip_template_dirty then
            AutoBand.mark_template_settings_modified()
        end
        if not opts.skip_gui_refresh then
            refresh_config_tab()
        end
    end
    return changed
end

local TEMPLATE_SNAPSHOT_VERSION = 4

local function template_bool(v)
    return v == true
end

local function template_int(v, fallback, minv, maxv)
    local n = tonumber(v)
    if n == nil then
        n = tonumber(fallback)
    end
    if n == nil then
        n = 0
    end
    n = math.floor(n)
    if minv ~= nil and n < minv then
        n = minv
    end
    if maxv ~= nil and n > maxv then
        n = maxv
    end
    return n
end

function AutoBand.template_prefix_text(v, fallback)
    if type(v) ~= "string" then
        v = fallback
    end
    if type(v) ~= "string" then
        return AB_const.DEFAULT_PREFIX_TEXT
    end
    v = string.gsub(v, "^%s+", "")
    v = string.gsub(v, "%s+$", "")
    if v == "" or #v > AB_const.MAX_PREFIX_LENGTH then
        return AB_const.DEFAULT_PREFIX_TEXT
    end
    return v
end

function AutoBand.template_color_name(v, fallback)
    if type(v) ~= "string" then
        v = fallback
    end
    if type(v) ~= "string" then
        return fallback
    end
    local ok, lowered = pcall(string.lower, v)
    if not ok or type(lowered) ~= "string" or AVAILABLE_COLORS[lowered] == nil then
        return fallback
    end
    return lowered
end

local function build_default_dps_weights(max_dps)
    local mdps = 0
    local rdps = 0
    max_dps = template_int(max_dps, AB_const.DEFAULT_MAX_DPS, 0, 24)
    if max_dps > 0 then
        rdps = math.floor(max_dps / 2)
        mdps = max_dps - rdps
        if mdps == 0 and rdps > 0 then
            mdps = 1
            rdps = max_dps - 1
        elseif rdps == 0 and mdps > 0 then
            rdps = 1
            mdps = max_dps - 1
        end
    end
    return mdps, rdps
end

function AutoBand.template_get_layout(template_data)
    if type(template_data) ~= "table" then
        return nil
    end
    if type(template_data.layout) == "table" then
        return template_data.layout
    end
    return template_data
end

function AutoBand.template_get_settings(template_data)
    if type(template_data) ~= "table" then
        return nil
    end
    if type(template_data.settings) == "table" then
        return template_data.settings
    end
    return nil
end

function AutoBand.normalize_template_selection(name)
    if type(name) ~= "string" or name == "" then
        return AB_const.EMPTY_TEMPLATE
    end
    if name == AB_const.EMPTY_TEMPLATE or name == AB_const.CURRENT_WB then
        return name
    end

    local saved = AutoBand.saved or {}
    if type(saved.templates) == "table" and saved.templates[name] ~= nil then
        return name
    end

    return AB_const.EMPTY_TEMPLATE
end

function AutoBand.remember_active_template_selection(name)
    local resolved = AutoBand.normalize_template_selection(name)
    AutoBand.template_active_key = resolved
    if type(AutoBand.saved) == "table" then
        AutoBand.saved.active_template_selection = resolved
    end
    return resolved
end

function AutoBand.restore_saved_template_selection()
    local saved = AutoBand.saved or {}
    local requested = saved.active_template_selection or AB_const.EMPTY_TEMPLATE
    local resolved = AutoBand.remember_active_template_selection(requested)

    if resolved == AB_const.EMPTY_TEMPLATE and requested ~= nil and requested ~= "" and requested ~= AB_const.EMPTY_TEMPLATE then
        if type(AutoBand.restore_normal_template_settings) == "function" then
            AutoBand.restore_normal_template_settings({
                silent = true,
                skip_gui_refresh = true,
                skip_template_dirty = true,
                template_name = AB_const.EMPTY_TEMPLATE
            })
        end
    end

    return resolved
end

function AutoBand.capture_template_settings_snapshot()
    local saved = AutoBand.saved or {}
    local min_rank_tank = template_int(saved.min_rank_tank or saved.min_rank, AB_const.MINIMUM_RANK_TANK, 0, AB_const.MAXIMUM_RANK)
    local min_rank_healer = template_int(saved.min_rank_healer, AB_const.MINIMUM_RANK_HEALER, 0, AB_const.MAXIMUM_RANK)
    local min_rank_dps = template_int(saved.min_rank_dps or saved.min_rank, AB_const.MINIMUM_RANK_DPS, 0, AB_const.MAXIMUM_RANK)
    if type(AutoBand.get_saved_rank_requirements) == "function" then
        min_rank_tank, min_rank_healer, min_rank_dps = AutoBand.get_saved_rank_requirements(saved)
    end
    local min_rank_legacy = min_rank_tank
    if min_rank_dps > min_rank_legacy then
        min_rank_legacy = min_rank_dps
    end
    local guild_priority_mode = AutoBand.get_saved_social_priority_mode("guild", saved)
    local friend_priority_mode = AutoBand.get_saved_social_priority_mode("friend", saved)

    return {
        autokick_enabled = template_bool(saved.autokick_enabled),
        autokick_toofar_enabled = template_bool(saved.autokick_toofar_enabled),
        autokick_low_rank_enabled = template_bool(saved.autokick_low_rank_enabled),
        autonote_enabled = template_bool(saved.autonote_enabled),
        autopartynote_enabled = template_bool(saved.autopartynote_enabled),
        notify_buffs_enabled = template_bool(saved.notify_buffs_enabled),
        autokick_we_wh_enabled = template_bool(saved.autokick_we_wh_enabled),
        autokick_rvrzone_enabled = template_bool(saved.autokick_rvrzone_enabled),
        bw_sorc_as_mdps = template_bool(saved.bw_sorc_as_mdps),
        restrict_same_race = template_bool(saved.restrict_same_race),
        use_common_race_names = template_bool(saved.use_common_race_names),
        prefix_use_guild = template_bool(saved.prefix_use_guild),
        prefix_text = AutoBand.template_prefix_text(saved.prefix_text, AB_const.DEFAULT_PREFIX_TEXT),
        prefix_color_name = AutoBand.template_color_name(saved.prefix_color_name, AB_const.DEFAULT_PREFIX_COLOR_NAME),
        lead_color_name = AutoBand.template_color_name(saved.lead_color_name, AB_const.DEFAULT_LEAD_COLOR_NAME),
        right_click_organize_include_templates = template_bool(saved.right_click_organize_include_templates),
        realmrank_lookup_enabled = template_bool(saved.realmrank_lookup_enabled),
        backfill_enabled = template_bool(saved.backfill_enabled),
        backfill_no_headsups_enabled = template_bool(saved.backfill_no_headsups_enabled),
        autokick_ignorelist_enabled = template_bool(saved.autokick_ignorelist_enabled),
        autokick_period = template_int(saved.autokick_period, AB_const.KICK_PERIOD, 0, AB_const.MAX_KICKOFF_TIME),
        min_rank = min_rank_legacy,
        min_rank_tank = min_rank_tank,
        min_rank_healer = min_rank_healer,
        min_rank_dps = min_rank_dps,
        org_algo_mode = template_int(saved.org_algo_mode, AB_const.DEFAULT_ORG_ALGO, AB_const.MODE_SPREAD, AB_const.MODE_AGGREGATE),
        org_algo_role = saved.org_algo_role or AB_const.DEFAULT_ORG_ROLE,
        guild_priority_mode = guild_priority_mode,
        friend_priority_mode = friend_priority_mode,
        guild_grouping_enabled = template_bool(saved.guild_grouping_enabled),
        alt_speccheck_enabled = template_bool(saved.alt_speccheck_enabled),
        exclude_realm_healer_alt_spec = template_bool(saved.exclude_realm_healer_alt_spec),
        printrole_enabled = template_bool(saved.printrole_enabled),
        print_arrival_notify_tags_enabled = template_bool(saved.print_arrival_notify_tags_enabled),
        autoform_search_enabled = template_bool(saved.autoform_search_enabled),
        search_discord_req_enabled = template_bool(saved.search_discord_req_enabled),
        search_no_mic_enabled = template_bool(saved.search_no_mic_enabled),
        dps_weighting_enabled = template_bool(saved.dps_weighting_enabled),
        max_tanks = template_int(saved.max_tanks, AB_const.DEFAULT_MAX_TANKS, 0, 24),
        max_healers = template_int(saved.max_healers, AB_const.DEFAULT_MAX_HEALERS, 0, 24),
        max_dps = template_int(saved.max_dps, AB_const.DEFAULT_MAX_DPS, 0, 24),
        max_mdps = template_int(saved.max_mdps, AB_const.DEFAULT_MAX_MDPS, 0, 24),
        max_rdps = template_int(saved.max_rdps, AB_const.DEFAULT_MAX_RDPS, 0, 24),
        toofar_radius_setting = saved.toofar_radius_setting,
        range_sort_distance_threshold = template_int(saved.range_sort_distance_threshold, AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD, 0, nil),
    }
end

function AutoBand.build_template_snapshot(layout)
    return {
        version = TEMPLATE_SNAPSHOT_VERSION,
        layout = layout,
        settings = AutoBand.capture_template_settings_snapshot()
    }
end

function AutoBand.restore_normal_template_settings(opts)
    local saved = AutoBand.saved or {}
    if type(saved.normal_template_settings) ~= "table" then
        return false
    end
    if type(AutoBand.remember_active_template_selection) == "function" then
        AutoBand.remember_active_template_selection(AB_const.EMPTY_TEMPLATE)
    else
        AutoBand.template_active_key = AB_const.EMPTY_TEMPLATE
    end
    return AutoBand.apply_template_settings({ settings = saved.normal_template_settings }, opts)
end

function AutoBand.apply_template_settings(template_data, opts)
    local settings = AutoBand.template_get_settings(template_data)
    local saved = AutoBand.saved
    local changed = false
    local need_role_refresh = false
    local notify_missing_rr = false
    local toggle_opts = { silent = true, skip_gui_refresh = true, skip_template_dirty = true }

    if type(settings) ~= "table" or type(saved) ~= "table" then
        return false
    end

    local function apply_bool(field, value)
        if value == nil then
            return
        end
        value = template_bool(value)
        if saved[field] ~= value then
            saved[field] = value
            changed = true
        end
    end

    local function apply_string(field, value)
        if value == nil then
            return
        end
        if saved[field] ~= value then
            saved[field] = value
            changed = true
        end
    end

    local function apply_toggle_setter(setter, field, value)
        if value == nil then
            return
        end
        if type(setter) == "function" then
            if setter(value, toggle_opts) then
                changed = true
            end
        else
            apply_bool(field, value)
        end
    end

    local function apply_mode_setter(setter, source_key, value)
        local resolved = value
        if resolved == nil then
            local mode_field = source_key == "friend" and "friend_priority_enabled" or "guild_priority_enabled"
            if settings[mode_field] ~= nil or settings.priority_ignore_rank_restrictions_enabled ~= nil then
                resolved = AutoBand.get_saved_social_priority_mode(source_key, settings)
            end
        end
        if resolved == nil then
            return
        end
        if type(setter) == "function" and setter(resolved, toggle_opts) then
            changed = true
        end
    end

    local max_tanks = template_int(settings.max_tanks, saved.max_tanks or AB_const.DEFAULT_MAX_TANKS, 0, 24)
    local max_healers = template_int(settings.max_healers, saved.max_healers or AB_const.DEFAULT_MAX_HEALERS, 0, 24)
    local max_dps = template_int(settings.max_dps, saved.max_dps or AB_const.DEFAULT_MAX_DPS, 0, 24)
    if max_tanks + max_healers + max_dps == 24 then
        if saved.max_tanks ~= max_tanks or saved.max_healers ~= max_healers or saved.max_dps ~= max_dps then
            saved.max_tanks = max_tanks
            saved.max_healers = max_healers
            saved.max_dps = max_dps
            changed = true
            need_role_refresh = true
        end
    end

    local max_mdps = template_int(settings.max_mdps, saved.max_mdps or AB_const.DEFAULT_MAX_MDPS, 0, saved.max_dps or AB_const.DEFAULT_MAX_DPS)
    local max_rdps = template_int(settings.max_rdps, saved.max_rdps or AB_const.DEFAULT_MAX_RDPS, 0, saved.max_dps or AB_const.DEFAULT_MAX_DPS)
    if max_mdps + max_rdps ~= saved.max_dps then
        max_mdps, max_rdps = build_default_dps_weights(saved.max_dps)
    end
    if saved.max_mdps ~= max_mdps or saved.max_rdps ~= max_rdps then
        saved.max_mdps = max_mdps
        saved.max_rdps = max_rdps
        changed = true
        need_role_refresh = true
    end

    local dps_weighting_enabled = saved.dps_weighting_enabled
    if settings.dps_weighting_enabled ~= nil then
        dps_weighting_enabled = template_bool(settings.dps_weighting_enabled)
    end
    if saved.dps_weighting_enabled ~= dps_weighting_enabled then
        saved.dps_weighting_enabled = dps_weighting_enabled
        changed = true
        need_role_refresh = true
    end

    local algo_mode = template_int(settings.org_algo_mode, saved.org_algo_mode or AB_const.DEFAULT_ORG_ALGO, AB_const.MODE_SPREAD, AB_const.MODE_AGGREGATE)
    if saved.org_algo_mode ~= algo_mode then
        saved.org_algo_mode = algo_mode
        changed = true
    end

    local algo_role = settings.org_algo_role
    if algo_role == nil then
        algo_role = saved.org_algo_role
    end
    if type(algo_role) ~= "string" or AB_const.ROLE_CATEGORIES[algo_role] == nil then
        algo_role = AB_const.DEFAULT_ORG_ROLE
    end
    if saved.org_algo_role ~= algo_role then
        saved.org_algo_role = algo_role
        changed = true
    end

    local autokick_period = template_int(settings.autokick_period, saved.autokick_period or AB_const.KICK_PERIOD, 0, AB_const.MAX_KICKOFF_TIME)
    if saved.autokick_period ~= autokick_period then
        saved.autokick_period = autokick_period
        changed = true
    end

    local saved_rank_tank, saved_rank_healer, saved_rank_dps = AB_const.MINIMUM_RANK_TANK, AB_const.MINIMUM_RANK_HEALER, AB_const.MINIMUM_RANK_DPS
    if type(AutoBand.get_saved_rank_requirements) == "function" then
        saved_rank_tank, saved_rank_healer, saved_rank_dps = AutoBand.get_saved_rank_requirements(saved)
    end

    local min_rank_legacy = template_int(settings.min_rank, saved.min_rank or AB_const.MINIMUM_RANK, 0, AB_const.MAXIMUM_RANK)
    local min_rank_tank = template_int(settings.min_rank_tank, saved_rank_tank or min_rank_legacy, 0, AB_const.MAXIMUM_RANK)
    local min_rank_healer = template_int(settings.min_rank_healer, saved_rank_healer or min_rank_legacy, 0, AB_const.MAXIMUM_RANK)
    local min_rank_dps = template_int(settings.min_rank_dps, saved_rank_dps or min_rank_legacy, 0, AB_const.MAXIMUM_RANK)
    if settings.min_rank_tank == nil then
        min_rank_tank = min_rank_legacy
    end
    if settings.min_rank_dps == nil then
        min_rank_dps = min_rank_legacy
    end
    if type(AutoBand.normalize_rank_requirement_value) == "function" then
        min_rank_tank = AutoBand.normalize_rank_requirement_value(min_rank_tank, AB_const.MINIMUM_RANK_TANK)
        min_rank_healer = AutoBand.normalize_rank_requirement_value(min_rank_healer, AB_const.MINIMUM_RANK_HEALER)
        min_rank_dps = AutoBand.normalize_rank_requirement_value(min_rank_dps, AB_const.MINIMUM_RANK_DPS)
    end
    if min_rank_tank > 40 or min_rank_healer > 40 or min_rank_dps > 40 then
        local rr_allowed = false
        if type(AutoBand.can_use_realmrank_requirement) == "function" then
            rr_allowed = AutoBand.can_use_realmrank_requirement(true) == true
        end
        if not rr_allowed then
            if min_rank_tank > 40 then
                min_rank_tank = 40
            end
            if min_rank_healer > 40 then
                min_rank_healer = 40
            end
            if min_rank_dps > 40 then
                min_rank_dps = 40
            end
            notify_missing_rr = true
        end
    end
    if saved.min_rank_tank ~= min_rank_tank or saved.min_rank_healer ~= min_rank_healer or saved.min_rank_dps ~= min_rank_dps then
        if type(AutoBand.set_saved_rank_requirements) == "function" then
            AutoBand.set_saved_rank_requirements(min_rank_tank, min_rank_healer, min_rank_dps, saved)
        else
            saved.min_rank_tank = min_rank_tank
            saved.min_rank_healer = min_rank_healer
            saved.min_rank_dps = min_rank_dps
            if min_rank_tank > min_rank_dps then
                saved.min_rank = min_rank_tank
            else
                saved.min_rank = min_rank_dps
            end
        end
        changed = true
    end

    local threshold = template_int(settings.range_sort_distance_threshold, saved.range_sort_distance_threshold or AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD, 0, nil)
    if saved.range_sort_distance_threshold ~= threshold then
        saved.range_sort_distance_threshold = threshold
        changed = true
    end

    local radius_setting = settings.toofar_radius_setting
    if type(radius_setting) ~= "string" or not AB_const.TOOFAR_DISTANCE_VALUES[radius_setting] then
        radius_setting = AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    end
    if saved.toofar_radius_setting ~= radius_setting then
        saved.toofar_radius_setting = radius_setting
        changed = true
    end

    if settings.prefix_text ~= nil then
        apply_string("prefix_text", AutoBand.template_prefix_text(settings.prefix_text, saved.prefix_text or AB_const.DEFAULT_PREFIX_TEXT))
    end
    if settings.prefix_color_name ~= nil then
        apply_string("prefix_color_name", AutoBand.template_color_name(settings.prefix_color_name, saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME))
    end
    if settings.lead_color_name ~= nil then
        apply_string("lead_color_name", AutoBand.template_color_name(settings.lead_color_name, saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME))
    end

    apply_toggle_setter(AutoBand.set_autokick_enabled, "autokick_enabled", settings.autokick_enabled)
    apply_toggle_setter(AutoBand.set_autokick_toofar_enabled, "autokick_toofar_enabled", settings.autokick_toofar_enabled)
    apply_toggle_setter(AutoBand.set_autokick_low_rank_enabled, "autokick_low_rank_enabled", settings.autokick_low_rank_enabled)
    apply_toggle_setter(AutoBand.set_autokick_we_wh_enabled, "autokick_we_wh_enabled", settings.autokick_we_wh_enabled)
    apply_toggle_setter(AutoBand.set_autokick_rvrzone_enabled, "autokick_rvrzone_enabled", settings.autokick_rvrzone_enabled)
    apply_toggle_setter(AutoBand.set_autokick_ignorelist_enabled, "autokick_ignorelist_enabled", settings.autokick_ignorelist_enabled)
    apply_toggle_setter(AutoBand.set_backfill_enabled, "backfill_enabled", settings.backfill_enabled)
    apply_toggle_setter(AutoBand.set_backfill_no_headsups_enabled, "backfill_no_headsups_enabled", settings.backfill_no_headsups_enabled)
    apply_toggle_setter(AutoBand.set_use_common_race_names, "use_common_race_names", settings.use_common_race_names)
    apply_mode_setter(AutoBand.set_guild_priority_mode, "guild", settings.guild_priority_mode)
    apply_mode_setter(AutoBand.set_friend_priority_mode, "friend", settings.friend_priority_mode)
    apply_toggle_setter(AutoBand.set_guild_grouping_enabled, "guild_grouping_enabled", settings.guild_grouping_enabled)

    local prev_alt_speccheck_enabled = saved.alt_speccheck_enabled
    local prev_exclude_realm_healer_alt_spec = saved.exclude_realm_healer_alt_spec
    apply_bool("autonote_enabled", settings.autonote_enabled)
    apply_bool("autopartynote_enabled", settings.autopartynote_enabled)
    apply_bool("notify_buffs_enabled", settings.notify_buffs_enabled)
    apply_bool("restrict_same_race", settings.restrict_same_race)
    apply_bool("prefix_use_guild", settings.prefix_use_guild)
    apply_bool("right_click_organize_include_templates", settings.right_click_organize_include_templates)
    apply_bool("realmrank_lookup_enabled", settings.realmrank_lookup_enabled)
    apply_bool("alt_speccheck_enabled", settings.alt_speccheck_enabled)
    apply_bool("exclude_realm_healer_alt_spec", settings.exclude_realm_healer_alt_spec)
    if saved.alt_speccheck_enabled ~= prev_alt_speccheck_enabled or
        saved.exclude_realm_healer_alt_spec ~= prev_exclude_realm_healer_alt_spec then
        need_role_refresh = true
        AutoBand.mark_alt_spec_snapshot_dirty()
    end
    apply_bool("printrole_enabled", settings.printrole_enabled)
    apply_bool("print_arrival_notify_tags_enabled", settings.print_arrival_notify_tags_enabled)
    apply_bool("autoform_search_enabled", settings.autoform_search_enabled)
    apply_bool("search_discord_req_enabled", settings.search_discord_req_enabled)
    apply_bool("search_no_mic_enabled", settings.search_no_mic_enabled)
    if settings.bw_sorc_as_mdps ~= nil and saved.bw_sorc_as_mdps ~= template_bool(settings.bw_sorc_as_mdps) then
        saved.bw_sorc_as_mdps = template_bool(settings.bw_sorc_as_mdps)
        changed = true
        need_role_refresh = true
    end

    if need_role_refresh then
        AutoBand.need_role_update = true
        AutoBand.cache_dirty = true
    end

    if changed then
        mark_partynote_dirty()
        refresh_config_tab()
    end

    if notify_missing_rr and not (opts and opts.silent) then
        local template_name = opts and opts.template_name or "template"
        AB_util.print("[Warning] '" .. tostring(template_name) .. "' includes RR rank requirements, but RR updates are unavailable. Falling back to CR40.")
    end

    return changed
end

local function purge_autokick_commands()
    if AutoBand.cmd_current and AutoBand.cmd_current.source == "autokick" then
        AutoBand.cmd_current = nil
    end
    if not AutoBand.cmd_queue or #AutoBand.cmd_queue == 0 then
        return
    end
    local remaining = {}
    for i = 1, #AutoBand.cmd_queue do
        local entry = AutoBand.cmd_queue[i]
        if not (entry and entry.source == "autokick") then
            table.insert(remaining, entry)
        end
    end
    AutoBand.cmd_queue = remaining
end

local function purge_warband_commands()
    AutoBand.cmd_current = nil
    AutoBand.cmd_queue = {}
end

local function get_wbdata()
    if AutoBand and AutoBand.debugon and AutoBand.saved and type(AutoBand.saved.dumped_wb) == "table" then
        local dump = AutoBand.saved.dumped_wb
        if type(dump.group) == "table" then
            local wbdata = {}
            for gid, group in ipairs(dump.group) do
                wbdata[gid] = { players = group }
            end
            return wbdata
        end
    end
    if type(GetBattlegroupMemberData) ~= "function" then
        return nil
    end
    local ok, wbdata = pcall(GetBattlegroupMemberData)
    if not ok or type(wbdata) ~= "table" then
        return nil
    end
    return wbdata
end

local function get_wbdata_and_count()
    local wbdata = get_wbdata()
    if type(wbdata) ~= "table" then
        return nil, 0
    end
    local count = 0
    for _, grp in ipairs(wbdata) do
        if grp and type(grp.players) == "table" then
            count = count + #grp.players
        end
    end
    return wbdata, count
end

local function count_wb_players()
    local _, count = get_wbdata_and_count()
    return count
end

local function build_roster_signature(wbdata)
    if type(wbdata) ~= "table" then
        return nil, 0
    end

    local lookup = AutoBand.wb_roster_snapshot_lookup
    if type(lookup) ~= "table" then
        lookup = {}
        AutoBand.wb_roster_snapshot_lookup = lookup
    end

    local previous_count = tonumber(AutoBand.wb_roster_snapshot_count) or 0
    local previous_stamp = tonumber(AutoBand.wb_roster_snapshot_stamp) or 0
    local current_stamp = previous_stamp + 1
    local count = 0
    local player_count = 0
    local changed = false
    for _, grp in ipairs(wbdata) do
        if grp and type(grp.players) == "table" then
            for _, player in ipairs(grp.players) do
                if player and player.name then
                    player_count = player_count + 1
                    local name = tostring(player.name)
                    if lookup[name] ~= current_stamp then
                        if lookup[name] ~= previous_stamp then
                            changed = true
                        end
                        lookup[name] = current_stamp
                        count = count + 1
                    end
                end
            end
        end
    end

    if count ~= previous_count then
        changed = true
    end

    if changed then
        AutoBand.wb_roster_snapshot_count = count
        for key, stamp in pairs(lookup) do
            if stamp ~= current_stamp then
                lookup[key] = nil
            end
        end
        AutoBand.wb_roster_generation = (tonumber(AutoBand.wb_roster_generation) or 0) + 1
        AutoBand.wb_roster_signature = tostring(AutoBand.wb_roster_generation)
    elseif AutoBand.wb_roster_signature == nil then
        AutoBand.wb_roster_signature = ""
    end

    AutoBand.wb_roster_snapshot_stamp = current_stamp
    return AutoBand.wb_roster_signature, player_count
end

local function get_alt_spec_probe_uptime_seconds()
    if type(GetGameTime) ~= "function" then
        return nil
    end

    local ok_time, value = pcall(GetGameTime)
    if not ok_time then
        return nil
    end

    local as_number = tonumber(value)
    if as_number == nil or as_number < 0 then
        return nil
    end

    return math.floor(as_number)
end

local function mark_alt_spec_snapshot_dirty()
    AutoBand.alt_spec_snapshot_dirty = true
    AutoBand.alt_spec_snapshot_next_probe_s = nil
end

local function build_alt_spec_snapshot(force_refresh)
    if not AutoBand.saved or not AutoBand.saved.alt_speccheck_enabled then
        local cleared_lookup = AutoBand.alt_spec_snapshot_lookup
        if type(cleared_lookup) ~= "table" then
            cleared_lookup = {}
            AutoBand.alt_spec_snapshot_lookup = cleared_lookup
        else
            for key, _ in pairs(cleared_lookup) do
                cleared_lookup[key] = nil
            end
        end
        AutoBand.alt_spec_snapshot_count = 0
        AutoBand.alt_spec_snapshot_stamp = 0
        AutoBand.alt_spec_snapshot_signature = nil
        AutoBand.alt_spec_snapshot_dirty = false
        AutoBand.alt_spec_snapshot_next_probe_s = nil
        AutoBand.alt_spec_snapshot_raw_ref = nil
        return nil, nil
    end

    local now_s = get_alt_spec_probe_uptime_seconds()
    local raw = RoRGroupScoreboard and RoRGroupScoreboard.playersDataRaw
    local raw_ref_changed = raw ~= AutoBand.alt_spec_snapshot_raw_ref
    if force_refresh ~= true and AutoBand.alt_spec_snapshot_dirty ~= true then
        if type(AutoBand.alt_spec_snapshot_lookup) == "table" then
            if not raw_ref_changed and (
                now_s == nil or
                AutoBand.alt_spec_snapshot_next_probe_s == nil or
                now_s < AutoBand.alt_spec_snapshot_next_probe_s) then
                local cached_signature = AutoBand.alt_spec_snapshot_signature
                if cached_signature == nil then
                    cached_signature = ""
                    AutoBand.alt_spec_snapshot_signature = cached_signature
                end
                return AutoBand.alt_spec_snapshot_lookup, cached_signature
            end
        end
    end

    local lookup = AutoBand.alt_spec_snapshot_lookup
    if type(lookup) ~= "table" then
        lookup = {}
        AutoBand.alt_spec_snapshot_lookup = lookup
    end

    local previous_count = tonumber(AutoBand.alt_spec_snapshot_count) or 0
    local previous_stamp = tonumber(AutoBand.alt_spec_snapshot_stamp) or 0
    local current_stamp = previous_stamp + 1
    local count = 0
    local changed = false
    if raw then
        for _, pdata in pairs(raw) do
            if pdata and pdata.archtype and pdata.archtype > 0 and pdata.name then
                local name_s = tostring(pdata.name)
                if lookup[name_s] ~= current_stamp then
                    if lookup[name_s] ~= previous_stamp then
                        changed = true
                    end
                    lookup[name_s] = current_stamp
                    count = count + 1
                end
            end
        end
    end

    local previous_signature = AutoBand.alt_spec_snapshot_signature
    if count ~= previous_count then
        changed = true
    end

    if changed then
        AutoBand.alt_spec_snapshot_count = count
        for key, stamp in pairs(lookup) do
            if stamp ~= current_stamp then
                lookup[key] = nil
            end
        end
        if count > 0 then
            AutoBand.alt_spec_snapshot_generation = (tonumber(AutoBand.alt_spec_snapshot_generation) or 0) + 1
            AutoBand.alt_spec_snapshot_signature = tostring(AutoBand.alt_spec_snapshot_generation)
        else
            AutoBand.alt_spec_snapshot_signature = ""
        end
    elseif previous_signature == nil then
        AutoBand.alt_spec_snapshot_signature = ""
    end

    AutoBand.alt_spec_snapshot_stamp = current_stamp
    AutoBand.alt_spec_snapshot_dirty = false
    AutoBand.alt_spec_snapshot_raw_ref = raw
    if now_s ~= nil then
        AutoBand.alt_spec_snapshot_next_probe_s = now_s + ALT_SPEC_PROBE_SECONDS
    else
        AutoBand.alt_spec_snapshot_next_probe_s = nil
    end

    local signature = AutoBand.alt_spec_snapshot_signature
    if signature == nil then
        signature = ""
    end
    return AutoBand.alt_spec_snapshot_lookup, signature
end

function AutoBand.mark_alt_spec_snapshot_dirty()
    mark_alt_spec_snapshot_dirty()
end

local function build_alt_spec_signature(force_refresh)
    if not AutoBand.saved or not AutoBand.saved.alt_speccheck_enabled then
        return nil
    end
    local _, signature = build_alt_spec_snapshot(force_refresh)
    return signature
end

local function get_partynote_live_context(force_alt_refresh)
    local live_wbdata = get_wbdata()
    local live_roster_signature, live_player_count = build_roster_signature(live_wbdata)
    local expected_player_count = 0
    if AutoBand.cached_wb and type(AutoBand.cached_wb.player_count) == "number" then
        expected_player_count = AutoBand.cached_wb.player_count
    elseif type(AutoBand.last_wb_player_count) == "number" then
        expected_player_count = AutoBand.last_wb_player_count
    end
    if live_player_count ~= expected_player_count then
        AutoBand.cache_dirty = true
    end

    local alt_lookup = nil
    local live_alt_signature = AutoBand.alt_spec_signature
    if type(live_alt_signature) ~= "string" or
       force_alt_refresh == true or
       AutoBand.cache_dirty == true or
       AutoBand.alt_spec_snapshot_dirty == true then
        alt_lookup, live_alt_signature = build_alt_spec_snapshot(force_alt_refresh)
    end

    return live_wbdata, live_roster_signature, alt_lookup, live_alt_signature
end

local function normalize_wb_player_name(name_raw)
    if name_raw == nil then
        return nil, nil
    end
    local fixed = name_raw
    if AutoBand and AutoBand.FixString then
        local ok_fix, fixed_val = pcall(AutoBand.FixString, name_raw)
        if ok_fix and fixed_val ~= nil then
            fixed = fixed_val
        end
    end
    local ok_str, name_str = pcall(tostring, fixed)
    if not ok_str or name_str == nil or name_str == "" then
        return nil, nil
    end
    local ok_lower, name_lower = pcall(string.lower, name_str)
    if not ok_lower or name_lower == nil or name_lower == "" then
        return nil, nil
    end
    return name_lower, name_str
end

local function uppercase_first_character_ascii(text)
    if type(text) ~= "string" or text == "" then
        return text
    end
    local first = string.sub(text, 1, 1)
    local rest = string.sub(text, 2)
    local ok_upper, upper_first = pcall(string.upper, first)
    if ok_upper and upper_first and upper_first ~= "" then
        return upper_first .. rest
    end
    return text
end

local function build_arrival_lookup(order)
    local lookup = {}
    for i = 1, #order do
        lookup[order[i]] = i
    end
    return lookup
end

function AutoBand.normalize_wb_player_name(name_raw)
    return normalize_wb_player_name(name_raw)
end

local function normalize_name_lowercase(name_raw)
    local lowered = normalize_wb_player_name(name_raw)
    return lowered
end

local SOCIAL_PRIORITY_MODE_ORDER = {
    [AB_const.SOCIAL_PRIORITY_MODE_OFF] = 0,
    [AB_const.SOCIAL_PRIORITY_MODE_PREFER] = 1,
    [AB_const.SOCIAL_PRIORITY_MODE_PROTECT] = 2,
    [AB_const.SOCIAL_PRIORITY_MODE_PROMOTE] = 3
}

local function canonicalize_social_priority_mode(mode)
    local raw = mode
    if raw == true then
        raw = AB_const.SOCIAL_PRIORITY_MODE_PREFER
    elseif raw == false then
        raw = AB_const.SOCIAL_PRIORITY_MODE_OFF
    end

    if raw ~= nil then
        local ok_lower, lowered = pcall(string.lower, tostring(raw))
        if ok_lower and lowered and SOCIAL_PRIORITY_MODE_ORDER[lowered] ~= nil then
            return lowered
        end
    end

    return nil
end

local function normalize_social_priority_mode(mode, fallback)
    local normalized = canonicalize_social_priority_mode(mode)
    if normalized ~= nil then
        return normalized
    end

    if fallback ~= nil then
        local fallback_normalized = canonicalize_social_priority_mode(fallback)
        if fallback_normalized ~= nil then
            return fallback_normalized
        end
    end

    return AB_const.SOCIAL_PRIORITY_MODE_OFF
end

function AutoBand.normalize_social_priority_mode(mode, fallback)
    return normalize_social_priority_mode(mode, fallback)
end

function AutoBand.get_social_priority_mode_rank(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    return SOCIAL_PRIORITY_MODE_ORDER[normalized] or 0
end

local function get_social_priority_mode_trim_rank(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    if normalized == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE then
        normalized = AB_const.SOCIAL_PRIORITY_MODE_PROTECT
    end
    return SOCIAL_PRIORITY_MODE_ORDER[normalized] or 0
end

local function social_priority_mode_grants_rank_exemption(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    return normalized == AB_const.SOCIAL_PRIORITY_MODE_PROTECT or normalized == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
end

local function social_priority_mode_grants_toofar_exemption(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    return normalized == AB_const.SOCIAL_PRIORITY_MODE_PROTECT or normalized == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
end

local function social_priority_mode_is_promote(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    return normalized == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
end

function AutoBand.get_social_priority_mode_label(mode)
    local normalized = normalize_social_priority_mode(mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    if normalized == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE then
        return "Promote"
    elseif normalized == AB_const.SOCIAL_PRIORITY_MODE_PROTECT then
        return "Protect"
    elseif normalized == AB_const.SOCIAL_PRIORITY_MODE_PREFER then
        return "Prefer"
    end
    return "Off"
end

local function get_social_priority_mode_field_name(source_key)
    if source_key == "friend" then
        return "friend_priority_mode", "friend_priority_enabled"
    end
    return "guild_priority_mode", "guild_priority_enabled"
end

local function derive_legacy_social_priority_mode(source_key, container)
    container = container or {}
    local _, legacy_enabled_field = get_social_priority_mode_field_name(source_key)
    if container[legacy_enabled_field] ~= true then
        return AB_const.SOCIAL_PRIORITY_MODE_OFF
    end
    if container.priority_ignore_rank_restrictions_enabled == true then
        return AB_const.SOCIAL_PRIORITY_MODE_PROTECT
    end
    return AB_const.SOCIAL_PRIORITY_MODE_PREFER
end

function AutoBand.get_saved_social_priority_mode(source_key, container)
    container = container or AutoBand.saved or {}
    local mode_field = get_social_priority_mode_field_name(source_key)
    local current = container[mode_field]
    local normalized = canonicalize_social_priority_mode(current)
    if normalized ~= nil then
        return normalized
    end
    return derive_legacy_social_priority_mode(source_key, container)
end

function AutoBand.build_name_membership_set(raw_rows)
    local lookup = {}
    if type(raw_rows) ~= "table" then
        return lookup
    end

    for _, entry in pairs(raw_rows) do
        local name_raw = nil
        if type(entry) == "table" then
            name_raw = entry.name or entry.m_memberName
        elseif entry ~= nil then
            name_raw = entry
        end
        local key = normalize_wb_player_name(name_raw)
        if key then
            lookup[key] = true
        end
    end

    return lookup
end

local function ab_social_list_copy_membership_set(source)
    local copy = {}
    if type(source) ~= "table" then
        return copy
    end

    for key, value in pairs(source) do
        if value == true then
            copy[key] = true
        end
    end

    return copy
end

local function ab_social_list_count_membership_entries(source)
    local count = 0
    if type(source) ~= "table" then
        return 0
    end

    for _, value in pairs(source) do
        if value == true then
            count = count + 1
        end
    end

    return count
end

local function ab_social_list_build_membership_set_checksum(source)
    if type(source) ~= "table" then
        return ""
    end

    local names = {}
    for key, value in pairs(source) do
        if value == true then
            table.insert(names, key)
        end
    end

    if #names == 0 then
        return ""
    end

    table.sort(names)
    return table.concat(names, "|")
end

local function ab_social_list_get_uptime_seconds()
    if type(GetGameTime) ~= "function" then
        return nil
    end

    local ok_time, value = pcall(GetGameTime)
    if not ok_time then
        return nil
    end

    local as_number = tonumber(value)
    if as_number == nil or as_number < 0 then
        return nil
    end

    return math.floor(as_number)
end

local function get_rank_requirement_grace_seconds()
    local grace_seconds = tonumber(AB_const and AB_const.RANK_REQUIREMENT_CHANGE_GRACE_SECONDS) or 0
    grace_seconds = math.floor(grace_seconds)
    if grace_seconds < 0 then
        grace_seconds = 0
    end
    return grace_seconds
end

local function get_rank_requirement_grace_heartbeat_count()
    local grace_seconds = get_rank_requirement_grace_seconds()
    if grace_seconds <= 0 then
        return 0
    end

    local heartbeat_s = tonumber(AB_const and AB_const.HEARTBEAT) or 5
    heartbeat_s = math.floor(heartbeat_s)
    if heartbeat_s <= 0 then
        heartbeat_s = 5
    end

    local ticks = math.floor((grace_seconds + heartbeat_s - 1) / heartbeat_s)
    if ticks < 1 then
        ticks = 1
    end
    return ticks
end

function AutoBand.get_uptime_seconds()
    return ab_social_list_get_uptime_seconds()
end

function AutoBand.clear_rank_requirement_grace()
    AutoBand.rank_requirement_grace_until_s = nil
    AutoBand.rank_requirement_grace_ticks_remaining = 0
end

function AutoBand.arm_rank_requirement_grace()
    -- Only arm the pause when low-rank enforcement is already live; changing
    -- thresholds while /ab akl is off should not defer enforcement later.
    if not (AutoBand and AutoBand.saved and AutoBand.saved.autokick_low_rank_enabled == true) or
       (AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled()) then
        AutoBand.clear_rank_requirement_grace()
        return false
    end

    local grace_seconds = get_rank_requirement_grace_seconds()
    if grace_seconds <= 0 then
        AutoBand.clear_rank_requirement_grace()
        return false
    end

    local now_s = AutoBand.get_uptime_seconds()
    if now_s ~= nil then
        AutoBand.rank_requirement_grace_until_s = now_s + grace_seconds
    else
        AutoBand.rank_requirement_grace_until_s = nil
    end
    AutoBand.rank_requirement_grace_ticks_remaining = get_rank_requirement_grace_heartbeat_count()
    return true
end

function AutoBand.get_rank_requirement_grace_remaining_seconds()
    local now_s = AutoBand.get_uptime_seconds()
    local until_s = tonumber(AutoBand.rank_requirement_grace_until_s)
    if now_s ~= nil and until_s ~= nil then
        local remaining = until_s - now_s
        if remaining > 0 then
            return remaining
        end
        AutoBand.clear_rank_requirement_grace()
        return 0
    end

    local ticks_remaining = tonumber(AutoBand.rank_requirement_grace_ticks_remaining) or 0
    if ticks_remaining > 0 then
        local heartbeat_s = tonumber(AB_const and AB_const.HEARTBEAT) or 5
        heartbeat_s = math.floor(heartbeat_s)
        if heartbeat_s <= 0 then
            heartbeat_s = 5
        end
        return ticks_remaining * heartbeat_s
    end

    return 0
end

function AutoBand.is_rank_requirement_grace_active()
    return AutoBand.get_rank_requirement_grace_remaining_seconds() > 0
end

function AutoBand.clear_social_priority_grace()
    AutoBand.social_priority_grace_until_s = nil
    AutoBand.social_priority_grace_ticks_remaining = 0
end

function AutoBand.arm_social_priority_grace()
    -- Match the rank-change grace behavior: only arm when role-cap or rank
    -- enforcement is already live. If both are off, later enabling should use
    -- the current mode immediately.
    local saved = AutoBand and AutoBand.saved
    if not saved or (saved.autokick_enabled ~= true and saved.autokick_low_rank_enabled ~= true) or
       (AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled()) then
        AutoBand.clear_social_priority_grace()
        return false
    end

    local grace_seconds = get_rank_requirement_grace_seconds()
    if grace_seconds <= 0 then
        AutoBand.clear_social_priority_grace()
        return false
    end

    local now_s = AutoBand.get_uptime_seconds()
    if now_s ~= nil then
        AutoBand.social_priority_grace_until_s = now_s + grace_seconds
    else
        AutoBand.social_priority_grace_until_s = nil
    end
    AutoBand.social_priority_grace_ticks_remaining = get_rank_requirement_grace_heartbeat_count()
    return true
end

function AutoBand.get_social_priority_grace_remaining_seconds()
    local now_s = AutoBand.get_uptime_seconds()
    local until_s = tonumber(AutoBand.social_priority_grace_until_s)
    if now_s ~= nil and until_s ~= nil then
        local remaining = until_s - now_s
        if remaining > 0 then
            return remaining
        end
        AutoBand.clear_social_priority_grace()
        return 0
    end

    local ticks_remaining = tonumber(AutoBand.social_priority_grace_ticks_remaining) or 0
    if ticks_remaining > 0 then
        local heartbeat_s = tonumber(AB_const and AB_const.HEARTBEAT) or 5
        heartbeat_s = math.floor(heartbeat_s)
        if heartbeat_s <= 0 then
            heartbeat_s = 5
        end
        return ticks_remaining * heartbeat_s
    end

    return 0
end

function AutoBand.is_social_priority_grace_active()
    return AutoBand.get_social_priority_grace_remaining_seconds() > 0
end

-- Bucket fields:
--   snapshot: normalized lowercase membership set
--   count: cached member count
--   has_snapshot: whether snapshot reflects a completed read (including empty)
--   dirty: whether the next getter call should attempt a refresh
--   signature: guild identity fence for guild snapshots
--   last_checksum: checksum of the last accepted non-empty/empty snapshot
--   last_good_uptime_s: uptime when the last non-empty snapshot was accepted
--   retry_after_uptime_s: throttle point for retrying after bad reads
local function ab_social_list_ensure_cache_bucket(list_key)
    if type(AutoBand.social_list_cache) ~= "table" then
        AutoBand.social_list_cache = {}
    end

    local bucket = AutoBand.social_list_cache[list_key]
    if type(bucket) ~= "table" then
        bucket = {}
        AutoBand.social_list_cache[list_key] = bucket
    end
    if type(bucket.snapshot) ~= "table" then
        bucket.snapshot = {}
    end
    if type(bucket.count) ~= "number" then
        bucket.count = ab_social_list_count_membership_entries(bucket.snapshot)
    end
    if type(bucket.empty_streak) ~= "number" then
        bucket.empty_streak = 0
    end
    if type(bucket.dirty) ~= "boolean" then
        bucket.dirty = true
    end
    if type(bucket.has_snapshot) ~= "boolean" then
        bucket.has_snapshot = bucket.count > 0
    end
    if bucket.last_good_uptime_s ~= nil and type(bucket.last_good_uptime_s) ~= "number" then
        bucket.last_good_uptime_s = nil
    end
    if bucket.retry_after_uptime_s ~= nil and type(bucket.retry_after_uptime_s) ~= "number" then
        bucket.retry_after_uptime_s = nil
    end
    if bucket.last_checksum ~= nil and type(bucket.last_checksum) ~= "string" then
        bucket.last_checksum = nil
    end

    return bucket
end

local function ab_social_list_reset_cache_bucket(bucket, signature)
    if type(bucket) ~= "table" then
        return
    end

    bucket.snapshot = {}
    bucket.count = 0
    bucket.empty_streak = 0
    bucket.signature = signature
    bucket.last_good_uptime_s = nil
    bucket.retry_after_uptime_s = nil
    bucket.last_checksum = nil
    bucket.has_snapshot = false
    bucket.dirty = true
end

local function ab_social_list_accept_snapshot(bucket, snapshot, signature, now_s, checksum)
    local stored = ab_social_list_copy_membership_set(snapshot)
    bucket.snapshot = stored
    bucket.count = ab_social_list_count_membership_entries(stored)
    bucket.empty_streak = 0
    bucket.signature = signature
    bucket.last_good_uptime_s = now_s
    bucket.retry_after_uptime_s = nil
    bucket.last_checksum = checksum
    bucket.has_snapshot = true
    bucket.dirty = false
end

local function ab_social_list_get_cached_snapshot(bucket)
    if type(bucket) ~= "table" then
        return {}
    end
    return ab_social_list_copy_membership_set(bucket.snapshot)
end

local function ab_social_list_get_cached_snapshot_ref(bucket)
    if type(bucket) ~= "table" or type(bucket.snapshot) ~= "table" then
        return {}
    end
    return bucket.snapshot
end

local function ab_social_list_mark_cache_dirty(list_key)
    local bucket = ab_social_list_ensure_cache_bucket(list_key)
    bucket.dirty = true
    bucket.retry_after_uptime_s = nil
end

local function ab_social_list_cache_is_still_fresh(bucket, now_s)
    if type(bucket) ~= "table" or bucket.has_snapshot ~= true or bucket.count <= 0 then
        return false
    end

    if now_s ~= nil and bucket.last_good_uptime_s ~= nil then
        local age = now_s - bucket.last_good_uptime_s
        if age < 0 then
            bucket.last_good_uptime_s = now_s
            bucket.empty_streak = 0
            return true
        end
        return age <= AB_SOCIAL_LIST_CACHE_GRACE_SECONDS
    end

    bucket.empty_streak = bucket.empty_streak + 1
    return bucket.empty_streak <= AB_SOCIAL_LIST_CACHE_GRACE_READS
end

local function ab_social_list_get_cached_membership_set(list_key, fetch_rows_fn, opts)
    opts = opts or {}
    local return_ref = opts.return_ref == true

    local bucket = ab_social_list_ensure_cache_bucket(list_key)
    local signature = opts.signature
    local now_s = ab_social_list_get_uptime_seconds()

    local function emit_cached_snapshot()
        if return_ref then
            return ab_social_list_get_cached_snapshot_ref(bucket)
        end
        return ab_social_list_get_cached_snapshot(bucket)
    end

    if opts.clear_on_signature_change then
        if signature == nil then
            ab_social_list_reset_cache_bucket(bucket, nil)
            return {}
        end
        if bucket.signature ~= nil and bucket.signature ~= signature then
            ab_social_list_reset_cache_bucket(bucket, signature)
        end
    end

    if bucket.dirty ~= true and bucket.has_snapshot == true then
        return emit_cached_snapshot()
    end

    if type(fetch_rows_fn) ~= "function" then
        if ab_social_list_cache_is_still_fresh(bucket, now_s) then
            return emit_cached_snapshot()
        end
        ab_social_list_reset_cache_bucket(bucket, signature)
        if now_s ~= nil then
            bucket.retry_after_uptime_s = now_s + AB_SOCIAL_LIST_RETRY_SECONDS
        end
        return {}
    end

    if now_s ~= nil and bucket.retry_after_uptime_s ~= nil and now_s < bucket.retry_after_uptime_s then
        if ab_social_list_cache_is_still_fresh(bucket, now_s) then
            return emit_cached_snapshot()
        end
        return {}
    end

    local ok_rows, rows = pcall(fetch_rows_fn)
    if not ok_rows or type(rows) ~= "table" then
        if now_s ~= nil then
            bucket.retry_after_uptime_s = now_s + AB_SOCIAL_LIST_RETRY_SECONDS
        end
        bucket.dirty = true
        if ab_social_list_cache_is_still_fresh(bucket, now_s) then
            return emit_cached_snapshot()
        end
        ab_social_list_reset_cache_bucket(bucket, signature)
        if now_s ~= nil then
            bucket.retry_after_uptime_s = now_s + AB_SOCIAL_LIST_RETRY_SECONDS
        end
        return {}
    end

    local snapshot = AutoBand.build_name_membership_set(rows)
    local snapshot_count = ab_social_list_count_membership_entries(snapshot)
    local checksum = ab_social_list_build_membership_set_checksum(snapshot)
    if snapshot_count > 0 then
        if bucket.has_snapshot == true and bucket.last_checksum == checksum then
            bucket.empty_streak = 0
            bucket.signature = signature
            bucket.last_good_uptime_s = now_s
            bucket.retry_after_uptime_s = nil
            bucket.dirty = false
            return emit_cached_snapshot()
        end
        ab_social_list_accept_snapshot(bucket, snapshot, signature, now_s, checksum)
        return emit_cached_snapshot()
    end

    if ab_social_list_cache_is_still_fresh(bucket, now_s) then
        if now_s ~= nil then
            bucket.retry_after_uptime_s = now_s + AB_SOCIAL_LIST_RETRY_SECONDS
        end
        bucket.signature = signature
        bucket.dirty = true
        return emit_cached_snapshot()
    end

    ab_social_list_accept_snapshot(bucket, {}, signature, now_s, checksum)
    return emit_cached_snapshot()
end

function AutoBand.get_guild_membership_set()
    if type(AutoBand.GetCurrentGuildInfo) ~= "function" then
        return {}
    end

    local guild_info = AutoBand.GetCurrentGuildInfo()
    if guild_info == nil then
        ab_social_list_reset_cache_bucket(ab_social_list_ensure_cache_bucket("guild"), nil)
        return {}
    end

    local guild_signature = tostring(guild_info.id or "") .. "|" .. tostring(guild_info.name or "")
    return ab_social_list_get_cached_membership_set("guild", GetGuildMemberData, {
        signature = guild_signature,
        clear_on_signature_change = true
    })
end

function AutoBand.get_friend_membership_set()
    return ab_social_list_get_cached_membership_set("friend", GetFriendsList)
end

function AutoBand.get_ignore_membership_set()
    return ab_social_list_get_cached_membership_set("ignore", GetIgnoreList)
end

function AutoBand.get_guild_membership_set_ref()
    if type(AutoBand.GetCurrentGuildInfo) ~= "function" then
        return {}
    end

    local guild_info = AutoBand.GetCurrentGuildInfo()
    if guild_info == nil then
        ab_social_list_reset_cache_bucket(ab_social_list_ensure_cache_bucket("guild"), nil)
        return {}
    end

    local guild_signature = tostring(guild_info.id or "") .. "|" .. tostring(guild_info.name or "")
    return ab_social_list_get_cached_membership_set("guild", GetGuildMemberData, {
        signature = guild_signature,
        clear_on_signature_change = true,
        return_ref = true
    })
end

function AutoBand.get_friend_membership_set_ref()
    return ab_social_list_get_cached_membership_set("friend", GetFriendsList, { return_ref = true })
end

function AutoBand.get_ignore_membership_set_ref()
    return ab_social_list_get_cached_membership_set("ignore", GetIgnoreList, { return_ref = true })
end

function AutoBand.OnSocialFriendsUpdated()
    if not AutoBand.is_warband_enabled() then
        return
    end
    ab_social_list_mark_cache_dirty("friend")
    return AutoBand.get_friend_membership_set()
end

function AutoBand.OnSocialIgnoreUpdated()
    if not AutoBand.is_warband_enabled() then
        return
    end
    ab_social_list_mark_cache_dirty("ignore")
    return AutoBand.get_ignore_membership_set()
end

function AutoBand.OnGuildMembershipUpdated()
    if not AutoBand.is_warband_enabled() then
        return
    end
    ab_social_list_mark_cache_dirty("guild")
    return AutoBand.get_guild_membership_set()
end

local function ab_social_list_get_debug_label(list_key)
    if list_key == "guild" then
        return "guild"
    elseif list_key == "friend" then
        return "friends"
    elseif list_key == "ignore" then
        return "ignore"
    end
    return tostring(list_key or "unknown")
end

local function ab_social_list_get_membership_getter(list_key)
    if list_key == "guild" then
        return AutoBand.get_guild_membership_set
    elseif list_key == "friend" then
        return AutoBand.get_friend_membership_set
    elseif list_key == "ignore" then
        return AutoBand.get_ignore_membership_set
    end
    return nil
end

local function ab_social_list_feature_enabled_for(list_key)
    local saved = AutoBand.saved or {}
    if list_key == "guild" then
        return AutoBand.get_saved_social_priority_mode("guild", saved) ~= AB_const.SOCIAL_PRIORITY_MODE_OFF
    elseif list_key == "friend" then
        return AutoBand.get_saved_social_priority_mode("friend", saved) ~= AB_const.SOCIAL_PRIORITY_MODE_OFF
    elseif list_key == "ignore" then
        return saved.autokick_ignorelist_enabled == true
    end

    return false
end

local function ab_social_list_get_sorted_keys(bucket)
    local names = {}
    if type(bucket) ~= "table" or type(bucket.snapshot) ~= "table" then
        return names
    end

    for key, value in pairs(bucket.snapshot) do
        if value == true then
            table.insert(names, key)
        end
    end
    table.sort(names)
    return names
end

local function ab_social_list_build_debug_state(bucket, now_s)
    if type(bucket) ~= "table" then
        return "unknown"
    end
    if bucket.dirty == true then
        if bucket.has_snapshot == true and bucket.count > 0 then
            return "stale snapshot"
        end
        if bucket.retry_after_uptime_s ~= nil and now_s ~= nil and bucket.retry_after_uptime_s > now_s then
            return "retry pending"
        end
        return "dirty"
    end
    if bucket.has_snapshot == true and bucket.count == 0 then
        return "empty"
    end
    return "clean"
end

local function ab_social_list_print_cache_debug(list_key)
    local bucket = ab_social_list_ensure_cache_bucket(list_key)
    local now_s = ab_social_list_get_uptime_seconds()
    local label = ab_social_list_get_debug_label(list_key)
    local state = ab_social_list_build_debug_state(bucket, now_s)
    local extra = ""

    if now_s ~= nil and bucket.retry_after_uptime_s ~= nil and bucket.retry_after_uptime_s > now_s then
        extra = extra .. ", retry_in=" .. tostring(bucket.retry_after_uptime_s - now_s) .. "s"
    end
    if now_s ~= nil and bucket.last_good_uptime_s ~= nil and bucket.count > 0 then
        extra = extra .. ", age=" .. tostring(now_s - bucket.last_good_uptime_s) .. "s"
    end

    AB_util.print("[Debug] AutoBand social " .. label .. ": " .. tostring(bucket.count or 0) .. " entries, state=" .. state .. extra)
    local names = ab_social_list_get_sorted_keys(bucket)
    if #names == 0 then
        AB_util.print("  (none)")
        return
    end

    local start_index = 1
    local per_line = 8
    while start_index <= #names do
        local stop_index = math.min(#names, start_index + per_line - 1)
        local row = {}
        for i = start_index, stop_index do
            row[#row + 1] = names[i]
        end
        AB_util.print("  " .. table.concat(row, ", "))
        start_index = stop_index + 1
    end
end

local function ab_social_list_parse_debug_targets(args)
    local raw = nil
    if type(args) == "table" and type(args[1]) == "string" then
        raw = string.lower(args[1])
    end

    if raw == nil or raw == "" or raw == "all" then
        return { "guild", "friend", "ignore" }
    elseif raw == "guild" or raw == "guilds" then
        return { "guild" }
    elseif raw == "friend" or raw == "friends" then
        return { "friend" }
    elseif raw == "ignore" or raw == "ignores" or raw == "ignorelist" then
        return { "ignore" }
    end

    return nil
end

local function ab_social_list_background_refresh_is_enabled_for(list_key)
    return ab_social_list_feature_enabled_for(list_key)
end

local function ab_social_list_begin_bootstrap_refresh()
    local targets = {}
    local all_targets = { "guild", "friend", "ignore" }
    for i = 1, #all_targets do
        local list_key = all_targets[i]
        if ab_social_list_feature_enabled_for(list_key) then
            targets[#targets + 1] = list_key
            ab_social_list_mark_cache_dirty(list_key)
        end
    end

    AutoBand.social_list_bootstrap_targets = targets
    AutoBand.social_list_bootstrap_pending = #targets > 0
    AutoBand.social_list_bootstrap_elapsed = 0
    AutoBand.social_list_bootstrap_attempts = 0
    AutoBand.social_list_refresh_elapsed = 0
end

local function ab_social_list_bootstrap_is_satisfied()
    local targets = AutoBand.social_list_bootstrap_targets or {}
    if #targets == 0 then
        return true
    end
    for i = 1, #targets do
        local bucket = ab_social_list_ensure_cache_bucket(targets[i])
        if bucket.has_snapshot ~= true then
            return false
        end
    end
    return true
end

local function ab_social_list_try_refresh_enabled_targets()
    local targets = { "guild", "friend", "ignore" }
    for i = 1, #targets do
        local list_key = targets[i]
        if ab_social_list_background_refresh_is_enabled_for(list_key) then
            local getter = ab_social_list_get_membership_getter(list_key)
            if getter ~= nil then
                ab_social_list_mark_cache_dirty(list_key)
                getter()
            end
        end
    end
end

local function ab_social_list_maybe_bootstrap_refresh(elapsed)
    if AutoBand.social_list_bootstrap_pending ~= true then
        return
    end
    if type(elapsed) ~= "number" or elapsed <= 0 then
        return
    end
    if ab_social_list_bootstrap_is_satisfied() then
        AutoBand.social_list_bootstrap_pending = false
        AutoBand.social_list_bootstrap_targets = nil
        return
    end

    AutoBand.social_list_bootstrap_elapsed = (tonumber(AutoBand.social_list_bootstrap_elapsed) or 0) + elapsed
    if AutoBand.social_list_bootstrap_elapsed < AB_SOCIAL_LIST_BOOTSTRAP_REFRESH_SECONDS then
        return
    end
    AutoBand.social_list_bootstrap_elapsed = 0
    AutoBand.social_list_bootstrap_attempts = (tonumber(AutoBand.social_list_bootstrap_attempts) or 0) + 1
    ab_social_list_try_refresh_enabled_targets()
    if ab_social_list_bootstrap_is_satisfied()
        or AutoBand.social_list_bootstrap_attempts >= AB_SOCIAL_LIST_BOOTSTRAP_MAX_ATTEMPTS then
        AutoBand.social_list_bootstrap_pending = false
        AutoBand.social_list_bootstrap_targets = nil
    end
end

local function ab_social_list_maybe_background_refresh(elapsed)
    if type(elapsed) ~= "number" or elapsed <= 0 then
        return
    end

    AutoBand.social_list_refresh_elapsed = (tonumber(AutoBand.social_list_refresh_elapsed) or 0) + elapsed
    if AutoBand.social_list_refresh_elapsed < AB_SOCIAL_LIST_BACKGROUND_REFRESH_SECONDS then
        return
    end
    AutoBand.social_list_refresh_elapsed = 0

    ab_social_list_try_refresh_enabled_targets()
end

function AutoBand.get_effective_social_priority_mode(player_name_raw, guild_member_set, friend_member_set, container)
    local key = normalize_wb_player_name(player_name_raw)
    if not key then
        return AB_const.SOCIAL_PRIORITY_MODE_OFF, false, false
    end

    local guild_match = guild_member_set and guild_member_set[key] == true or false
    local friend_match = friend_member_set and friend_member_set[key] == true or false
    local effective_rank = 0

    if guild_match then
        local guild_rank = AutoBand.get_social_priority_mode_rank(AutoBand.get_saved_social_priority_mode("guild", container))
        if guild_rank > effective_rank then
            effective_rank = guild_rank
        end
    end
    if friend_match then
        local friend_rank = AutoBand.get_social_priority_mode_rank(AutoBand.get_saved_social_priority_mode("friend", container))
        if friend_rank > effective_rank then
            effective_rank = friend_rank
        end
    end

    if effective_rank >= SOCIAL_PRIORITY_MODE_ORDER[AB_const.SOCIAL_PRIORITY_MODE_PROMOTE] then
        return AB_const.SOCIAL_PRIORITY_MODE_PROMOTE, guild_match, friend_match
    elseif effective_rank >= SOCIAL_PRIORITY_MODE_ORDER[AB_const.SOCIAL_PRIORITY_MODE_PROTECT] then
        return AB_const.SOCIAL_PRIORITY_MODE_PROTECT, guild_match, friend_match
    elseif effective_rank >= SOCIAL_PRIORITY_MODE_ORDER[AB_const.SOCIAL_PRIORITY_MODE_PREFER] then
        return AB_const.SOCIAL_PRIORITY_MODE_PREFER, guild_match, friend_match
    end

    return AB_const.SOCIAL_PRIORITY_MODE_OFF, guild_match, friend_match
end

local function get_toofar_social_priority_membership_sets(container)
    container = container or AutoBand.saved or {}

    local guild_mode = AutoBand.get_saved_social_priority_mode("guild", container)
    local friend_mode = AutoBand.get_saved_social_priority_mode("friend", container)
    if not social_priority_mode_grants_toofar_exemption(guild_mode) and
       not social_priority_mode_grants_toofar_exemption(friend_mode) then
        return nil, nil
    end

    return AutoBand.get_guild_membership_set_ref(), AutoBand.get_friend_membership_set_ref()
end

local function player_is_exempt_from_toofar_kick(player_name_raw, guild_member_set, friend_member_set, container)
    if player_name_raw == nil or (guild_member_set == nil and friend_member_set == nil) then
        return false
    end

    local social_mode = AutoBand.get_effective_social_priority_mode(player_name_raw, guild_member_set, friend_member_set, container)
    return social_priority_mode_grants_toofar_exemption(social_mode)
end

local function migrate_social_priority_settings_container(container)
    if type(container) ~= "table" then
        return false, false
    end

    local changed = false
    local needs_review = false
    local shared_ignore = container.priority_ignore_rank_restrictions_enabled == true

    local function migrate_source(source_key)
        local mode_field, legacy_enabled_field = get_social_priority_mode_field_name(source_key)
        local raw_mode = container[mode_field]
        local normalized = canonicalize_social_priority_mode(raw_mode)
        if normalized ~= nil then
            if normalized ~= raw_mode then
                container[mode_field] = normalized
                changed = true
            end
        else
            container[mode_field] = derive_legacy_social_priority_mode(source_key, container)
            changed = true
        end
        if shared_ignore and container[legacy_enabled_field] ~= true then
            needs_review = true
        end
    end

    migrate_source("guild")
    migrate_source("friend")

    if type(container.guild_grouping_enabled) ~= "boolean" then
        container.guild_grouping_enabled = AB_const.GUILD_GROUPING_ENABLED
        changed = true
    end

    return changed, needs_review
end

function AutoBand.migrate_social_priority_settings_container(container)
    return migrate_social_priority_settings_container(container)
end

function AutoBand.migrate_social_priority_saved_state()
    local saved = AutoBand.saved or {}
    local needs_review = false

    local _, review_main = migrate_social_priority_settings_container(saved)
    if review_main then
        needs_review = true
    end

    if type(saved.normal_template_settings) == "table" then
        local _, review_normal = migrate_social_priority_settings_container(saved.normal_template_settings)
        if review_normal then
            needs_review = true
        end
    end

    if type(saved.templates) == "table" then
        for _, template_data in pairs(saved.templates) do
            local settings = nil
            if type(AutoBand.template_get_settings) == "function" then
                settings = AutoBand.template_get_settings(template_data)
            end
            if type(settings) == "table" then
                local _, review_template = migrate_social_priority_settings_container(settings)
                if review_template then
                    needs_review = true
                end
            end
        end
    end

    if saved.social_priority_migration_v1 ~= true then
        if needs_review then
            AB_util.print("[Warning] Legacy social-priority settings were migrated conservatively. Review the new Social settings.")
        end
        saved.social_priority_migration_v1 = true
    end
end

local function trim_string(raw)
    if raw == nil then
        return nil
    end
    if type(raw) ~= "string" then
        local ok_str, raw_str = pcall(tostring, raw)
        if not ok_str or raw_str == nil then
            return nil
        end
        raw = raw_str
    end
    raw = string.gsub(raw, "^%s+", "")
    raw = string.gsub(raw, "%s+$", "")
    if raw == "" then
        return nil
    end
    return raw
end

local function parse_first_integer(raw)
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

local function parse_first_number(raw)
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

AutoBand._core_api = AutoBand._core_api or {}
AutoBand._core_api.trim_string = trim_string
AutoBand._core_api.parse_first_integer = parse_first_integer
AutoBand._core_api.parse_first_number = parse_first_number
AutoBand._core_api.uppercase_first_character_ascii = uppercase_first_character_ascii
AutoBand._core_api.normalize_wb_player_name = normalize_wb_player_name
AutoBand._core_api.build_alt_spec_snapshot = build_alt_spec_snapshot

local function load_autoband_module(module_name, file_name)
    if type(dofile) == "function" then
        local ok = pcall(dofile, file_name)
        if ok then
            return true
        end
    end
    if type(require) == "function" then
        if type(package) == "table" and type(package.loaded) == "table" then
            package.loaded[module_name] = nil
        end
        local ok_require = pcall(require, module_name)
        if ok_require then
            return true
        end
    end
    return false
end

load_autoband_module("AB_realmrank", "AB_realmrank.lua")
load_autoband_module("AB_stats", "AB_stats.lua")

function AutoBand.get_arrival_index(name_raw)
    if not AutoBand.wb_arrival_lookup or not AutoBand.wb_arrival_order then
        return nil, nil
    end
    local key = AutoBand.normalize_wb_player_name(name_raw)
    if not key then
        return nil, nil
    end
    local idx = AutoBand.wb_arrival_lookup[key]
    if not idx then
        return nil, nil
    end
    return idx, #AutoBand.wb_arrival_order
end

function AutoBand.format_arrival_tag(name_raw)
    local idx, total = AutoBand.get_arrival_index(name_raw)
    if not idx then
        return ""
    end
    if total and total > 0 then
        return " (arr " .. tostring(idx) .. "/" .. tostring(total) .. ")"
    end
    return " (arr " .. tostring(idx) .. ")"
end

function AutoBand.reset_wb_arrival_tracking()
    AutoBand.wb_arrival_order = {}
    AutoBand.wb_arrival_lookup = {}
    AutoBand.wb_arrival_meta = {}
    AutoBand.pending_arrival_seed = false
    AutoBand.pending_arrival_seed_attempts = 0
end

function AutoBand.update_wb_arrival_tracking(wbdata)
    if type(wbdata) ~= "table" then
        return
    end
    if not AutoBand.wb_arrival_order then
        AutoBand.reset_wb_arrival_tracking()
    end

    AutoBand.wb_arrival_meta = AutoBand.wb_arrival_meta or {}
    local order = AutoBand.wb_arrival_order
    local meta = AutoBand.wb_arrival_meta
    local wb_count = 0
    for _, grp in ipairs(wbdata) do
        if grp and type(grp.players) == "table" then
            wb_count = wb_count + #grp.players
        end
    end
    local self_key = nil
    if GameData and GameData.Player and GameData.Player.name then
        self_key = normalize_wb_player_name(GameData.Player.name)
    end

    local function build_arrival_seed_from_open_party()
        local function fetch_list(fetch_fn)
            if type(fetch_fn) ~= "function" then
                return nil
            end
            local ok_list, list = pcall(fetch_fn)
            if not ok_list or type(list) ~= "table" then
                return nil
            end
            return list
        end

        local leader_lookup = {}
        local function add_leader(name_raw)
            local key = normalize_wb_player_name(name_raw)
            if key then
                leader_lookup[key] = true
            end
        end

        if GameData and GameData.Player and GameData.Player.isGroupLeader == true and GameData.Player.name then
            add_leader(GameData.Player.name)
        end

        if PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
            local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
            if ok_leader and leader then
                add_leader(leader.name)
                add_leader(leader.leaderName)
            end
        end

        if AutoBand.last_wb_leader_name_lower then
            leader_lookup[AutoBand.last_wb_leader_name_lower] = true
        end

        if not next(leader_lookup) then
            return nil
        end

        local function is_warband_entry(candidate)
            if candidate.isWarband == true then
                return true
            end
            if candidate.isWarband == nil and candidate.numGroupMembers and candidate.numGroupMembers > 6 then
                return true
            end
            return false
        end

        local function find_entry(list)
            if type(list) ~= "table" then
                return nil
            end
            for _, candidate in ipairs(list) do
                if type(candidate) == "table" and is_warband_entry(candidate) then
                    local leader_key = normalize_wb_player_name(candidate.leaderName or candidate.name)
                    if leader_key and leader_lookup[leader_key] then
                        return candidate
                    end
                end
            end
            return nil
        end

        local entry
        local world_list = fetch_list(GetOpenPartyWorldList)
        local full_list = fetch_list(GetOpenPartyFullList)
        entry = find_entry(world_list)
        if not entry then
            entry = find_entry(full_list)
        end

        if not entry then
            return nil
        end

        local entry_group_len = 0
        if type(entry.Group) == "table" then
            entry_group_len = #entry.Group
        end
        local self_found_in_entry = false
        if self_key and type(entry.Group) == "table" then
            for i = 1, #entry.Group do
                local member = entry.Group[i]
                local key = normalize_wb_player_name(member and (member.m_memberName or member.name))
                if key and key == self_key then
                    self_found_in_entry = true
                    break
                end
            end
        end
        local entry_num = nil
        if type(entry.numGroupMembers) == "number" then
            entry_num = entry.numGroupMembers
        end
        if entry_num and wb_count > 0 and entry_num < wb_count then
            local allow_self_gap = (self_key ~= nil and not self_found_in_entry and entry_num + 1 == wb_count)
            if not allow_self_gap then
                return nil
            end
        end
        if entry_group_len == 0 then
            return nil
        end

        local seed = {}
        local seen = {}
        local function add_name(name_raw)
            local key, display = normalize_wb_player_name(name_raw)
            if not key or key == self_key then
                return
            end
            if not seen[key] then
                seen[key] = true
                seed[#seed + 1] = key
            end
            if display then
                local entry_meta = meta[key]
                if not entry_meta then
                    entry_meta = {}
                    meta[key] = entry_meta
                end
                entry_meta.name = display
            end
        end

        if type(entry.Group) == "table" then
            for i = 1, #entry.Group do
                local member = entry.Group[i]
                add_name(member and (member.m_memberName or member.name))
            end
        end

        local leader_key, leader_display = normalize_wb_player_name(entry.leaderName or entry.name)
        if leader_key and leader_key ~= self_key and not seen[leader_key] then
            table.insert(seed, 1, leader_key)
            seen[leader_key] = true
            if leader_display then
                local entry_meta = meta[leader_key]
                if not entry_meta then
                    entry_meta = {}
                    meta[leader_key] = entry_meta
                end
                entry_meta.name = leader_display
            end
        end

        if #seed == 0 then
            return nil
        end

        return seed
    end

    if AutoBand.pending_arrival_seed and #order > 0 then
        order = {}
        AutoBand.wb_arrival_order = order
        AutoBand.wb_arrival_lookup = {}
        AutoBand.wb_arrival_meta = {}
        meta = AutoBand.wb_arrival_meta
    end

    if AutoBand.pending_arrival_seed then
        if #order == 0 then
            local seeded = build_arrival_seed_from_open_party()
            if seeded then
                order = seeded
                AutoBand.wb_arrival_order = order
                AutoBand.pending_arrival_seed = false
                AutoBand.pending_arrival_seed_attempts = 0
            else
                AutoBand.pending_arrival_seed_attempts = (AutoBand.pending_arrival_seed_attempts or 0) + 1
                if AutoBand.pending_arrival_seed_attempts < ARRIVAL_SEED_MAX_ATTEMPTS then
                    return
                end
                AutoBand.pending_arrival_seed = false
            end
        end
    end

    local scan_order = {}
    local present = {}

    for _, grp in ipairs(wbdata) do
        if grp and type(grp.players) == "table" then
            for _, player in ipairs(grp.players) do
                if player and player.name then
                    local key, display = normalize_wb_player_name(player.name)
                    if key and key ~= self_key then
                        if not present[key] then
                            present[key] = true
                            table.insert(scan_order, key)
                        end
                        local entry = meta[key]
                        if not entry then
                            entry = {}
                            meta[key] = entry
                        end
                        if display then
                            entry.name = display
                        end
                    end
                end
            end
        end
    end

    if #scan_order == 0 then
        return
    end

    local new_order = {}
    local new_lookup = {}

    for i = 1, #order do
        local key = order[i]
        if key == self_key then
            meta[key] = nil
        elseif present[key] then
            new_lookup[key] = #new_order + 1
            new_order[#new_order + 1] = key
            present[key] = nil
        else
            meta[key] = nil
        end
    end

    for i = 1, #scan_order do
        local key = scan_order[i]
        if not new_lookup[key] then
            new_lookup[key] = #new_order + 1
            new_order[#new_order + 1] = key
        end
    end

    AutoBand.wb_arrival_order = new_order
    AutoBand.wb_arrival_lookup = new_lookup
end

local function reset_wb_roster_cache(preserve_arrival)
    roles_last = {}
    AutoBand.role_tick = 0
    AutoBand.cached_wb = nil
    AutoBand.cache_dirty = true
    AutoBand.last_wb_player_count = 0
    AutoBand.last_wb_leader_name_lower = nil
    AutoBand.need_role_update = false
    AutoBand.wb_roster_signature = nil
    AutoBand.wb_roster_snapshot_lookup = {}
    AutoBand.wb_roster_snapshot_count = 0
    AutoBand.wb_roster_snapshot_stamp = 0
    AutoBand.wb_roster_generation = 0
    AutoBand.alt_spec_signature = nil
    AutoBand.party_note_last_roster_signature = nil
    AutoBand.party_note_last_alt_signature = nil
    mark_partynote_dirty()
    clear_partynote_live_verify_state()
    AutoBand.role_update_elapsed = 0
    AutoBand.backfill_notice_state = {}
    AutoBand.pending_arrival_seed = false
    AutoBand.pending_arrival_seed_attempts = 0
    if not preserve_arrival then
        AutoBand.reset_wb_arrival_tracking()
    end
end

function AutoBand.register_warband_event_handlers()
    if AutoBand.warband_events_registered == true then
        return false
    end
    for i = 1, #AB_WARBAND_EVENT_HANDLERS do
        local spec = AB_WARBAND_EVENT_HANDLERS[i]
        ab_register_optional_event_handler(spec.event, spec.handler)
    end
    AutoBand.warband_events_registered = true
    return true
end

function AutoBand.unregister_warband_event_handlers()
    if AutoBand.warband_events_registered ~= true then
        return false
    end
    for i = #AB_WARBAND_EVENT_HANDLERS, 1, -1 do
        local spec = AB_WARBAND_EVENT_HANDLERS[i]
        ab_unregister_optional_event_handler(spec.event, spec.handler)
    end
    AutoBand.warband_events_registered = false
    return true
end

function AutoBand.register_player_state_event_handlers()
    if AutoBand.player_state_events_registered == true then
        return false
    end
    for i = 1, #AB_PLAYER_STATE_EVENT_HANDLERS do
        local spec = AB_PLAYER_STATE_EVENT_HANDLERS[i]
        ab_register_optional_event_handler(spec.event, spec.handler)
    end
    AutoBand.player_state_events_registered = true
    return true
end

function AutoBand.is_wbleader_tell_alert_enabled()
    return AutoBand.saved and AutoBand.saved.wbleader_tell_alert_enabled == true
end

function AutoBand.is_wbleader_background_tracking_enabled()
    return AutoBand.saved and
        (AutoBand.saved.wbleader_notify_enabled == true or AutoBand.saved.wbleader_tell_alert_enabled == true)
end

-- Region/LFG availability gates the Tools-tab search controls and the auto-search, so
-- AutoBand always listens for CHANNEL_NAMES_UPDATED (it fires only on join/create/leave).
-- While subscribed, AB_util keeps the channel table until the handler marks it dirty.
function AutoBand.RefreshChatChannelEventSubscription()
    if AB_util._chat_channels_event_registered ~= true then
        AB_util._chat_channels_event_registered = ab_register_optional_event_handler(
            "CHANNEL_NAMES_UPDATED", "AutoBand.OnChatChannelNamesUpdated")
        AB_util.invalidate_chat_channels()
    end
    return AB_util._chat_channels_event_registered == true
end

-- Marks the channel table dirty and refreshes only the channel controls of the
-- visible page (Lead search channels, Recruit auto search); hidden pages refresh
-- them on their next Show().
function AutoBand.OnChatChannelNamesUpdated()
    AB_util.invalidate_chat_channels()
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshChannelControls) == "function" then
        AutoBandWindow.RefreshChannelControls()
    end
end

function AutoBand.RefreshWBLeaderTellEventSubscription()
    local want_registered = AutoBand.is_wbleader_tell_alert_enabled()
    if want_registered and AutoBand.wbleader_tell_event_registered ~= true then
        AutoBand.wbleader_tell_event_registered = ab_register_optional_event_handler(
            AB_WBLEADER_TELL_EVENT_HANDLER.event,
            AB_WBLEADER_TELL_EVENT_HANDLER.handler
        )
        return AutoBand.wbleader_tell_event_registered
    elseif not want_registered and AutoBand.wbleader_tell_event_registered == true then
        ab_unregister_optional_event_handler(
            AB_WBLEADER_TELL_EVENT_HANDLER.event,
            AB_WBLEADER_TELL_EVENT_HANDLER.handler
        )
        AutoBand.wbleader_tell_event_registered = false
    end
    return AutoBand.wbleader_tell_event_registered == true
end

local function autoband_plain_chat_text(value)
    if value == nil then
        return ""
    end

    local fixed = value
    if type(AutoBand.FixString) == "function" then
        local ok_fix, fixed_value = pcall(AutoBand.FixString, value)
        if ok_fix and fixed_value ~= nil then
            fixed = fixed_value
        end
    elseif type(fixed) ~= "string" and type(WStringToString) == "function" then
        local ok_wstring, text_value = pcall(WStringToString, fixed)
        if ok_wstring and text_value ~= nil then
            fixed = text_value
        end
    end

    local ok_text, text = pcall(tostring, fixed)
    if not ok_text or text == nil then
        return ""
    end
    return text
end

function AutoBand.StopWBLeaderTellHighlight()
    AutoBand.wbleader_tell_alert_highlight_remaining = 0
    if type(WindowStopAlphaAnimation) == "function" then
        pcall(WindowStopAlphaAnimation, "AutoBandMapIconButton")
    end
    if type(WindowSetAlpha) == "function" then
        pcall(WindowSetAlpha, "AutoBandMapIconButton", 1)
    end
end

function AutoBand.StartWBLeaderTellHighlight()
    AutoBand.wbleader_tell_alert_highlight_remaining = AB_WBLEADER_TELL_ALERT_HIGHLIGHT_SECONDS
    if type(WindowStartAlphaAnimation) ~= "function" or
        type(Window) ~= "table" or type(Window.AnimationType) ~= "table" or Window.AnimationType.LOOP == nil then
        return
    end
    pcall(
        WindowStartAlphaAnimation,
        "AutoBandMapIconButton",
        Window.AnimationType.LOOP,
        1,
        0.25,
        0.5,
        false,
        0,
        0
    )
end

function AutoBand.UpdateWBLeaderTellHighlight(elapsed)
    local remaining = tonumber(AutoBand.wbleader_tell_alert_highlight_remaining) or 0
    if remaining <= 0 then
        return
    end
    remaining = remaining - (tonumber(elapsed) or 0)
    if remaining <= 0 then
        AutoBand.StopWBLeaderTellHighlight()
    else
        AutoBand.wbleader_tell_alert_highlight_remaining = remaining
    end
end

local function autoband_rgb_components(rgb, fallback)
    if type(rgb) ~= "table" then
        rgb = fallback
    end
    if type(rgb) ~= "table" then
        rgb = { 255, 255, 255 }
    end
    return rgb[1] or 255, rgb[2] or 255, rgb[3] or 255
end

local function autoband_muted_chat_text(text)
    local r, g, b = autoband_rgb_components(AB_const.COLOR_SILVER, { 192, 192, 192 })
    return string.format(
        "<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">",
        r, g, b, tostring(text or "")
    )
end

local function autoband_player_link_text(name)
    local name_s = tostring(name or "")
    if name_s == "" then
        return ""
    end

    local lead_color_name = (AutoBand.saved and AutoBand.saved.lead_color_name) or AB_const.DEFAULT_LEAD_COLOR_NAME
    local rgb = AB_const.AVAILABLE_COLORS[lead_color_name] or
        AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME] or
        AB_const.COLOR_WHITE
    local r, g, b = autoband_rgb_components(rgb, AB_const.COLOR_WHITE)
    local link_name = string.gsub(name_s, "\"", "'")

    return string.format(
        "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"@%s\">",
        link_name, r, g, b, link_name
    )
end

function AutoBand.TriggerWBLeaderTellAlert(sender_raw, message_raw)
    local _, sender_name = AutoBand.normalize_wb_player_name(sender_raw)
    sender_name = sender_name or autoband_plain_chat_text(sender_raw)
    if sender_name == "" then
        sender_name = "unknown"
    end

    AB_util.print(
        autoband_muted_chat_text("[WBLead-Tell]") .. " " ..
        autoband_player_link_text(sender_name) .. ": " ..
        autoband_plain_chat_text(message_raw)
    )

    if type(PlaySound) == "function" and GameData and GameData.Sound then
        local sound_id = GameData.Sound.QUEST_OBJECTIVES_COMPLETED or GameData.Sound.PLAYER_RECEIVES_TELL
        if sound_id ~= nil then
            pcall(PlaySound, sound_id)
        end
    end
    AutoBand.StartWBLeaderTellHighlight()
end

function AutoBand.OnWBLeaderTellChatText()
    if not AutoBand.is_wbleader_tell_alert_enabled() then
        return
    end
    if not (GameData and type(GameData.ChatData) == "table" and SystemData and type(SystemData.ChatLogFilters) == "table") then
        return
    end
    if GameData.ChatData.type ~= SystemData.ChatLogFilters.TELL_RECEIVE then
        return
    end
    if type(AutoBand.is_wb_leader) ~= "function" or AutoBand.is_wb_leader() ~= true then
        return
    end

    local wbleaders = AutoBand.WBLeaders
    if not (type(wbleaders) == "table" and type(wbleaders.IsKnownLeader) == "function") then
        return
    end
    if wbleaders.IsKnownLeader(GameData.ChatData.name) ~= true then
        return
    end

    AutoBand.TriggerWBLeaderTellAlert(GameData.ChatData.name, GameData.ChatData.text)
end

function AutoBand.cmd_test_wbleader_tell_alert(_args)
    if not (GameData and type(GameData) == "table" and SystemData and type(SystemData.ChatLogFilters) == "table") then
        AB_util.print("WB-Leader tell test unavailable: chat globals are missing.")
        return
    end
    if SystemData.ChatLogFilters.TELL_RECEIVE == nil then
        AB_util.print("WB-Leader tell test unavailable: tell chat filter is missing.")
        return
    end
    if not (AutoBand.WBLeaders and type(AutoBand.WBLeaders.IsKnownLeader) == "function") then
        AB_util.print("WB-Leader tell test unavailable: WB-Leader tracker is missing.")
        return
    end

    AutoBand.saved = AutoBand.saved or {}

    local sender_name = "AutoBandTestLead"
    local message_text = "test WB-Leader tell alert"
    local sender_key = AutoBand.normalize_wb_player_name(sender_name)
    local old_chat_data = GameData.ChatData
    local old_alert_enabled = AutoBand.saved.wbleader_tell_alert_enabled
    local old_is_wb_leader = AutoBand.is_wb_leader
    local old_is_known_leader = AutoBand.WBLeaders and AutoBand.WBLeaders.IsKnownLeader

    AutoBand.saved.wbleader_tell_alert_enabled = true
    AutoBand.is_wb_leader = function()
        return true
    end
    AutoBand.WBLeaders.IsKnownLeader = function(name_raw)
        local key = AutoBand.normalize_wb_player_name(name_raw)
        if key and sender_key and key == sender_key then
            return true
        end
        return old_is_known_leader(name_raw) == true
    end

    GameData.ChatData = {
        type = SystemData.ChatLogFilters.TELL_RECEIVE,
        name = type(towstring) == "function" and towstring(sender_name) or sender_name,
        text = type(towstring) == "function" and towstring(message_text) or message_text
    }

    local ok, err = pcall(AutoBand.OnWBLeaderTellChatText)

    GameData.ChatData = old_chat_data
    AutoBand.saved.wbleader_tell_alert_enabled = old_alert_enabled
    AutoBand.is_wb_leader = old_is_wb_leader
    if AutoBand.WBLeaders then
        AutoBand.WBLeaders.IsKnownLeader = old_is_known_leader
    end

    if not ok then
        AB_util.print("WB-Leader tell test failed: " .. tostring(err))
    end
end

function AutoBand.set_wbleader_tell_alert_enabled(new_state, opts)
    opts = opts or {}
    new_state = new_state == true
    AutoBand.saved = AutoBand.saved or {}

    local changed = AutoBand.saved.wbleader_tell_alert_enabled ~= new_state
    AutoBand.saved.wbleader_tell_alert_enabled = new_state
    AutoBand.RefreshWBLeaderTellEventSubscription()

    if new_state then
        AutoBand.wbleaders_background_refresh_elapsed = AB_WBLEADERS_BACKGROUND_REFRESH_SECONDS
    else
        AutoBand.StopWBLeaderTellHighlight()
    end

    if changed and not opts.silent then
        AB_util.print("WB-Leader tell alerts: " .. tostring(new_state))
    end
    if changed and not opts.skip_gui_refresh then
        AutoBand.refresh_settings_ui()
    end

    return changed
end

local function reset_warband_runtime_after_disable()
    purge_warband_commands()
    reset_wb_roster_cache()
    AutoBand.need_role_update = false
    AutoBand.role_update_elapsed = 0
    AutoBand.pending_search_roles_args = nil
    AutoBand.pending_search_roles_delay = 0
    AutoBand.pending_search_roles_attempts = 0
    AutoBand.pending_group_leave_broadcast = nil
    AutoBand.pending_partynote_refresh = 0
    AutoBand.force_partynote_refresh = false
    AutoBand.pending_partynote_live_verify = false
    AutoBand.pending_partynote_live_verify_ticks = 0
    AutoBand.partynote_state_dirty = false
    AutoBand.pending_arrival_seed = false
    AutoBand.pending_arrival_seed_attempts = 0
    AutoBand.rank_requirement_grace_ticks_remaining = 0
    AutoBand.social_priority_grace_ticks_remaining = 0
    AutoBand.social_list_bootstrap_pending = false
    AutoBand.social_list_bootstrap_elapsed = 0
    AutoBand.social_list_bootstrap_attempts = 0
    AutoBand.social_list_bootstrap_targets = nil
    AutoBand.social_list_refresh_elapsed = 0
    AutoBand.wbleaders_background_refresh_elapsed = 0
    AutoBand.rankreq_pending_notice_state = {}
    AutoBand.suppressRoleNotifs = false
    AutoBand.suppressCounter = 0
    AutoBand.inWarband = false
    AutoBand.was_wb_leader = false
    AutoBand.elapsed = 0
    warned = {}
    toofar = {}
    toofar_old = {}
    toofar_not_changed = {}
end

function AutoBand.apply_warband_enabled_state(opts)
    opts = opts or {}
    refresh_warband_enabled_ui()
    AutoBand.register_player_state_event_handlers()
    if type(AutoBand.zonevote_set_sor_tracking) == "function" then
        AutoBand.zonevote_set_sor_tracking(AutoBand.is_warband_enabled())
    end
    if AutoBand.is_warband_enabled() then
        AutoBand.register_warband_event_handlers()
        if type(AutoBand.HookWarbandMenuCallbacks) == "function" then
            AutoBand.HookWarbandMenuCallbacks()
        end
        if opts.refresh_now == true then
            AutoBand.OnPlayerEnteringWorldOrReload()
            AutoBand.OnBattleGroupDataChanged()
        end
        return true
    end

    AutoBand.unregister_warband_event_handlers()
    if type(AutoBand.RestoreWarbandMenuCallbacks) == "function" then
        AutoBand.RestoreWarbandMenuCallbacks()
    end
    reset_warband_runtime_after_disable()
    return false
end

local function clear_warband_purpose()
    if AutoBand.current_purpose ~= nil then
        AutoBand.current_purpose = nil
        AutoBand.refresh_settings_ui()
    end
end

-- Leader/assistant/party changes also change which settings-window actions are
-- available, so the visible action buttons are re-evaluated after every update.
function AutoBand.OnBattleGroupDataChanged()
    AutoBand.battlegroup_data_changed_core()
    AutoBand.refresh_settings_actions()
end

function AutoBand.battlegroup_data_changed_core()
    if not AutoBand.is_warband_enabled() then
        return
    end
    local was_in = AutoBand.inWarband
    local was_leader = AutoBand.was_wb_leader
    local prev_count = AutoBand.last_wb_player_count or 0
    local prev_leader_name_lower = AutoBand.last_wb_leader_name_lower
    AutoBand.cache_dirty = true
    mark_partynote_dirty()
    AutoBand.inWarband = IsWarBandActive()
    if (was_in or AutoBand.current_purpose ~= nil) and not AutoBand.inWarband then
        local _, wb_count_check = get_wbdata_and_count()
        if wb_count_check and wb_count_check > 0 then
            AutoBand.inWarband = true
            AutoBand.last_wb_player_count = wb_count_check
        else
            reset_wb_roster_cache(true)
            clear_warband_purpose()
            return
        end
    end
    if AutoBand.inWarband and not was_in then
        AutoBand.suppressRoleNotifs = true
        AutoBand.suppressCounter = 4
        AutoBand.pending_arrival_seed = true
        AutoBand.pending_arrival_seed_attempts = 0
        if AutoBand.pending_search_roles_args then
            AutoBand.pending_search_roles_delay = 1
        end
    end
    local now_leader = false
    local wb_count
    local wbdata = nil
    local self_name_lower = nil
    local detected_leader_name_lower = nil
    local previous_roster_signature = AutoBand.wb_roster_signature
    if AutoBand.inWarband then
        wbdata = get_wbdata()
        wb_count = select(2, build_roster_signature(wbdata))
        AutoBand.last_wb_player_count = wb_count
        if wb_count > 0 then
            now_leader = AutoBand.is_wb_leader()
        end
        if GameData and GameData.Player and GameData.Player.name then
            self_name_lower = normalize_name_lowercase(GameData.Player.name)
        end
        if PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
            local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
            if ok_leader and leader then
                detected_leader_name_lower = normalize_name_lowercase(leader.name or leader.leaderName)
            end
        end
        if now_leader and self_name_lower then
            AutoBand.last_wb_leader_name_lower = self_name_lower
        elseif detected_leader_name_lower then
            AutoBand.last_wb_leader_name_lower = detected_leader_name_lower
        end
        -- A missing roster or leader can be temporary during zoning. Clear the
        -- purpose only once another leader is known and our leader check agrees.
        if wb_count > 0 and not now_leader and self_name_lower and
            detected_leader_name_lower and detected_leader_name_lower ~= self_name_lower then
            clear_warband_purpose()
        end
    else
        AutoBand.last_wb_player_count = 0
    end
    if AutoBand.inWarband and was_in and not was_leader and now_leader then
        local was_self_leader = prev_leader_name_lower and self_name_lower and prev_leader_name_lower == self_name_lower
        if not was_self_leader then
            local disabled = {}
            local reenable = {}
            local popup_details = {
                player_count = prev_count,
                disabled_items = {},
                reenable = {}
            }
            local opts = { silent = true, skip_gui_refresh = true, skip_template_dirty = true }
            local disable_full = prev_count >= 6
            local function record_disabled(label, command)
                table.insert(disabled, label)
                table.insert(reenable, command)
                table.insert(popup_details.disabled_items, { label = label, command = command })
                table.insert(popup_details.reenable, command)
            end
            if disable_full and AutoBand.saved.autokick_enabled then
                AutoBand.set_autokick_enabled(false, opts)
                record_disabled(
                    "role caps (" .. tostring(AutoBand.saved.max_tanks) .. "-" .. tostring(AutoBand.saved.max_healers) .. "-" .. tostring(AutoBand.saved.max_dps) .. ")",
                    "/ab ak"
                )
            end
            if disable_full and AutoBand.saved.autokick_low_rank_enabled then
                AutoBand.set_autokick_low_rank_enabled(false, opts)
                record_disabled("rank requirement", "/ab akl")
            end
            if AutoBand.saved.autokick_we_wh_enabled then
                AutoBand.set_autokick_we_wh_enabled(false, opts)
                record_disabled("stealthers autokick", "/ab wewhk")
            end
            if disable_full and AutoBand.saved.autokick_toofar_enabled then
                AutoBand.set_autokick_toofar_enabled(false, opts)
                record_disabled("too-far autokick", "/ab akf")
            end
            if disable_full and AutoBand.saved.autokick_ignorelist_enabled then
                AutoBand.set_autokick_ignorelist_enabled(false, opts)
                record_disabled("ignored-players autokick", "/ab akignore")
            end
            if AutoBand.saved.restrict_same_race then
                set_toggle("restrict_same_race", false, opts)
                record_disabled(AutoBand.get_promotion_safety_race_label(), "/ab rr")
            end
            if #disabled > 0 then
                if AutoBand.saved.default_template ~= AB_const.EMPTY_TEMPLATE then
                    popup_details.template_reset_from = AutoBand.saved.default_template
                    popup_details.template_reset_to = AB_const.EMPTY_TEMPLATE
                    AutoBand.saved.default_template = AB_const.EMPTY_TEMPLATE
                end
                if type(AutoBand.remember_active_template_selection) == "function" then
                    AutoBand.remember_active_template_selection(AB_const.EMPTY_TEMPLATE)
                else
                    AutoBand.template_active_key = AB_const.EMPTY_TEMPLATE
                end
                local disabled_str = join_list_with_conjunction(disabled, "and")
                local msg = "You just became warband leader in an existing warband. AutoBand disabled " .. disabled_str .. " to avoid unexpected kicks."
                if #reenable > 0 then
                    local reenable_items = {}
                    for i = 1, #reenable do
                        reenable_items[i] = reenable[i]
                    end
                    table.insert(reenable_items, "in the GUI (/ab show)")
                    msg = msg .. " Re-enable with " .. join_list_with_conjunction(reenable_items, "or") .. "."
                end
                purge_autokick_commands()
                AB_util.print(msg)
                refresh_config_tab()
                AutoBand.refresh_settings_ui()
                if type(AutoBandWindowLeaderPromotionPopup) == "table"
                    and type(AutoBandWindowLeaderPromotionPopup.ShowForPromotionSafety) == "function" then
                    AutoBandWindowLeaderPromotionPopup.ShowForPromotionSafety(popup_details)
                end
            end
        end
    end
    AutoBand.was_wb_leader = now_leader
    if not AutoBand.inWarband then
        AutoBand.need_role_update = false
        return
    end

    local roster_sig = AutoBand.wb_roster_signature
    local roster_changed = false
    if roster_sig ~= nil then
        roster_changed = roster_sig ~= previous_roster_signature
        if roster_changed then
            AutoBand.update_wb_arrival_tracking(wbdata)
            if AutoBand.checkpoint_realmrank_cache_for_wb then
                AutoBand.checkpoint_realmrank_cache_for_wb(wbdata)
            end
        end
    end

    local alt_changed = false
    if roster_changed then
        mark_alt_spec_snapshot_dirty()
        AutoBand.alt_spec_signature = build_alt_spec_signature()
    else
        local alt_sig = build_alt_spec_signature()
        alt_changed = alt_sig ~= AutoBand.alt_spec_signature
        if alt_changed then
            AutoBand.alt_spec_signature = alt_sig
        end
    end

    if roster_changed or alt_changed then
        AutoBand.need_role_update = true
    end
end

function AutoBand.OnPlayerEnteringWorldOrReload()
    AutoBand.DetermineRaceAndFaction()
    AutoBand.DeterminePlayerBaseRole()
    if not AutoBand.is_warband_enabled() then
        -- Keep non-mutating RR CSV, online monitor, and stats startup alive while WB automation is disabled.
        if type(AutoBand.realmrank_handle_world_entry) == "function" then
            AutoBand.realmrank_handle_world_entry()
        end
        return
    end
    AutoBand.TryRegisterPrefixLinkHandler()
    mark_partynote_dirty()
    clear_partynote_live_verify_state()
    ab_social_list_begin_bootstrap_refresh()
    if type(AutoBand.realmrank_handle_world_entry) == "function" then
        AutoBand.realmrank_handle_world_entry()
    end
end

function AutoBand.DetermineRaceAndFaction()
    local career_line = nil
    if GameData and GameData.Player and GameData.Player.career then
        career_line = GameData.Player.career.line
    end

    if career_line == nil then
        if not (AutoBand.raceDetermined and AutoBand.factionDetermined) then
            AB_util.print("Player data not ready for race/faction determination on ENTER_WORLD/INTERFACE_RELOADED.")
        end
        return false
    end

    if AutoBand.player_career_line_for_race == career_line
        and AutoBand.raceDetermined == true
        and AutoBand.factionDetermined == true
    then
        return true
    end

    AutoBand.faction = nil
    AutoBand.factionDetermined = false
    AutoBand.race = nil
    AutoBand.raceDetermined = false
    AutoBand.player_career_line_for_race = career_line

    local faction = AB_const.CAREERLINE_FACTIONMAP[career_line]
    local race = AB_const.CAREERLINE_RACEMAP[career_line]

    if faction then
        AutoBand.faction = faction
        AutoBand.factionDetermined = true
    else
        AB_util.print("Could not determine faction.")
    end

    if race then
        AutoBand.race = race
        AutoBand.raceDetermined = true
    else
        AB_util.print("Could not determine race.")
    end

    return AutoBand.raceDetermined == true and AutoBand.factionDetermined == true
end

function AutoBand.DeterminePlayerBaseRole()
    local career_line = nil
    if GameData and GameData.Player and GameData.Player.career then
        career_line = GameData.Player.career.line
    end

    if career_line == nil then
        if AutoBand.roleDetermined ~= true then
            AB_util.print("Player data not ready for role determination on ENTER_WORLD/INTERFACE_RELOADED.")
        end
        return false
    end

    if AutoBand.player_career_line_for_role == career_line and AutoBand.roleDetermined == true then
        return true
    end

    AutoBand.player_career_line_for_role = career_line
    AutoBand.role = nil
    AutoBand.roleDetermined = false

    local role = AB_util.career_category(career_line)
    if role then
        AutoBand.role = role
        AutoBand.roleDetermined = true
    else
        AB_util.print("Could not determine role.")
    end

    return AutoBand.roleDetermined == true
end

-- Trimmed prefix text, or nil plus the reason it cannot be used. Shared by the
-- command and the settings preview so both judge a draft the same way.
function AutoBand.validate_prefix_text(raw_prefix_string)
    local new_prefix = tostring(raw_prefix_string or "")
    local max_length = AB_const.MAX_PREFIX_LENGTH or 20

    new_prefix = string.gsub(new_prefix, "^%s+", "")
    new_prefix = string.gsub(new_prefix, "%s+$", "")

    if new_prefix == "" then
        return nil, "Prefix cannot be empty or only spaces."
    end
    if #new_prefix > max_length then
        return nil, "Prefix is too long (max " .. max_length .. " characters)."
    end
    return new_prefix
end

function AutoBand.cmd_set_prefix(raw_prefix_string)
    local new_prefix, problem = AutoBand.validate_prefix_text(raw_prefix_string)
    if new_prefix == nil then
        if string.find(problem, "empty", 1, true) then
            AB_util.print("[Error] " .. problem .. " Use /ab resetprefix to restore default.")
        else
            AB_util.print("[Error] " .. problem .. " Prefix not set.")
        end
        return
    end

    if AutoBand.saved.prefix_text ~= new_prefix then
        AutoBand.saved.prefix_text = new_prefix
        AutoBand.mark_template_settings_modified()
        AutoBand.refresh_settings_ui({ prefix_text_changed = true })
    end
    -- Add quotes in feedback to make spaces visible
    AB_util.print("Chat prefix set to: \"" .. new_prefix .. "\"")
end

function AutoBand.cmd_toggle_prefix_guild(_args)
    AutoBand.saved.prefix_use_guild = not AutoBand.saved.prefix_use_guild
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
    local guildInfo = AutoBand.GetCurrentGuildInfo()

    if AutoBand.saved.prefix_use_guild then
        if guildInfo then
            -- Use GenerateGuildLinkRaw and convert to wstring for printing the example
            local example_link_raw = AutoBand.GenerateGuildLinkRaw(guildInfo.id, guildInfo.name)
            AB_util.print(L"Prefix set to use guild in searches: " .. towstring(example_link_raw))
        else
            -- Get normal prefix example (wstring)
            local normal_prefix_example = AutoBand.GetFormattedPrefixWString(false)
            AB_util.print(L"Prefix guild link enabled, but you are not in a guild. Will use normal prefix: " .. normal_prefix_example)
        end
    else
         -- Get normal prefix example (wstring)
        local normal_prefix_example = AutoBand.GetFormattedPrefixWString(false)
        AB_util.print(L"Prefix guild link disabled. Using normal prefix: " .. normal_prefix_example)
    end

end

function AutoBand.cmd_reset_prefix(_args)
    if AutoBand.saved.prefix_text ~= AB_const.DEFAULT_PREFIX_TEXT then
        AutoBand.saved.prefix_text = AB_const.DEFAULT_PREFIX_TEXT
        AutoBand.mark_template_settings_modified()
    end
    AutoBand.refresh_settings_ui({ prefix_text_changed = true })
    AB_util.print("Chat prefix reset to default: " .. AutoBand.saved.prefix_text)
end

local function ensure_available_color_names_sorted()
    if type(AB_const.AVAILABLE_COLOR_NAMES_SORTED) == "table" and #AB_const.AVAILABLE_COLOR_NAMES_SORTED > 0 then
        return AB_const.AVAILABLE_COLOR_NAMES_SORTED
    end

    AB_const.AVAILABLE_COLOR_NAMES_SORTED = {}
    for name, _ in pairs(AB_const.AVAILABLE_COLORS) do
        table.insert(AB_const.AVAILABLE_COLOR_NAMES_SORTED, name)
    end
    table.sort(AB_const.AVAILABLE_COLOR_NAMES_SORTED)
    return AB_const.AVAILABLE_COLOR_NAMES_SORTED
end

local function build_colored_color_name_link_raw(color_name)
    local color_rgb = AVAILABLE_COLORS[color_name] or AVAILABLE_COLORS[AB_const.DEFAULT_PREFIX_COLOR_NAME] or AB_const.COLOR_WHITE
    local r, g, b = color_rgb[1], color_rgb[2], color_rgb[3]
    return string.format("<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">", r, g, b, color_name)
end

function AutoBand.cmd_list_colors(_args)
    AB_util.print("Available color names:")
    local color_names = ensure_available_color_names_sorted()
    local batch = {}
    for i = 1, #color_names do
        batch[#batch + 1] = build_colored_color_name_link_raw(color_names[i])
        if #batch >= 6 or i == #color_names then
            AB_util.print(table.concat(batch, ", "))
            batch = {}
        end
    end
end

function AutoBand.cmd_set_prefix_color(args)
    local color_name = args[1]
    if not color_name then
        AB_util.print("[Error] Missing color name. Usage: /ab setprefixcolor <color_name>")
        AutoBand.cmd_list_colors({}) -- Show available colors
        return
    end
    color_name = color_name:lower() -- Ensure lowercase for comparison

    if AVAILABLE_COLORS[color_name] then
        AutoBand.saved.prefix_color_name = color_name
        AutoBand.mark_template_settings_modified()
        AutoBand.refresh_settings_ui()
        -- Get the formatted prefix with the NEW color for feedback (as wstring)
        local example_prefix = AutoBand.GetFormattedPrefixWString(false) -- Get prefix without space
        local feedback_message = L"Prefix color set to " .. example_prefix

        -- Pass the complete wstring message to AB_util.print
        AB_util.print(feedback_message)
    else
        AB_util.print("[Error] Invalid color name: '" .. color_name .. "'.")
        AutoBand.cmd_list_colors({}) -- Show available colors
    end
end

function AutoBand.cmd_reset_prefix_color(_args)
    AutoBand.saved.prefix_color_name = AB_const.DEFAULT_PREFIX_COLOR_NAME
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
    -- Get the formatted prefix using the NEWLY reset default color for feedback
    local example_prefix = AutoBand.GetFormattedPrefixWString(false) -- Get prefix without space
    -- Construct the full feedback message as a wstring
    local feedback_message = L"Prefix color reset to default (" .. example_prefix .. L")"
    AB_util.print(feedback_message)
end

function AutoBand.cmd_set_lead_color(args)
    local color_name = args[1]
    if not color_name then
        AB_util.print("[Error] Missing color name. Usage: /ab setleadcolor <color_name>")
        AutoBand.cmd_list_colors({}) -- Show available colors
        return
    end
    color_name = color_name:lower() -- Ensure lowercase for comparison

    if AVAILABLE_COLORS[color_name] then
        AutoBand.saved.lead_color_name = color_name
        AutoBand.mark_template_settings_modified()
        AutoBand.refresh_settings_ui()
        -- Keep the raw string for formatting, then convert
        local example_text_raw = build_colored_color_name_link_raw(color_name)
        local example_text_wstring = towstring(example_text_raw) -- Convert the link to wstring
        local feedback_message = L"WB Lead mention color set to " .. example_text_wstring

        -- Pass the complete wstring message to AB_util.print
        AB_util.print(feedback_message)
    else
        AB_util.print("[Error] Invalid color name: '" .. color_name .. "'.")
        AutoBand.cmd_list_colors({}) -- Show available colors
    end
end

function AutoBand.cmd_reset_lead_color(_args)
    AutoBand.saved.lead_color_name = AB_const.DEFAULT_LEAD_COLOR_NAME
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
    -- Generate example colored text for feedback using the default color
    local default_color_name = AB_const.DEFAULT_LEAD_COLOR_NAME
    local example_text_raw = build_colored_color_name_link_raw(default_color_name)
    local example_text_wstring = towstring(example_text_raw) -- Convert the link to wstring
    -- Construct the full feedback message as a wstring
    local feedback_message = L"WB Lead mention color reset to default (" .. example_text_wstring .. L")"
    AB_util.print(feedback_message)
end

function AutoBand.cmd_flag_autokick_lowrnk(_args)
    AutoBand.set_autokick_low_rank_enabled(not AutoBand.saved.autokick_low_rank_enabled)
end

function AutoBand.cmd_flag_autokick_rvrzone(_args)
    AutoBand.set_autokick_rvrzone_enabled(not AutoBand.saved.autokick_rvrzone_enabled)
end

function AutoBand.cmd_toggle_autokick_ignorelist(_args)
    AutoBand.set_autokick_ignorelist_enabled(not AutoBand.saved.autokick_ignorelist_enabled)
end

function AutoBand.cmd_toggle_backfill(_args)
    AutoBand.set_backfill_enabled(not AutoBand.saved.backfill_enabled)
end

function AutoBand.cmd_toggle_buffnotify(_args)
    AutoBand.saved.notify_buffs_enabled = not AutoBand.saved.notify_buffs_enabled
    AB_util.print("Notify warband after organize: " .. tostring(AutoBand.saved.notify_buffs_enabled))
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_alt_speccheck(_args)
    AutoBand.saved.alt_speccheck_enabled = not AutoBand.saved.alt_speccheck_enabled
    AutoBand.mark_alt_spec_snapshot_dirty()
    AB_util.print("Use alt spec check: " .. tostring(AutoBand.saved.alt_speccheck_enabled))
    AutoBand.mark_template_settings_modified()
    AutoBand.need_role_update = true
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_flag_printrole(_args)
    AutoBand.saved.printrole_enabled = not AutoBand.saved.printrole_enabled
    AB_util.print("Print role assignments: " .. tostring(AutoBand.saved.printrole_enabled))
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_toggle_arrival_notify_tags(args)
    local arg1 = args and args[1]
    if arg1 then
        local lower = arg1:lower()
        if lower == "on" or lower == "true" or lower == "1" then
            AutoBand.saved.print_arrival_notify_tags_enabled = true
        elseif lower == "off" or lower == "false" or lower == "0" then
            AutoBand.saved.print_arrival_notify_tags_enabled = false
        else
            AB_util.print("Usage: /ab arrtag [on|off]")
            return
        end
    else
        AutoBand.saved.print_arrival_notify_tags_enabled = AutoBand.saved.print_arrival_notify_tags_enabled ~= true
    end
    AB_util.print("Show arrival tags in role notifications: " .. tostring(AutoBand.saved.print_arrival_notify_tags_enabled))
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end


function AutoBand.cmd_list_roles(args)
    local role_filter = nil
    if args[1] then
        local role_param = args[1]:lower()
        if role_param == "tanks" then
            role_param = AB_const.TANK -- Convert to singular constant
        elseif role_param == "healers" then
            role_param = AB_const.HEALER -- Convert to singular constant
        elseif role_param == "heals" then
            role_param = AB_const.HEALER -- Convert to singular constant
        elseif role_param == "heal" then
            role_param = AB_const.HEALER -- Convert to singular constant
        end
        if role_param ~= AB_const.TANK and role_param ~= AB_const.HEALER and
           role_param ~= AB_const.MDPS and role_param ~= AB_const.RDPS then
            AB_util.print("[error] Invalid role: " .. role_param .. ". Valid roles are " ..
                          AB_const.TANK .. ", " .. AB_const.HEALER .. ", " ..
                          AB_const.MDPS .. ", " .. AB_const.RDPS .. ".")
            return
        end
        role_filter = role_param
    end

    AB_util.print("Currently known player roles" ..
                  (role_filter and (" (" .. role_filter .. ")") or "") .. ":")
    local entries = {}
    local wb_obj = nil
    if AutoBand.get_wb then
        AutoBand.cache_dirty = true
        wb_obj = AutoBand.get_wb()
    end

    if wb_obj and wb_obj.player_count and wb_obj.player_count > 0 then
        wb_obj:foreach_player(function(_gid, player)
            local role = player and player.role or nil
            if role and (not role_filter or role == role_filter) then
                table.insert(entries, {
                    name = tostring(player.name),
                    role = role,
                    level = player.level
                })
            end
        end)
    else
        for name, entry in pairs(roles_last) do
            local role = entry
            if type(entry) == "table" then
                role = entry.role
            end

            if role then
                if not role_filter or role == role_filter then
                    table.insert(entries, { name = name, role = role, level = type(entry) == "table" and entry.level or nil })
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        local a_order = AB_util.role_display_order(a.role)
        local b_order = AB_util.role_display_order(b.role)
        if a_order == b_order then
            if a.role ~= b.role then
                return tostring(a.role) < tostring(b.role)
            end
            return a.name < b.name
        end
        return a_order < b_order
    end)

    local count = 0
    for _, entry in ipairs(entries) do
        local msg = towstring("- [") .. towstring(entry.role) .. towstring("] - ") .. towstring(entry.name)
        AB_util.print(msg)
        count = count + 1
    end

    if count == 0 then
        AB_util.print("(no role data available)")
    end
end

local function refresh_arrival_from_live()
    if not AutoBand.inWarband then
        return false
    end
    local wbdata, count = get_wbdata_and_count()
    if wbdata and count and count > 0 then
        AutoBand.update_wb_arrival_tracking(wbdata)
        return true
    end
    return false
end

local function get_arrival_display_name(key, fallback)
    if AutoBand.wb_arrival_meta and AutoBand.wb_arrival_meta[key] and AutoBand.wb_arrival_meta[key].name then
        return AutoBand.wb_arrival_meta[key].name
    end
    return fallback or key
end

function AutoBand.cmd_arrival(args)
    local subcmd = args[1] and args[1]:lower() or "list"

    if subcmd == "list" or subcmd == "ls" then
        if not AutoBand.inWarband then
            AB_util.print("Not in a warband.")
            return
        end
        if not AutoBand.wb_arrival_order or #AutoBand.wb_arrival_order == 0 then
            refresh_arrival_from_live()
        end

        local order = AutoBand.wb_arrival_order or {}
        if #order == 0 then
            AB_util.print("Arrival tracking is empty. Use /ab arrival reset to seed from the current roster.")
            return
        end

        local role_map = {}
        local wb = AutoBand.get_wb()
        if wb and wb.group then
            wb:foreach_player(function(gid, player)
                local key = normalize_wb_player_name(player.name)
                if key then
                    role_map[key] = { gid = gid, role = player.role }
                end
            end)
        end

        AB_util.print("Arrival order (oldest -> newest):")
        for i = 1, #order do
            local key = order[i]
            local display = get_arrival_display_name(key, key)
            local extra = ""
            local info = role_map[key]
            if info then
                if info.role and info.role ~= "" then
                    extra = " - " .. tostring(info.role)
                end
                if info.gid and info.gid > 0 then
                    extra = extra .. " (G" .. tostring(info.gid) .. ")"
                end
            end
            AB_util.print(tostring(i) .. ". " .. tostring(display) .. extra)
        end
        return
    end

    if subcmd == "swap" or subcmd == "move" or subcmd == "reset" or subcmd == "rebuild" then
        if not AutoBand.require_warband_features_enabled("changing arrival tracking") then
            return
        end
        if not AutoBand.is_wb_leader() then
            AB_util.print("[error] You need to be a wb leader")
            return
        end
    end

    if subcmd == "reset" or subcmd == "rebuild" then
        AutoBand.reset_wb_arrival_tracking()
        if AutoBand.inWarband then
            refresh_arrival_from_live()
        end
        AB_util.print("Arrival tracking reset from the current roster.")
        return
    end

    if AutoBand.inWarband then
        refresh_arrival_from_live()
    end
    local order = AutoBand.wb_arrival_order or {}
    if #order == 0 then
        AB_util.print("Arrival tracking is empty. Use /ab arrival reset to seed from the current roster.")
        return
    end

    if subcmd == "swap" then
        local name_a = args[2]
        local name_b = args[3]
        if not name_a or not name_b then
            AB_util.print("Usage: /ab arrival swap <name1> <name2>")
            return
        end
        local key_a = normalize_wb_player_name(name_a)
        local key_b = normalize_wb_player_name(name_b)
        if not key_a or not key_b then
            AB_util.print("[error] Invalid player name.")
            return
        end
        local lookup = AutoBand.wb_arrival_lookup or build_arrival_lookup(order)
        local idx_a = lookup[key_a]
        local idx_b = lookup[key_b]
        if not idx_a or not idx_b then
            AB_util.print("[error] One or both names are not tracked in the current warband.")
            return
        end
        order[idx_a], order[idx_b] = order[idx_b], order[idx_a]
        AutoBand.wb_arrival_lookup = build_arrival_lookup(order)
        AB_util.print("Arrival order updated: swapped " .. get_arrival_display_name(key_a, name_a) .. " and " .. get_arrival_display_name(key_b, name_b) .. ".")
        return
    end

    if subcmd == "move" then
        local name = args[2]
        local pos_arg = args[3]
        if not name or not pos_arg then
            AB_util.print("Usage: /ab arrival move <name> <index|top|bottom>")
            return
        end
        local key = normalize_wb_player_name(name)
        if not key then
            AB_util.print("[error] Invalid player name.")
            return
        end
        local lookup = AutoBand.wb_arrival_lookup or build_arrival_lookup(order)
        local idx = lookup[key]
        if not idx then
            AB_util.print("[error] Name is not tracked in the current warband.")
            return
        end
        local target
        local pos_lower = tostring(pos_arg):lower()
        if pos_lower == "top" then
            target = 1
        elseif pos_lower == "bottom" then
            target = #order
        else
            target = tonumber(pos_arg)
        end
        if not target or target < 1 or target > #order then
            AB_util.print("[error] Position must be between 1 and " .. tostring(#order) .. ".")
            return
        end
        if target == idx then
            AB_util.print("Arrival order unchanged: " .. get_arrival_display_name(key, name) .. " is already at position " .. tostring(target) .. ".")
            return
        end
        table.remove(order, idx)
        table.insert(order, target, key)
        AutoBand.wb_arrival_lookup = build_arrival_lookup(order)
        AB_util.print("Arrival order updated: moved " .. get_arrival_display_name(key, name) .. " to position " .. tostring(target) .. ".")
        return
    end

    AB_util.print("Usage: /ab arrival list")
    AB_util.print("       /ab arrival swap <name1> <name2>")
    AB_util.print("       /ab arrival move <name> <index|top|bottom>")
    AB_util.print("       /ab arrival reset")
end


-- Block AutoBand PMs ---------------------------------------------------------
-- An optional switch (saved key block_outgoing_pms, default off) that keeps
-- AutoBand's own queued tells from being sent. It never touches the player's typed
-- chat, other addons, incoming tell alerts, /wb output or kicks. It is checked when
-- a command is queued and again right before SendChatText, so entries put straight
-- into cmd_queue or changed after queueing are caught too. Only an explicit saved
-- true enables blocking, including before init.

-- Whole first command token, compared case-insensitively. /tt is the native
-- "tell target" command (chatwindow.lua c_TELL_TARGET_COMMAND).
local pm_block = {
    tokens = { tell = true, t = true, tt = true, whisper = true, w = true, reply = true, r = true },
}

function AutoBand.is_pm_block_active()
    return type(AutoBand.saved) == "table" and AutoBand.saved.block_outgoing_pms == true
end

-- true = private message command, false = some other command or text,
-- nil = could not be classified (unsupported type or the wide-string library failed).
-- Only the leading command token is extracted; the payload is never converted.
function AutoBand.is_private_message_command(cmd)
    local kind = type(cmd)
    if kind == "string" then
        local token = string.match(cmd, "^%s*/(%S*)")
        if token == nil then
            return false
        end
        return pm_block.tokens[string.lower(token)] == true
    end
    if kind == "wstring" then
        if type(wstring) ~= "table" or type(wstring.match) ~= "function" or type(wstring.lower) ~= "function" then
            return nil
        end
        local ok_match, token = pcall(wstring.match, cmd, L"^%s*/(%S*)")
        if not ok_match then
            return nil
        end
        if token == nil then
            return false
        end
        local ok_lower, lowered = pcall(wstring.lower, token)
        if not ok_lower or lowered == nil then
            return nil
        end
        local wide_tokens = { L"tell", L"t", L"tt", L"whisper", L"w", L"reply", L"r" }
        for i = 1, #wide_tokens do
            if lowered == wide_tokens[i] then
                return true
            end
        end
        return false
    end
    return nil
end

-- While blocking, anything not positively classified as a non-PM is held back.
function pm_block.is_blocked(cmd)
    return AutoBand.is_pm_block_active() and AutoBand.is_private_message_command(cmd) ~= false
end

function pm_block.note_suppressed()
    AutoBand.pm_block_dropped_count = (tonumber(AutoBand.pm_block_dropped_count) or 0) + 1
    if AutoBand.pm_block_notice_shown ~= true then
        AutoBand.pm_block_notice_shown = true
        AB_util.print("Block AutoBand PMs is on: AutoBand did not send a tell. /ab nopm off allows them.")
    end
end

-- Drop the current and queued PMs (callbacks not run); other entries keep their
-- order, ticks, source and callback.
function pm_block.purge()
    local dropped = 0
    if AutoBand.cmd_current and AutoBand.is_private_message_command(AutoBand.cmd_current.cmd) ~= false then
        AutoBand.cmd_current = nil
        dropped = dropped + 1
    end
    if type(AutoBand.cmd_queue) == "table" and #AutoBand.cmd_queue > 0 then
        local remaining = {}
        for i = 1, #AutoBand.cmd_queue do
            local entry = AutoBand.cmd_queue[i]
            if entry and AutoBand.is_private_message_command(entry.cmd) == false then
                remaining[#remaining + 1] = entry
            else
                dropped = dropped + 1
            end
        end
        AutoBand.cmd_queue = remaining
    end
    AutoBand.pm_block_dropped_count = (tonumber(AutoBand.pm_block_dropped_count) or 0) + dropped
    return dropped
end

function pm_block.refresh_strip()
    if type(AutoBandWindow) == "table" and type(AutoBandWindow.RefreshGlobalStrip) == "function" then
        AutoBandWindow.RefreshGlobalStrip()
    end
end

-- Global setting: never captured by presets, the Automatic baseline or page defaults.
function AutoBand.set_block_outgoing_pms(new_state, opts)
    opts = opts or {}
    if type(new_state) ~= "boolean" then
        AB_util.print("[Error] Block AutoBand PMs needs on or off.")
        return false
    end
    AutoBand.saved = AutoBand.saved or {}
    local was_active = AutoBand.is_pm_block_active()
    AutoBand.saved.block_outgoing_pms = new_state
    local changed = was_active ~= new_state
    if new_state then
        pm_block.purge()
    end
    if not opts.silent then
        if new_state then
            AB_util.print("Block AutoBand PMs: on. AutoBand will not send tells; kicks and /wb messages still go out.")
        else
            AB_util.print("Block AutoBand PMs: off. AutoBand may send kick reasons and backfill notices as tells.")
        end
    end
    pm_block.refresh_strip()
    return changed
end

function AutoBand.cmd_block_pms(args)
    -- Exactly one argument (empty split tokens ignored); anything extra is malformed
    -- and only prints usage, so "/ab nopm off unexpected" can never switch blocking off.
    local words = {}
    if type(args) == "table" then
        for i = 1, #args do
            local word = tostring(args[i] or "")
            if string.find(word, "%S") then
                words[#words + 1] = string.lower((string.gsub(word, "^%s*(.-)%s*$", "%1")))
            end
        end
    end
    if #words > 1 then
        AB_util.print("Usage: /ab nopm [on|off|status]")
        return
    end
    local arg = words[1]
    if arg == nil or arg == "status" then
        local state = AutoBand.is_pm_block_active() and "on" or "off"
        AB_util.print("Block AutoBand PMs: " .. state .. " (applies to AutoBand's own tells; " ..
            tostring(tonumber(AutoBand.pm_block_dropped_count) or 0) .. " held back this session).")
        return
    end
    if arg == "on" or arg == "true" or arg == "1" then
        AutoBand.set_block_outgoing_pms(true)
    elseif arg == "off" or arg == "false" or arg == "0" then
        AutoBand.set_block_outgoing_pms(false)
    else
        AB_util.print("Usage: /ab nopm [on|off|status]")
    end
end

-- Organizer focus role used by the Aggregate algorithm (AB_template.from_bins_aggregate).
-- Preset-captured; only the four role constants are accepted.
function AutoBand.set_org_algo_role(role, opts)
    opts = opts or {}
    if role ~= AB_const.TANK and role ~= AB_const.HEALER and role ~= AB_const.MDPS and role ~= AB_const.RDPS then
        if not opts.silent then
            AB_util.print("[Error] Organizer focus must be tank, healer, mdps or rdps.")
        end
        return false
    end
    local changed = AutoBand.saved.org_algo_role ~= role
    AutoBand.saved.org_algo_role = role
    if changed then
        if not opts.silent then
            AB_util.print("Aggregate organize spreads " .. tostring(role) .. " across groups.")
        end
        AutoBand.mark_template_settings_modified()
        if not opts.skip_gui_refresh then
            AutoBand.refresh_settings_ui()
        end
    end
    return changed
end

-- Page defaults --------------------------------------------------------------
-- Each page resets only its own settings, through the validated setters and their
-- lifecycle effects (grace periods, partynote clearing, baseline). Never touched:
-- Block AutoBand PMs, warband enablement, presets/layout/default preset, custom
-- roles, monitored markgroups and the default markgroup, and the map icon. The
-- preset is marked modified only when a preset-captured setting actually changed.
local page_defaults = {}

-- Tools: kick checks, advertising, auto-search, partynote, organize messages.
function page_defaults.tools(s)
    s.kick_func_enabled = type(s.kick_func_enabled) == "table" and s.kick_func_enabled or {}
    for fid, value in pairs(AB_const.KICK_FUNC_DEFAULT) do
        s.kick_func_enabled[fid] = value
    end
    s.autonote_enabled = AB_const.AUTONOTE
    s.autoform_search_enabled = AB_const.AUTOFORM_SEARCH
    s.search_discord_req_enabled = AB_const.SEARCH_DISCORD_REQ
    s.search_no_mic_enabled = AB_const.SEARCH_NO_MIC
    if s.autopartynote_enabled ~= AB_const.AUTOPARTYNOTE then
        -- the toggle carries the partynote clear/verify lifecycle
        AutoBand.cmd_toggle_partynote({})
    end
    s.notify_buffs_enabled = true
    s.printrole_enabled = AB_const.PRINTROLE
    s.print_arrival_notify_tags_enabled = AB_const.PRINT_ARRIVAL_NOTIFY_TAGS
end

-- Templates: cap values and placement (not templates/layout or the default template).
function page_defaults.templates(s, quiet)
    AutoBand.cmd_setroles({ AB_const.DEFAULT_MAX_TANKS, AB_const.DEFAULT_MAX_HEALERS, AB_const.DEFAULT_MAX_DPS }, true)
    s.max_mdps = AB_const.DEFAULT_MAX_MDPS
    s.max_rdps = AB_const.DEFAULT_MAX_RDPS
    s.org_algo_mode = AB_const.DEFAULT_ORG_ALGO
    s.org_algo_role = AB_const.DEFAULT_ORG_ROLE
    AutoBand.set_guild_grouping_enabled(AB_const.GUILD_GROUPING_ENABLED, quiet)
    s.range_sort_distance_threshold = AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
    s.right_click_organize_include_templates = false
end

-- Config: enforcement, composition checks, rank, backfill, auto-kick, social, chat output.
function page_defaults.config(s, quiet)
    AutoBand.set_autokick_enabled(AB_const.AUTOKICK, quiet)
    s.dps_weighting_enabled = AB_const.DPS_WEIGHTING_ENABLED
    local alt_changed = s.alt_speccheck_enabled ~= AB_const.ALTCHECK or
        s.exclude_realm_healer_alt_spec ~= AB_const.EXCLUDE_REALM_HEALER_ALT_SPEC or
        s.bw_sorc_as_mdps ~= AB_const.BW_SORC_AS_MDPS
    s.alt_speccheck_enabled = AB_const.ALTCHECK
    s.exclude_realm_healer_alt_spec = AB_const.EXCLUDE_REALM_HEALER_ALT_SPEC
    s.bw_sorc_as_mdps = AB_const.BW_SORC_AS_MDPS
    if alt_changed then
        if type(AutoBand.mark_alt_spec_snapshot_dirty) == "function" then
            AutoBand.mark_alt_spec_snapshot_dirty()
        end
        AutoBand.need_role_update = true
    end
    AutoBand.set_autokick_low_rank_enabled(AB_const.KICKLOWRNK, quiet)
    local tank, healer, dps = AutoBand.get_saved_rank_requirements(s)
    if tank ~= AB_const.MINIMUM_RANK_TANK or healer ~= AB_const.MINIMUM_RANK_HEALER or dps ~= AB_const.MINIMUM_RANK_DPS then
        AutoBand.set_saved_rank_requirements(AB_const.MINIMUM_RANK_TANK, AB_const.MINIMUM_RANK_HEALER, AB_const.MINIMUM_RANK_DPS, s)
        if type(AutoBand.arm_rank_requirement_grace) == "function" then
            AutoBand.arm_rank_requirement_grace()
        end
    end
    AutoBand.set_backfill_enabled(AB_const.BACKFILL, quiet)
    AutoBand.set_backfill_no_headsups_enabled(AB_const.BACKFILL_NO_HEADS_UPS, quiet)
    AutoBand.set_autokick_toofar_enabled(AB_const.AUTOKICKTOOFAR, quiet)
    s.toofar_radius_setting = AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING
    s.autokick_period = AB_const.KICK_PERIOD
    AutoBand.set_autokick_rvrzone_enabled(AB_const.AUTOKICKRVRZONE, quiet)
    AutoBand.set_autokick_ignorelist_enabled(AB_const.AUTOKICK_IGNORELIST, quiet)
    AutoBand.set_autokick_we_wh_enabled(AB_const.AUTOKICK_WE_WH, quiet)
    s.restrict_same_race = AB_const.RESTRICT_RACE
    AutoBand.set_use_common_race_names(AB_const.USE_COMMON_RACE_NAMES == true, quiet)
    AutoBand.set_guild_priority_mode(AB_const.DEFAULT_GUILD_PRIORITY_MODE, quiet)
    AutoBand.set_friend_priority_mode(AB_const.DEFAULT_FRIEND_PRIORITY_MODE, quiet)
    s.prefix_text = AB_const.DEFAULT_PREFIX_TEXT
    s.prefix_color_name = AB_const.DEFAULT_PREFIX_COLOR_NAME
    s.prefix_use_guild = AB_const.DEFAULT_PREFIX_USE_GUILD
    s.lead_color_name = AB_const.DEFAULT_LEAD_COLOR_NAME
end

function page_defaults.realm(s)
    AutoBand.set_realmrank_lookup_enabled(true, { silent = true, skip_gui_refresh = true })
    local rr_const = AutoBand._realmrank_module and AutoBand._realmrank_module.const or {}
    s.realmrank_refresh_seconds = rr_const.REALMRANK_REFRESH_DEFAULT_SECONDS or 300
    AutoBand.set_realmstats_enabled(false, { silent = true, skip_gui_refresh = true })
    local stats_const = AutoBand._realmstats_module and AutoBand._realmstats_module.const or {}
    s.realmstats_shift_threshold_percent = stats_const.REALMSTATS_SHIFT_THRESHOLD_DEFAULT_PERCENT or 2
    local leaders = AutoBand.WBLeaders
    if type(leaders) == "table" then
        if type(leaders.SetNotifyEnabled) == "function" and s.wbleader_notify_enabled == true then
            leaders.SetNotifyEnabled(false)
        end
        if type(leaders.SetMinMembers) == "function" then
            leaders.SetMinMembers(leaders.default_min_members or 6)
        end
    end
    AutoBand.set_wbleader_tell_alert_enabled(false, { silent = true, skip_gui_refresh = true })
end

AutoBand.SETTINGS_PAGES = { "templates", "tools", "config", "realm" }

function AutoBand.reset_settings_page(page)
    local reset = page_defaults[page]
    if type(reset) ~= "function" or type(AutoBand.saved) ~= "table" then
        return false
    end
    local s = AutoBand.saved
    local before = AutoBand.capture_template_settings_snapshot()
    local dirty_before = AutoBand.template_settings_dirty
    local editor_modified_before = type(AutoBandWindowTemplate) == "table" and AutoBandWindowTemplate.modified or nil
    local normal_before = s.normal_template_settings
    reset(s, { silent = true, skip_gui_refresh = true })
    -- min_rank and the social enabled flags stay legacy mirrors of the new values
    if type(AutoBand.sync_legacy_rank_requirement_fields) == "function" then
        AutoBand.sync_legacy_rank_requirement_fields(s)
    end
    local after = AutoBand.capture_template_settings_snapshot()
    local preset_changed = false
    for key, value in pairs(after) do
        if type(value) ~= "table" and before[key] ~= value then
            preset_changed = true
            break
        end
    end
    if preset_changed then
        AutoBand.mark_template_settings_modified()
    else
        -- setters that ran without a preset change must not leave the preset dirty
        AutoBand.template_settings_dirty = dirty_before
        s.normal_template_settings = normal_before
        if type(AutoBandWindowTemplate) == "table" and editor_modified_before ~= nil then
            AutoBandWindowTemplate.modified = editor_modified_before
        end
    end
    mark_partynote_dirty()
    AB_util.print("Restored " .. page .. " page defaults.")
    AutoBand.refresh_settings_ui({ prefix_text_changed = true, distance_changed = true })
    return true
end

function AutoBand.update(elapsed)
    elapsed = tonumber(elapsed) or 0
    if AutoBand.WBLeaders and AutoBand.WBLeaders.pending_refresh then
        AutoBand.WBLeaders.UpdateRefresh(elapsed)
    end
    if type(AutoBand.realmrank_update_runtime) == "function" then
        AutoBand.realmrank_update_runtime(elapsed)
    end
    AutoBand.UpdateWBLeaderTellHighlight(elapsed)
    if not AutoBand.is_warband_enabled() then
        return
    end
    AutoBand.elapsed = (tonumber(AutoBand.elapsed) or 0) + elapsed
    if type(AutoBand.zonevote_update_sor) == "function" then
        AutoBand.zonevote_update_sor(elapsed)
    end
    if type(AutoBand.zonevote_update_warband_reminder) == "function" then
        AutoBand.zonevote_update_warband_reminder(elapsed)
    end

    ab_social_list_maybe_bootstrap_refresh(elapsed)
    ab_social_list_maybe_background_refresh(elapsed)
    AutoBand.maybe_refresh_wbleaders_background(elapsed)

    if AutoBand.need_role_update then
        AutoBand.role_update_elapsed = (AutoBand.role_update_elapsed or 0) + elapsed
        if AutoBand.role_update_elapsed >= ROLE_UPDATE_INTERVAL then
            AutoBand.cache_dirty = true
            AutoBand.update_roles()
            AutoBand.need_role_update = false
            AutoBand.role_update_elapsed = 0
        end
    else
        AutoBand.role_update_elapsed = 0
    end
    if (AutoBand.elapsed > AB_const.HEARTBEAT) then
        AutoBand.elapsed = 0
        if AutoBand.pending_partynote_live_verify and AutoBand.pending_partynote_live_verify_ticks > 0 then
            AutoBand.pending_partynote_live_verify_ticks = AutoBand.pending_partynote_live_verify_ticks - 1
            if AutoBand.pending_partynote_live_verify_ticks <= 0 then
                clear_partynote_live_verify_state()
            end
        end
        if AutoBand.pending_partynote_refresh and AutoBand.pending_partynote_refresh > 0 then
            AutoBand.pending_partynote_refresh = AutoBand.pending_partynote_refresh - 1
            if AutoBand.pending_partynote_refresh <= 0 then
                AutoBand.pending_partynote_refresh = 0
                AutoBand.force_partynote_refresh = true
            end
        end
        if (tonumber(AutoBand.rank_requirement_grace_ticks_remaining) or 0) > 0 then
            AutoBand.rank_requirement_grace_ticks_remaining = AutoBand.rank_requirement_grace_ticks_remaining - 1
            if AutoBand.rank_requirement_grace_ticks_remaining < 0 then
                AutoBand.rank_requirement_grace_ticks_remaining = 0
            end
        end
        if (tonumber(AutoBand.social_priority_grace_ticks_remaining) or 0) > 0 then
            AutoBand.social_priority_grace_ticks_remaining = AutoBand.social_priority_grace_ticks_remaining - 1
            if AutoBand.social_priority_grace_ticks_remaining < 0 then
                AutoBand.social_priority_grace_ticks_remaining = 0
            end
        end
        local run_autokick = false
        local run_toofar = false
        local run_note = false
        local run_partynote = false

        if not AutoBand.debugon then
            local saved = AutoBand.saved
            if saved then
                run_autokick = saved.autokick_enabled or saved.autokick_low_rank_enabled or
                    saved.autokick_we_wh_enabled or saved.autokick_rvrzone_enabled or
                    saved.autokick_ignorelist_enabled or saved.restrict_same_race
                run_toofar = saved.autokick_toofar_enabled == true
                run_note = saved.autonote_enabled == true and
                    AB_util.get_chat_channel(AB_util.REGION_CHANNEL_KEY) ~= nil
                run_partynote = saved.autopartynote_enabled == true
            end
        end

        if (run_autokick or run_toofar or run_note or run_partynote) and not AutoBand.is_wb_leader() then
            run_autokick = false
            run_toofar = false
            run_note = false
            run_partynote = false
        end
        if AutoBand.pending_group_leave_broadcast then
            run_partynote = false
        end

        if AutoBand.need_role_update then
            AutoBand.cache_dirty = true
        end
        if run_autokick then
            local kicked_any = AutoBand.auto_kick()
            if kicked_any then
                AutoBand.pending_partynote_refresh = 1
            end
        end
        if run_toofar then
            AutoBand.auto_kick_toofar()
        end
        if run_note then
            AutoBand.auto_note()
        end
        if AutoBand.force_partynote_refresh then
            if run_partynote then
                AutoBand.party_note_last_sent_ticks = PARTYNOTE_SUPPRESS_TICKS
                AutoBand.party_note_last_check_ticks = PARTYNOTE_VERIFY_TICKS
            end
            AutoBand.force_partynote_refresh = false
        end
        if run_partynote then
            AutoBand.auto_partynote()
        end
        if AutoBand.need_role_update then
            AutoBand.update_roles()
            AutoBand.need_role_update = false
            AutoBand.role_update_elapsed = 0
        end
        if AutoBand.suppressRoleNotifs and AutoBand.suppressCounter > 0 then
            AutoBand.suppressCounter = AutoBand.suppressCounter - 1
            if AutoBand.suppressCounter == 0 then
                AutoBand.suppressRoleNotifs = false
            end
        end
        if (tonumber(AutoBand.pending_search_roles_delay) or 0) > 0 then
            AutoBand.pending_search_roles_delay = AutoBand.pending_search_roles_delay - 1
        end
        if AutoBand.pending_arrival_seed and AutoBand.inWarband then
            local order_len = AutoBand.wb_arrival_order and #AutoBand.wb_arrival_order or 0
            if order_len == 0 and (AutoBand.pending_arrival_seed_attempts or 0) < ARRIVAL_SEED_MAX_ATTEMPTS then
                refresh_arrival_from_live()
            end
        end
    end

    AutoBand.resume_pending_search_roles()

    if (AutoBand.cmd_current == nil) then
        if (#AutoBand.cmd_queue > 0) then
            AutoBand.cmd_current = table.remove(AutoBand.cmd_queue, 1)
        else
            AutoBand.maybe_broadcast_group_leave()
            return
        end
    end

    AutoBand.cmd_current.ticks = AutoBand.cmd_current.ticks - 1
    if (AutoBand.cmd_current.ticks <= 0) then
        if (AutoBand.debugon or AutoBand.gizilon) then
            AB_util.debug(tostring(AutoBand.cmd_current.cmd))
        end
        -- Final gate: the entry may have been inserted directly or changed since queueing.
        if pm_block.is_blocked(AutoBand.cmd_current.cmd) then
            AutoBand.cmd_current = nil
            pm_block.note_suppressed()
            AutoBand.maybe_broadcast_group_leave()
            return
        end
        SendChatText(towstring(AutoBand.cmd_current.cmd), L"")
        local cmd_tmp = AutoBand.cmd_current
        AutoBand.cmd_current = nil
        if (cmd_tmp.callback) then
            cmd_tmp.callback(cmd_tmp)
        end
        AutoBand.maybe_broadcast_group_leave()
    end
end

function AutoBand.update_roles()
    if not AutoBand.inWarband then
        return
    end
    local wb_obj = AutoBand.get_wb()
    if not wb_obj then
        AB_util.print("wb_obj is nil!")
        return
    end

    local success, err = pcall(function()
        AB_wb:sync_role_notifications(wb_obj)
    end)

    if not success then
        AB_util.print("Error in foreach_player: " .. tostring(err))
        return
    end
end

function AutoBand.cmd_custom_role(args)
    local subcmd = args[1]
    if not subcmd then
        AB_util.print("Usage: /ab customrole <add|remove|delete|list> ...")
        return
    end
    subcmd = subcmd:lower()

    local leader_name_lower = nil
    if GameData and GameData.Player and GameData.Player.name then
        leader_name_lower = tostring(AutoBand.FixString(GameData.Player.name)):lower()
    end

    if subcmd == "add" and args[2] and args[3] then
        local name_param = args[2]
        local name_lower_param = name_param:lower()
        local role_param_new_custom_role = args[3]:lower()

        if role_param_new_custom_role ~= AB_const.TANK and role_param_new_custom_role ~= AB_const.HEALER and role_param_new_custom_role ~= AB_const.MDPS and role_param_new_custom_role ~= AB_const.RDPS then
            AB_util.print("[Error] Invalid role: " .. args[3] .. ". Valid choices are tank, healer, mdps, or rdps.")
            return
        end

        if leader_name_lower and name_lower_param == leader_name_lower then
            -- Leader is setting their own custom role to role_param_new_custom_role
            if role_param_new_custom_role == AB_const.TANK and AutoBand.saved.max_tanks == 0 then
                AB_util.print("[Error] Cannot set your custom role to Tank. Max tanks limit is 0.")
                return
            elseif role_param_new_custom_role == AB_const.HEALER and AutoBand.saved.max_healers == 0 then
                AB_util.print("[Error] Cannot set your custom role to Healer. Max healers limit is 0.")
                return
            elseif (role_param_new_custom_role == AB_const.MDPS or role_param_new_custom_role == AB_const.RDPS) then
                if AutoBand.saved.max_dps == 0 then
                    AB_util.print("[Error] Cannot set your custom role to " .. role_param_new_custom_role .. ". Max DPS limit is 0.")
                    return
                end
                if AutoBand.saved.dps_weighting_enabled then
                    if role_param_new_custom_role == AB_const.MDPS and AutoBand.saved.max_mdps == 0 then
                        AB_util.print("[Error] Cannot set custom role to mDPS. Max mDPS is 0 (DPS weighting active).")
                        return
                    elseif role_param_new_custom_role == AB_const.RDPS and AutoBand.saved.max_rdps == 0 then
                        AB_util.print("[Error] Cannot set custom role to rDPS. Max rDPS is 0 (DPS weighting active).")
                        return
                    end
                end
            end
        end
        AutoBand.saved.custom_roles[name_lower_param] = role_param_new_custom_role
        AB_util.print("Added role override: " .. name_param .. " -> " .. role_param_new_custom_role)
        AutoBand.need_role_update = true

   elseif (subcmd == "remove" or subcmd == "delete") and args[2] then
        local name_to_remove_param = args[2]
        local name_to_remove_lower = name_to_remove_param:lower()

        if leader_name_lower and name_to_remove_lower == leader_name_lower then
            -- Leader is removing their own custom role. Check what they revert to.
            -- The 'true' flag tells GetLeaderEffectiveRoleCategory to ignore the custom role for this specific check.
            local reverted_role = AutoBand.GetLeaderEffectiveRoleCategory(true)

            if reverted_role then
                if reverted_role == AB_const.TANK and AutoBand.saved.max_tanks == 0 then
                    AB_util.print("[Error] Cannot remove your custom role. Your resulting role (Tank) has a max limit of 0.")
                    return
                elseif reverted_role == AB_const.HEALER and AutoBand.saved.max_healers == 0 then
                    AB_util.print("[Error] Cannot remove your custom role. Your resulting role (Healer) has a max limit of 0.")
                    return
                elseif (reverted_role == AB_const.MDPS or reverted_role == AB_const.RDPS) then
                    if AutoBand.saved.max_dps == 0 then
                        AB_util.print("[Error] Cannot remove custom role. Your resulting role ("..reverted_role..") has max DPS limit of 0.")
                        return
                    end
                    if AutoBand.saved.dps_weighting_enabled then
                        if reverted_role == AB_const.MDPS and AutoBand.saved.max_mdps == 0 then
                            AB_util.print("[Error] Cannot remove custom role. Your resulting role (mDPS) has max mDPS limit of 0 (DPS weighting active).")
                            return
                        elseif reverted_role == AB_const.RDPS and AutoBand.saved.max_rdps == 0 then
                            AB_util.print("[Error] Cannot remove custom role. Your resulting role (rDPS) has max rDPS limit of 0 (DPS weighting active).")
                            return
                        end
                    end
                end
            else
                AB_util.print("[Warning] Could not determine your resulting role if custom role is removed. Proceeding with removal.")
            end
        end
        AutoBand.saved.custom_roles[name_to_remove_lower] = nil
        AB_util.print("Removed role override for: " .. name_to_remove_param)
        AutoBand.need_role_update = true
    elseif subcmd == "list" then
        AB_util.print("Custom role overrides:")
        if next(AutoBand.saved.custom_roles) == nil then
            AB_util.print("(none)")
        else
            for k, v in pairs(AutoBand.saved.custom_roles) do
                AB_util.print("- " .. k .. ": " .. v)
            end
        end
    else
        AB_util.print("Usage: /ab customrole add <name> <role>")
        AB_util.print("   /ab customrole remove <name>")
        AB_util.print("   /ab customrole list")
    end
end

-- Queue a chat/game command for AutoBand.update(); disabled warband mode rejects live command work.
function AutoBand.enqueue_command(cmd, ticks, callback, source)
    if AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled() then
        if AutoBand.warband_disabled_enqueue_warned ~= true then
            AB_util.print("AutoBand warband features are disabled. Queued warband command ignored; use /ab enable first.")
            AutoBand.warband_disabled_enqueue_warned = true
        end
        return false
    end
    if pm_block.is_blocked(cmd) then
        pm_block.note_suppressed()
        return false
    end

    ticks = ticks or AB_const.DEFAULT_CMD_TICKS
    table.insert(AutoBand.cmd_queue, {
        ["cmd"] = cmd,
        ["ticks"] = ticks,
        ["callback"] = callback,
        ["source"] = source
    })
    return true
end

function AutoBand.queue_group_leave_broadcast()
    AutoBand.pending_group_leave_broadcast = true
    -- Once leave/disband is pending, suppress background note refresh work so
    -- it cannot recreate the listing note before GROUP_LEAVE fires.
    AutoBand.pending_partynote_refresh = 0
    AutoBand.force_partynote_refresh = false
    AutoBand.partynote_state_dirty = false
    clear_partynote_live_verify_state()
end

function AutoBand.maybe_broadcast_group_leave()
    if not AutoBand.pending_group_leave_broadcast then
        return
    end
    if AutoBand.cmd_current ~= nil or #AutoBand.cmd_queue > 0 then
        return
    end
    AutoBand.pending_group_leave_broadcast = nil
    if type(BroadcastEvent) ~= "function" then
        return
    end
    if not (SystemData and SystemData.Events and SystemData.Events.GROUP_LEAVE) then
        return
    end
    pcall(BroadcastEvent, SystemData.Events.GROUP_LEAVE)
end

function AutoBand.is_player_ignored(player_name_str)
    local key = AutoBand.normalize_wb_player_name(player_name_str)
    if not key then return false end

    local ignore_set = AutoBand.get_ignore_membership_set_ref()
    return ignore_set[key] == true
end

function AutoBand.is_addon_user_kick_target(player_name)
    if not (GameData and GameData.Player and GameData.Player.name) then
        return false
    end
    local self_key = AutoBand.normalize_wb_player_name(GameData.Player.name)
    local target_key = AutoBand.normalize_wb_player_name(player_name)
    return self_key ~= nil and target_key ~= nil and self_key == target_key
end

function AutoBand.enqueue_kick(player_name, msg_reason, source)
    if AutoBand.is_addon_user_kick_target(player_name) then
        return false
    end

    if (msg_reason and not AutoBand.is_player_ignored(tostring(player_name))) then
        -- Use the helper function to get the current prefix format for the tell message
        local prefix_raw_wspace = AutoBand.GetFormattedPrefixRaw(true)
        AutoBand.enqueue_command("/tell " .. tostring(player_name) ..
            " " .. prefix_raw_wspace .. "You were removed from the warband since " .. msg_reason, nil, nil, source)
    end
    AutoBand.enqueue_command(L"/kick " .. player_name, nil, nil, source)
    if msg_reason then
        AB_util.print(L"Kicking " .. player_name .. L" (reason: " .. towstring(msg_reason) .. L")")
    else
        AB_util.print(L"Kicking " .. player_name)
    end
    return true
end

function AutoBand.is_wb_leader()
    local in_wb = AutoBand.inWarband
    if in_wb ~= true and type(IsWarBandActive) == "function" then
        local ok_wb, is_active = pcall(IsWarBandActive)
        if ok_wb then
            in_wb = is_active == true
            AutoBand.inWarband = in_wb
        end
    end
    if not in_wb then
        return false
    end

    local count = AutoBand.last_wb_player_count
    if not count or count == 0 then
        count = count_wb_players()
        AutoBand.last_wb_player_count = count or 0
    end
    if not count or count == 0 then
        return false
    end
    if not GameData or not GameData.Player then
        return false
    end
    local function normalize_name(name_raw)
        if name_raw == nil then
            return nil
        end
        local ok_fix, fixed = pcall(AutoBand.FixString, name_raw)
        if ok_fix and fixed ~= nil then
            name_raw = fixed
        end
        local ok_str, str_val = pcall(tostring, name_raw)
        if not ok_str or not str_val or str_val == "" then
            return nil
        end
        local ok_lower, lowered = pcall(string.lower, str_val)
        if not ok_lower then
            return nil
        end
        return lowered
    end

    local self_name = normalize_name(GameData.Player.name)
    local self_is_group_leader = GameData.Player.isGroupLeader == true
    local self_is_assistant = GameData.Player.isWarbandAssistant == true
    if PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
        local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
        if ok_leader and leader then
            local leader_name = leader.name or leader.leaderName
            local leader_norm = normalize_name(leader_name)
            if leader_norm and self_name then
                if leader_norm == self_name then
                    return true
                end
                -- PartyUtils can lag on promotions; trust the local leader flag if set.
                if self_is_group_leader and not self_is_assistant then
                    return true
                end
                return false
            end
        end
    end

    if self_is_assistant then
        return false
    end
    return self_is_group_leader
end

local function is_warband_active_safe()
    if type(IsWarBandActive) == "function" then
        local ok_wb, is_active = pcall(IsWarBandActive)
        if ok_wb then
            return is_active == true
        end
    end
    return AutoBand.inWarband == true
end

local function is_player_in_combat()
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

function AutoBand.maybe_refresh_wbleaders_background(elapsed)
    if type(elapsed) ~= "number" or elapsed <= 0 then
        return false
    end
    if AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled() then
        AutoBand.clear_combat_resume_deferred("wbleaders_background_refresh")
        return false
    end
    if AutoBand.is_wbleader_background_tracking_enabled and not AutoBand.is_wbleader_background_tracking_enabled() then
        AutoBand.clear_combat_resume_deferred("wbleaders_background_refresh")
        return false
    end

    AutoBand.wbleaders_background_refresh_elapsed =
        (tonumber(AutoBand.wbleaders_background_refresh_elapsed) or 0) + elapsed
    if AutoBand.wbleaders_background_refresh_elapsed < AB_WBLEADERS_BACKGROUND_REFRESH_SECONDS then
        return false
    end
    if is_player_in_combat() then
        AutoBand.wbleaders_background_refresh_elapsed = AB_WBLEADERS_BACKGROUND_REFRESH_SECONDS
        AutoBand.mark_combat_resume_deferred("wbleaders_background_refresh")
        return false
    end
    if not AutoBand.is_combat_resume_ready("wbleaders_background_refresh", elapsed) then
        AutoBand.wbleaders_background_refresh_elapsed = AB_WBLEADERS_BACKGROUND_REFRESH_SECONDS
        return false
    end

    local wbleaders = AutoBand.WBLeaders
    if not (type(wbleaders) == "table" and type(wbleaders.Refresh) == "function") then
        AutoBand.wbleaders_background_refresh_elapsed = 0
        AutoBand.clear_combat_resume_deferred("wbleaders_background_refresh")
        return false
    end

    AutoBand.wbleaders_background_refresh_elapsed = 0
    local include_realmrank = false
    if type(wbleaders.GetNotifyEnabled) == "function" and wbleaders.GetNotifyEnabled() == true then
        include_realmrank = true
    end
    local ok_collect = pcall(wbleaders.Refresh, {
        notify = true,
        include_realmrank = include_realmrank
    })
    return ok_collect == true
end

local function copy_args_table(args)
    local copy = {}
    if type(args) ~= "table" then
        return copy
    end
    for i = 1, #args do
        copy[i] = args[i]
    end
    return copy
end

local function is_party_open_flag()
    if GameData and GameData.Player and GameData.Player.Group and GameData.Player.Group.Settings then
        local is_public = GameData.Player.Group.Settings.isPublic
        if type(is_public) == "boolean" and is_public == true then
            return true
        end
    end
    return false
end

local function party_data_has_members(party_data)
    if type(party_data) ~= "table" then
        return false
    end
    for _, member in ipairs(party_data) do
        if type(member) == "table" and member.name ~= nil then
            local ok_name, name_str = pcall(tostring, member.name)
            if ok_name and name_str ~= "" then
                return true
            end
        end
    end
    return false
end

local function is_party_active()
    if PartyUtils and type(PartyUtils.IsPartyActive) == "function" then
        local ok_active, is_active = pcall(PartyUtils.IsPartyActive)
        if ok_active and type(is_active) == "boolean" and is_active == true then
            return true
        end
    end
    if PartyUtils and type(PartyUtils.GetPartyData) == "function" then
        local ok_party_data, party_data = pcall(PartyUtils.GetPartyData)
        if ok_party_data and party_data_has_members(party_data) then
            return true
        end
    end
    if is_party_open_flag() then
        return true
    end
    return false
end

-- Cheap read-only state for the settings UI action gates.
AutoBand.is_in_active_warband = is_warband_active_safe
AutoBand.is_party_active_safe = is_party_active

function AutoBand.get_promotion_safety_race_label()
    local race_label = "race restriction"
    if AutoBand.raceDetermined then
        local title = AB_const.GetRaceThemeTitle(AutoBand.race)
        if title and title ~= "" then
            race_label = "race restriction (" .. title .. " only)"
        end
    else
        race_label = "race restriction (leader's race)"
    end
    return race_label
end

function AutoBand.build_promotion_safety_popup_preview_details(player_count)
    local preview_count = tonumber(player_count)
    if preview_count == nil then
        preview_count = tonumber(AutoBand.last_wb_player_count) or 0
        if preview_count <= 0 then
            preview_count = 8
        end
    end

    preview_count = math.floor(preview_count)
    if preview_count < 0 then
        preview_count = 0
    end

    local disable_full = preview_count >= 6
    local details = {
        player_count = preview_count,
        disabled_items = {},
        reenable = {},
        force_show = true
    }

    local function add_item(label, command)
        table.insert(details.disabled_items, { label = label, command = command })
        table.insert(details.reenable, command)
    end

    if disable_full and AutoBand.saved.autokick_enabled then
        add_item(
            "role caps (" .. tostring(AutoBand.saved.max_tanks) .. "-" .. tostring(AutoBand.saved.max_healers) .. "-" .. tostring(AutoBand.saved.max_dps) .. ")",
            "/ab ak"
        )
    end
    if disable_full and AutoBand.saved.autokick_low_rank_enabled then
        add_item("rank requirement", "/ab akl")
    end
    if AutoBand.saved.autokick_we_wh_enabled then
        add_item("stealthers autokick", "/ab wewhk")
    end
    if disable_full and AutoBand.saved.autokick_toofar_enabled then
        add_item("too-far autokick", "/ab akf")
    end
    if disable_full and AutoBand.saved.autokick_ignorelist_enabled then
        add_item("ignored-players autokick", "/ab akignore")
    end
    if AutoBand.saved.restrict_same_race then
        add_item(AutoBand.get_promotion_safety_race_label(), "/ab rr")
    end
    if AutoBand.saved.default_template ~= AB_const.EMPTY_TEMPLATE then
        details.template_reset_from = AutoBand.saved.default_template
        details.template_reset_to = AB_const.EMPTY_TEMPLATE
    end

    return details
end

function AutoBand.is_assistant()
    local wb_obj = AutoBand.get_wb() -- Get current group/wb data
    if not wb_obj or type(wb_obj.foreach_player) ~= "function" then
        return false
    end
    local i = 0
    -- Check if we are actually in a group recognised by the addon
    wb_obj:foreach_player(
        function(_gid, _player)
            i = i + 1
        end
    )
    if i == 0 then
        return false -- Can't be assistant if not in a group
    end
    return GameData and GameData.Player and GameData.Player.isWarbandAssistant == true
end

function AutoBand.get_current_toofar_distance()
    local setting = AutoBand.saved.toofar_radius_setting
    if AB_const.TOOFAR_DISTANCE_VALUES[setting] then
        return AB_const.TOOFAR_DISTANCE_VALUES[setting]
    end
    -- Fallback if the setting is somehow corrupted or invalid post-init
    AB_util.print("[Internal Warning] Invalid 'toofar_radius_setting' (" .. tostring(setting) .. ") encountered. Using default distance.")
    return AB_const.TOOFAR_DISTANCE_VALUES[AB_const.DEFAULT_SAVED_TOOFAR_RADIUS_SETTING]
end

function AutoBand.cmd_set_toofar_distance(args)
    local setting_arg = args[1]

    -- Collect all the valid setting keys
    local valid_settings_keys = {}
    for k, _ in pairs(AB_const.TOOFAR_DISTANCE_VALUES) do
        table.insert(valid_settings_keys, k)
    end

    -- Sort them by their numeric distance (ascending)
    table.sort(valid_settings_keys, function(a, b)
        return AB_const.TOOFAR_DISTANCE_VALUES[a] < AB_const.TOOFAR_DISTANCE_VALUES[b]
    end)

    -- Build the usage/options string in sorted order
    local usage_options_str = table.concat(valid_settings_keys, "|")

    -- No argument provided: show usage & current setting
    if not setting_arg then
        AB_util.print(
            "[Error] Missing argument. Usage: /ab tfd <"
            .. usage_options_str .. ">"
        )
        AB_util.print(
            "Current setting: "
            .. AutoBand.saved.toofar_radius_setting
            .. " (" .. AutoBand.get_current_toofar_distance() .. " units). Available: "
            .. table.concat(valid_settings_keys, ", ")
            .. "."
        )
        return
    end

    -- Normalize user input
    setting_arg = string.lower(setting_arg)

    -- If its valid, apply it
    if AB_const.TOOFAR_DISTANCE_VALUES[setting_arg] then
        AutoBand.saved.toofar_radius_setting = setting_arg
        AB_util.print(
            "'Too far' distance setting changed to: "
            .. setting_arg
            .. " (" .. AutoBand.get_current_toofar_distance() .. " units)."
        )
        AutoBand.mark_template_settings_modified()
        AutoBand.refresh_settings_ui()

        -- If auto-kick is on, broadcast the change
        if AutoBand.saved.autokick_toofar_enabled and AutoBand.is_warband_enabled() and AutoBand.is_wb_leader() then
            local prefix_raw_wspace = AutoBand.GetFormattedPrefixRaw(true)
            local current_distance_str = AutoBand.get_current_toofar_distance() .. " units"
            AutoBand.enqueue_command(
                "/wb "
                .. prefix_raw_wspace
                .. "'Too far' distance has been updated to "
                .. current_distance_str
                .. "."
            )
        end

    else
        -- Invalid input: show error + valid options
        AB_util.print(
            "[Error] Invalid setting: '"
            .. setting_arg
            .. "'. Valid settings are: "
            .. table.concat(valid_settings_keys, ", ")
            .. "."
        )
    end
end

-- returns a AB_wb object either from a warband, scenario or dumped_wb
function AutoBand.get_wb(wbdata, preload)
    if (AutoBand.debugon and AutoBand.saved.dumped_wb ~= nil) then
        AB_util.debug("Getting dump " .. AutoBand.saved.default_dump .. " size " ..
            AB_util.size_wb(AutoBand.saved.dumped_wb.group) .. " (Debug mode, bypasses cache)")
        return AB_wb:new(AutoBand.saved.dumped_wb)
    end
    if not AutoBand.cache_dirty and AutoBand.cached_wb then
        return AutoBand.cached_wb
    end
    if type(preload) ~= "table" then
        preload = {}
    end
    if type(preload.roster_signature) ~= "string" and type(AutoBand.wb_roster_signature) == "string" then
        preload.roster_signature = AutoBand.wb_roster_signature
    end
    if AutoBand.saved and AutoBand.saved.alt_speccheck_enabled then
        if type(preload.alt_spec_signature) ~= "string" and type(AutoBand.alt_spec_signature) == "string" then
            preload.alt_spec_signature = AutoBand.alt_spec_signature
        end
        if type(preload.alt_lookup) ~= "table" and
           AutoBand.alt_spec_snapshot_dirty ~= true and
           type(AutoBand.alt_spec_snapshot_lookup) == "table" then
            preload.alt_lookup = AutoBand.alt_spec_snapshot_lookup
        end
    end
    local wb = AB_wb:new()
    local success, err = pcall(function() wb:load_from_wbdata(wbdata, preload) end)
    if not success then
        AB_util.print("[Error] Failed to load warband data during cache refresh: " .. tostring(err))
        return nil
    end
    AutoBand.cached_wb = wb
    AutoBand.alt_spec_signature = wb.alt_spec_signature
    AutoBand.cache_dirty = false
    return AutoBand.cached_wb
end

-- ####### / Commands #######
function AutoBand.parse_cmd(original_msg)
    local cmd_key
    local args_str = "" -- Raw argument string (including spaces, original case)
    local args_tbl = {} -- Split arguments table (for most commands)

    -- Trim leading/trailing whitespace from the whole input
    original_msg = string.gsub(original_msg, "^%s+", "")
    original_msg = string.gsub(original_msg, "%s+$", "")

    -- Find the first space to separate command from arguments
    local first_space = string.find(original_msg, " ", 1, true)

    if first_space then
        -- Extract command part and convert ONLY the command to lowercase for lookup
        cmd_key = string.sub(original_msg, 1, first_space - 1):lower()
        -- Extract the rest of the string (arguments) with original case
        args_str = string.sub(original_msg, first_space + 1)
        -- Only split into a table IF NOT the setprefix command (or others needing raw string)
        if cmd_key ~= "setprefix" and args_str ~= "" then
             args_tbl = StringSplit(args_str)
        end
    else
        -- No space found, the whole message is the command
        cmd_key = original_msg:lower()
        -- args_str remains ""
        -- args_tbl remains {}
    end

    -- Find and execute the command handler
    if cmd_key and AutoBand.cmd[cmd_key] ~= nil then
        local cmd_spec = AutoBand.cmd[cmd_key]
        if AB_WARBAND_MUTATING_COMMANDS[cmd_key] == true and
           not AutoBand.require_warband_features_enabled("/ab " .. tostring(cmd_key)) then
            return
        end

        local handler_func = cmd_spec.f
        if type(handler_func) ~= "function" then
            AB_util.print(
                "[Error] Command handler for /ab " ..
                tostring(cmd_key) ..
                " is unavailable. Try /reloadui, then report if it persists."
            )
            return
        end
        -- Decide what to pass based on the command
        if cmd_key == "setprefix" or cmd_key == "prefix" then
            -- Pass the raw argument string directly for setprefix
            handler_func(args_str)
        else
            -- Pass the split arguments table for other commands
            handler_func(args_tbl)
        end
    else
        AB_util.print("AutoBand unknown command: " .. original_msg)
    end
end
function AutoBand.cmd_setroles(args, called_from_gui)
    called_from_gui = called_from_gui or false

    local function print_if_not_gui(message)
        if not called_from_gui then
            AB_util.print(message)
        end
    end
    local num_tanks_input = tonumber(args[1])
    local num_healers_input = tonumber(args[2])
    local num_dps_input = tonumber(args[3])

    if not num_tanks_input or not num_healers_input or not num_dps_input then
        print_if_not_gui("[Error] Invalid input. Usage: /ab setroles <tanks> <healers> <dps>")
        return
    end

    local num_tanks = math.floor(num_tanks_input)
    local num_healers = math.floor(num_healers_input)
    local num_dps = math.floor(num_dps_input)

    if num_tanks < 0 or num_healers < 0 or num_dps < 0 then
        print_if_not_gui("[Error] Role counts cannot be negative.")
        return
    end

    if num_tanks + num_healers + num_dps ~= 24 then
        print_if_not_gui("[Error] Role counts must sum to 24. Provided: " .. num_tanks .. "+" .. num_healers .. "+" .. num_dps .. " = " .. (num_tanks + num_healers + num_dps))
        return
    end

    local leader_effective_role = AutoBand.GetLeaderEffectiveRoleCategory()
    if not leader_effective_role then
        print_if_not_gui("[Warning] Could not determine your effective role. Proceeding with setting roles, but validation might be incomplete.")
    else
        if leader_effective_role == AB_const.TANK and num_tanks == 0 then
            print_if_not_gui("[Error] Cannot set max tanks to 0. Your current effective role is Tank.")
            return
        elseif leader_effective_role == AB_const.HEALER and num_healers == 0 then
            print_if_not_gui("[Error] Cannot set max healers to 0. Your current effective role is Healer.")
            return
        elseif (leader_effective_role == AB_const.MDPS or leader_effective_role == AB_const.RDPS) and num_dps == 0 then
            print_if_not_gui("[Error] Cannot set max DPS to 0. Your current effective role is " .. leader_effective_role .. ".")
            return
        end
    end

    AutoBand.saved.max_tanks = num_tanks
    AutoBand.saved.max_healers = num_healers
    AutoBand.saved.max_dps = num_dps

    print_if_not_gui("Role limits set to: Tanks=" .. num_tanks .. ", Healers=" .. num_healers .. ", DPS=" .. num_dps)

    if AutoBand.saved.max_mdps + AutoBand.saved.max_rdps ~= AutoBand.saved.max_dps then
        print_if_not_gui("[Warning] Max DPS changed. Resetting mDPS/rDPS weights proportionally.")
        if AutoBand.saved.max_dps > 0 then
            AutoBand.saved.max_rdps = math.floor(AutoBand.saved.max_dps / 2)
            AutoBand.saved.max_mdps = AutoBand.saved.max_dps - AutoBand.saved.max_rdps
            if AutoBand.saved.max_mdps == 0 and AutoBand.saved.max_dps > 0 and AutoBand.saved.max_rdps > 0 then
                AutoBand.saved.max_mdps = 1
                AutoBand.saved.max_rdps = AutoBand.saved.max_dps - 1
            elseif AutoBand.saved.max_rdps == 0 and AutoBand.saved.max_dps > 0 and AutoBand.saved.max_mdps > 0 then
                AutoBand.saved.max_rdps = 1
                AutoBand.saved.max_mdps = AutoBand.saved.max_dps - 1
            end
        else
            AutoBand.saved.max_mdps = 0
            AutoBand.saved.max_rdps = 0
        end
        print_if_not_gui(" -> New mDPS/rDPS weights: mDPS=" .. AutoBand.saved.max_mdps .. ", rDPS=" .. AutoBand.saved.max_rdps)
    end

    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_resetroles(_args)
    AutoBand.saved.max_tanks = AB_const.DEFAULT_MAX_TANKS
    AutoBand.saved.max_healers = AB_const.DEFAULT_MAX_HEALERS
    AutoBand.saved.max_dps = AB_const.DEFAULT_MAX_DPS
    AutoBand.saved.max_mdps = AB_const.DEFAULT_MAX_MDPS
    AutoBand.saved.max_rdps = AB_const.DEFAULT_MAX_RDPS
    AB_util.print("Role limits reset to default: Tanks=" .. AutoBand.saved.max_tanks .. ", Healers=" .. AutoBand.saved.max_healers .. ", DPS=" .. AutoBand.saved.max_dps)
    AutoBand.cmd_setroles({AutoBand.saved.max_tanks, AutoBand.saved.max_healers, AutoBand.saved.max_dps}, true)
end

-- Concise status snapshot (version, modes, caps) without dumping all settings
function AutoBand.cmd_status(_args)
    local mode_label = "Spread"
    if AutoBand.saved.org_algo_mode == AB_const.MODE_AGGREGATE then mode_label = "Aggregate" end

    local max_t = AutoBand.saved.max_tanks or AB_const.DEFAULT_MAX_TANKS
    local max_h = AutoBand.saved.max_healers or AB_const.DEFAULT_MAX_HEALERS
    local max_d = AutoBand.saved.max_dps or AB_const.DEFAULT_MAX_DPS
    local max_md = AutoBand.saved.max_mdps or AB_const.DEFAULT_MAX_MDPS
    local max_rd = AutoBand.saved.max_rdps or AB_const.DEFAULT_MAX_RDPS
    local caps_line
    if AutoBand.saved.dps_weighting_enabled then
        caps_line = string.format("Caps T/H/D: %d/%d/%d (m/r %d/%d)", max_t, max_h, max_d, max_md, max_rd)
    else
        caps_line = string.format("Caps T/H/D: %d/%d/%d", max_t, max_h, max_d)
    end

    local dist_thr = AutoBand.saved.range_sort_distance_threshold or AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
    local default_tpl = AutoBand.saved.default_template or "(none)"
    local ak_on = AutoBand.saved.autokick_enabled and "on" or "off"
    local min_rank_tank, min_rank_healer, min_rank_dps = AutoBand.get_effective_saved_rank_requirements()
    local min_rank_line = "Level req: off"
    if AutoBand.saved.autokick_low_rank_enabled then
        min_rank_line = "Level req: " .. AutoBand.build_rank_requirement_text(min_rank_tank, min_rank_healer, min_rank_dps, "compact")
    end

    local wb_enabled = AutoBand.is_warband_enabled() and "on" or "off"
    local pm_state = AutoBand.is_pm_block_active() and "on" or "off"
    AB_util.print(string.format("AutoBand v%s | WB: %s | PM block: %s | mode: %s | dist thr: %d | autokick: %s | %s", AB_const.VERSION, wb_enabled, pm_state, mode_label, dist_thr, ak_on, min_rank_line))
    AB_util.print(string.format("%s | Default template: %s", caps_line, default_tpl))
    if AutoBand and AutoBand.get_wb then
        local wb_obj = AutoBand.get_wb()
        if wb_obj and wb_obj.player_count and wb_obj.player_count > 0 then
            local summary = AB_util.roles_summary_line(wb_obj)
            if summary and summary ~= "" then
                local lead_tag = ""
                if AutoBand.is_wb_leader and not AutoBand.is_wb_leader() then
                    lead_tag = " (not lead)"
                end
                AB_util.print("Current WB" .. lead_tag .. " (T-H-D): " .. summary)
            end
            local can_show_backfill_route = false
            if AutoBand.is_wb_leader then
                local ok_lead, is_lead = pcall(AutoBand.is_wb_leader)
                if ok_lead and is_lead then
                    can_show_backfill_route = true
                end
            end
            if can_show_backfill_route then
                local route_members, route_mode = AutoBand.get_backfill_route_members(wb_obj)
                if route_mode == "disabled" then
                    AB_util.print("Trim order: off.")
                elseif route_mode == "idle" then
                    AB_util.print("Trim order: inactive (enable /ab ak or /ab akl).")
                else
                    local route_line = AutoBand.format_backfill_route_members(route_members, BACKFILL_ROUTE_STATUS_MAX_ENTRIES)
                    AB_util.print("Trim order (" .. route_mode .. "): " .. route_line)
                end
            end
        end
    end
end

function AutoBand.cmd_usage(_args)
    local ab = "/autoband "
    if AutoBand.has_shortslash then
        ab = "/ab "
    end
    AB_util.print("[Autoband v" .. AB_const.VERSION .. " commands]")
    for _, cmd in ipairs(AutoBand.cmd_ordered) do
        if cmd.help ~= "" or AutoBand.debugon then
            -- Use resolved_help which handles functions
            local help_text = cmd.resolved_help or ""
            if type(cmd.help) == "function" then -- Resolve again just in case order changes things (unlikely here)
                help_text = cmd.help()
            end
            AB_util.print(ab .. cmd.key .. " - " .. help_text)
        end
    end
end

function AutoBand.cmd_show(_args)
    AB_util.print("[Autoband v" .. AB_const.VERSION .. " settings]")
    local current_prefix_example = AutoBand.GetFormattedPrefixRaw(false) -- Get raw string example
    local prefix_color_name = AutoBand.saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME
    local lead_color_name = AutoBand.saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME
    AB_util.print("Chat Prefix: " .. current_prefix_example .. " (Color: " .. build_colored_color_name_link_raw(prefix_color_name) .. ")")
    AB_util.print("Use Guild Prefix in searches: " .. tostring(AutoBand.saved.prefix_use_guild))
    AB_util.print("WB Lead Mention Color: " .. build_colored_color_name_link_raw(lead_color_name) .. ".")
    AB_util.print("Faction detected as " .. (AutoBand.faction or "Unknown") .. ".")
    AB_util.print("Race detected as " .. (AutoBand.race or "Unknown") .. ".")
    AB_util.print("Warband automation enabled: " .. tostring(AutoBand.is_warband_enabled()))
    AB_util.print("Block AutoBand PMs: " .. tostring(AutoBand.is_pm_block_active()))
    AB_util.print("Default template: " .. AutoBand.saved.default_template)
    AB_util.print("Right-click icon organize menu: always enabled")
    AB_util.print("Right-click icon menu includes template organize options: " .. tostring(AutoBand.saved.right_click_organize_include_templates))
    AB_util.print("WB-Leader tell alerts: " .. tostring(AutoBand.saved.wbleader_tell_alert_enabled == true))
    AB_util.print("Auto kick too far players: " .. tostring(AutoBand.saved.autokick_toofar_enabled))
    AB_util.print(" -> 'Too far' distance setting: " .. AutoBand.saved.toofar_radius_setting .. " (" .. AutoBand.get_current_toofar_distance() .. " units)")
    AB_util.print("Auto kick too far players timeout: " .. tostring(AutoBand.saved.autokick_period))
    AB_util.print("/ab org distance threshold: " .. AutoBand.saved.range_sort_distance_threshold .. " units.")
    local min_rank_tank, min_rank_healer, min_rank_dps = AutoBand.get_effective_saved_rank_requirements()
    if min_rank_tank == min_rank_healer and min_rank_healer == min_rank_dps then
        AB_util.print("Minimum rank requirement: " .. AutoBand.format_rank_requirement_value(min_rank_tank))
    else
        AB_util.print("Minimum rank requirement (tank): " .. AutoBand.format_rank_requirement_value(min_rank_tank))
        AB_util.print("Minimum rank requirement (healer): " .. AutoBand.format_rank_requirement_value(min_rank_healer))
        AB_util.print("Minimum rank requirement (dps): " .. AutoBand.format_rank_requirement_value(min_rank_dps))
    end
    AB_util.print("Auto enforcing " .. AutoBand.saved.max_tanks .. "-" .. AutoBand.saved.max_healers .. "-" .. AutoBand.saved.max_dps .." WB (autokick): " .. tostring(AutoBand.saved.autokick_enabled))
    AB_util.print(" -> DPS Weighting Enabled: " .. tostring(AutoBand.saved.dps_weighting_enabled))
    if AutoBand.saved.dps_weighting_enabled then
        AB_util.print("    -> Max Melee DPS: " .. tostring(AutoBand.saved.max_mdps))
        AB_util.print("    -> Max Ranged DPS: " .. tostring(AutoBand.saved.max_rdps))
    end
    AB_util.print("Auto kick players below rank req: " .. tostring(AutoBand.saved.autokick_low_rank_enabled))
    AB_util.print("BackFill: " .. tostring(AutoBand.saved.backfill_enabled))
    AB_util.print("BackFill no heads-ups: " .. tostring(AutoBand.saved.backfill_no_headsups_enabled == true))
    AB_util.print(AB_const.GetAutoKickStealthersLabel("Auto kick") .. ": " .. tostring(AutoBand.saved.autokick_we_wh_enabled))
    AB_util.print("Auto kick players in scenarios: " .. tostring(AutoBand.saved.autokick_rvrzone_enabled))
    AB_util.print("Auto kick ignored players: " .. tostring(AutoBand.saved.autokick_ignorelist_enabled))
    AB_util.print("Guild priority mode: " .. AutoBand.get_social_priority_mode_label(AutoBand.get_saved_social_priority_mode("guild")))
    AB_util.print("Friend priority mode: " .. AutoBand.get_social_priority_mode_label(AutoBand.get_saved_social_priority_mode("friend")))
    AB_util.print("Group guildies together during organize: " .. tostring(AutoBand.saved.guild_grouping_enabled == true))
    AB_util.print("Notify warband after organize: " .. tostring(AutoBand.saved.notify_buffs_enabled))
    AB_util.print("Use alt spec check: " .. tostring(AutoBand.saved.alt_speccheck_enabled))
    AB_util.print(AB_const.GetExcludeRealmHealerAltSpecLabel() .. " from alt spec check: " .. tostring(AutoBand.saved.exclude_realm_healer_alt_spec))
    AB_util.print("Auto note in Region: " .. tostring(AutoBand.saved.autonote_enabled) .. AutoBand.autonote_region_status_suffix())
    AB_util.print("Print role assignments: " .. tostring(AutoBand.saved.printrole_enabled))
    AB_util.print("Show arrival tags in role notifications: " .. tostring(AutoBand.saved.print_arrival_notify_tags_enabled))
    local bw_sorc_label = AB_const.GetBWSorcAsMDPSLabel() -- Get faction-aware label
    AB_util.print(bw_sorc_label .. ": " .. tostring(AutoBand.saved.bw_sorc_as_mdps))
    local restrict_race_label = AB_const.GetRestrictRaceLabel() -- Get race-aware label
    AB_util.print(restrict_race_label .. ": " .. tostring(AutoBand.saved.restrict_same_race))
    AB_util.print("Use common race names: " .. tostring(AutoBand.saved.use_common_race_names))
    if AutoBand.current_purpose then
        local purpose_display = AB_const.WARBAND_PURPOSES[AutoBand.current_purpose].display or AutoBand.current_purpose
        AB_util.print("Current warband purpose: " .. purpose_display)
    else
        AB_util.print("Current warband purpose: none set")
    end
    if (AutoBand.debugon) then
        AB_util.print("Data dumped: " .. tostring(AutoBand.saved.dumped_wb ~= nil))
        AB_util.print("Debug mode: true")
    end
end

function AutoBand.cmd_debug(_args)
    AutoBand.debugon = not AutoBand.debugon
    AB_util.print("Debug mode: " .. tostring(AutoBand.debugon))
end

function AutoBand.cmd_promotion_popup_preview(args)
    if type(AutoBandWindowLeaderPromotionPopup) ~= "table"
        or type(AutoBandWindowLeaderPromotionPopup.ShowForPromotionSafety) ~= "function" then
        AB_util.print("[Error] Promotion safety popup window is not available.")
        return
    end

    local player_count = nil
    if type(args) == "table" and args[1] ~= nil then
        player_count = tonumber(args[1])
        if player_count == nil then
            AB_util.print("Usage: /ab promopopup [player_count]")
            return
        end
    end

    AutoBandWindowLeaderPromotionPopup.ShowForPromotionSafety(
        AutoBand.build_promotion_safety_popup_preview_details(player_count)
    )
end

function AutoBand.cmd_flag_autokick(_args)
    AutoBand.set_autokick_enabled(not AutoBand.saved.autokick_enabled)
end

function AutoBand.cmd_flag_autokick_toofar(_args)
    AutoBand.set_autokick_toofar_enabled(not AutoBand.saved.autokick_toofar_enabled)
end

-- Status text for an enabled auto-search that is idle because Region is not joined.
function AutoBand.autonote_region_status_suffix()
    if AutoBand.saved.autonote_enabled ~= true or AB_util.get_chat_channel(AB_util.REGION_CHANNEL_KEY) then
        return ""
    end
    return " (inactive: " .. AB_util.chat_channel_requirement_text("Region") .. ")"
end

function AutoBand.cmd_flag_autonote(_args)
    AutoBand.saved.autonote_enabled = not AutoBand.saved.autonote_enabled
    AB_util.print("Auto note in Region: " .. tostring(AutoBand.saved.autonote_enabled) .. AutoBand.autonote_region_status_suffix())
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_toggle_partynote(_args)
    AutoBand.saved.autopartynote_enabled = not AutoBand.saved.autopartynote_enabled
    AB_util.print("Auto update /partynote: " .. tostring(AutoBand.saved.autopartynote_enabled))
    AutoBand.mark_template_settings_modified()
    if not AutoBand.saved.autopartynote_enabled then
        AutoBand.clear_partynote_if_autoband()
        AutoBand.party_note_last_text = nil
        AutoBand.party_note_last_roster_signature = nil
        AutoBand.party_note_last_alt_signature = nil
        AutoBand.party_note_last_sent_ticks = PARTYNOTE_SUPPRESS_TICKS
        AutoBand.party_note_last_check_ticks = PARTYNOTE_VERIFY_TICKS
        AutoBand.pending_partynote_refresh = 0
        AutoBand.force_partynote_refresh = false
        clear_partynote_live_verify_state()
    end
    AutoBand.refresh_settings_ui()
end

function AutoBand.build_search_discord_suffix()
    local saved = AutoBand.saved or {}
    if saved.search_discord_req_enabled ~= true then
        return ""
    end

    if saved.search_no_mic_enabled == true then
        return " - Discord req (no mic needed)"
    end
    return " - Discord req"
end

local function promote_priority_can_affect_enforcement(saved)
    saved = saved or AutoBand.saved or {}
    if saved.autokick_enabled == true then
        return true
    end
    if saved.backfill_enabled == true and saved.autokick_low_rank_enabled == true then
        return true
    end
    return false
end

local function get_active_promote_priority_sources(saved)
    saved = saved or AutoBand.saved or {}
    local guild_active = social_priority_mode_is_promote(AutoBand.get_saved_social_priority_mode("guild", saved))
    local friend_active = social_priority_mode_is_promote(AutoBand.get_saved_social_priority_mode("friend", saved))
    if not promote_priority_can_affect_enforcement(saved) then
        guild_active = false
        friend_active = false
    end
    return guild_active, friend_active
end

local function has_active_promote_priority(saved)
    local guild_active, friend_active = get_active_promote_priority_sources(saved)
    return guild_active or friend_active
end

local function build_party_note_promote_suffix(saved)
    if has_active_promote_priority(saved) then
        return " (gp)"
    end
    return ""
end

function AutoBand.build_search_priority_suffix(saved)
    local guild_active, friend_active = get_active_promote_priority_sources(saved)
    if guild_active and friend_active then
        return " - Guild/friend priority"
    elseif guild_active then
        return " - Guild priority"
    elseif friend_active then
        return " - Friend priority"
    end
    return ""
end

function AutoBand.cmd_toggle_autoform_search(args)
    local arg1 = args and args[1]
    if arg1 then
        local lower = arg1:lower()
        if lower == "on" or lower == "true" or lower == "1" then
            AutoBand.saved.autoform_search_enabled = true
        elseif lower == "off" or lower == "false" or lower == "0" then
            AutoBand.saved.autoform_search_enabled = false
        else
            AB_util.print("Usage: /ab autoform [on|off]")
            return
        end
    else
        AutoBand.saved.autoform_search_enabled = not AutoBand.saved.autoform_search_enabled
    end
    AB_util.print("Autoform WB when searching: " .. tostring(AutoBand.saved.autoform_search_enabled))
    AutoBand.mark_template_settings_modified()

    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_form(_args)
    if not AutoBand.is_warband_enabled() then
        AutoBand.set_warband_enabled(true)
    end

    if is_warband_active_safe() then
        AB_util.print("Already in a warband.")
        return
    end

    local party_active = is_party_active()

    local is_party_leader = GameData and GameData.Player and GameData.Player.isGroupLeader == true
    if party_active and not is_party_leader then
        AB_util.print("[Error] Only the party leader can form a warband.")
        return
    end

    if party_active then
        if is_party_open_flag() then
            AB_util.print("Converting party to warband...")
            AutoBand.enqueue_command("/warbandc")
        else
            AB_util.print("Opening party, then converting to warband...")
            AutoBand.enqueue_command("/partyopen")
            AutoBand.enqueue_command("/warbandc", FORM_WARBAND_DELAY_TICKS)
        end
        return
    end

    AB_util.print("Creating open party, then converting to warband...")
    AutoBand.enqueue_command("/openpartyinterest")
    AutoBand.enqueue_command("/warbandc", FORM_WARBAND_DELAY_TICKS)
end

function AutoBand.cmd_dump(args)
    if (args[1] == nil) then
        AB_util.print("[error] Missing argument")
        return
    end
    local wb = AB_wb:new()
    wb:load_from_wbdata()
    AutoBand.saved.dumped_wb = wb
    AutoBand.saved.default_dump = args[1]
    AutoBand.saved.dumps[args[1]] = wb
    AB_util.print("Dump complete")
end

function AutoBand.cmd_cleardumps(_args)
    AutoBand.saved.dumped_wb = nil
    AutoBand.saved.dumps = {}
    AutoBand.saved.default_dump = nil
end

function AutoBand.cmd_kick_toofar(_args)
    if not AutoBand.require_warband_features_enabled("kicking warband members") then
        return
    end

    if (not AutoBand.is_wb_leader()) then
        AB_util.print("[error] You need to be a wb leader")
        return
    end
    local wb_obj = AutoBand.get_wb()
    local current_toofar_distance = AutoBand.get_current_toofar_distance() -- Get dynamic distance
    local kicked_count = 0
    local exempt_count = 0
    local guild_member_set, friend_member_set = get_toofar_social_priority_membership_sets(AutoBand.saved)
    local mp_lookup = BuildMapPointLookup()

    wb_obj:foreach_player(
        function(_gid, player)
            local mpd = mp_lookup[player.name]
            if mpd and mpd.distance then
                player.distance = mpd.distance * DISTANCE_FIX_COEFFICIENT
                if player.distance > current_toofar_distance then
                    if player_is_exempt_from_toofar_kick(player.name, guild_member_set, friend_member_set, AutoBand.saved) then
                        exempt_count = exempt_count + 1
                    else
                        if AutoBand.enqueue_kick(player.name, "not following leader (distance " .. math.floor(player.distance) .. " > " .. current_toofar_distance .. ")") then
                            kicked_count = kicked_count + 1
                        end
                    end
                end
            end
        end
    )
    if kicked_count > 0 then
         local msg = "Kicked " .. kicked_count .. " player(s) for being too far (current threshold: " .. current_toofar_distance .. " units)."
         if exempt_count > 0 then
             msg = msg .. " Skipped " .. exempt_count .. " protected/promoted player(s)."
         end
         AB_util.print(msg)
    else
         if exempt_count > 0 then
             AB_util.print("No kickable players found exceeding the 'too far' distance of " .. current_toofar_distance .. " units. Skipped " .. exempt_count .. " protected/promoted player(s).")
         else
             AB_util.print("No players found exceeding the 'too far' distance of " .. current_toofar_distance .. " units.")
         end
    end
end

function AutoBand.cmd_list_toofar(_args)
  local wb_obj = AutoBand.get_wb()
  local current_toofar_distance = AutoBand.get_current_toofar_distance() -- Get dynamic distance
  local listed_count = 0

  AB_util.print("Players further than " .. current_toofar_distance .. " units:")

  local mp_lookup = BuildMapPointLookup()
  wb_obj:foreach_player(
    function(_gid, player)
      local mpd = mp_lookup[player.name]
      if mpd and mpd.distance then
        player.distance = mpd.distance * DISTANCE_FIX_COEFFICIENT
        if player.distance > current_toofar_distance then
          local zoneName = L"Unknown Zone"
          if player.zoneNum and player.zoneNum ~= 0 then
            local success, zn = pcall(GetZoneName, player.zoneNum)
            if success and zn and zn ~= L"" then
              zoneName = zn
            elseif success and (zn == L"" or zn == nil) then
              zoneName = L"Zone ID: " .. towstring(player.zoneNum)
            end
          elseif player.zoneNum == 0 then
            zoneName = L"Offline"
          end
          local message = L"- " .. towstring(player.name) ..
                  L" (distance: " .. towstring(math.floor(player.distance)) ..
                  L", zone: " .. zoneName .. L")"
          AB_util.print(message)
          listed_count = listed_count + 1
        end
      end
    end
  )
  if listed_count == 0 then
    AB_util.print("(none found)")
  end
end

-- Backwards-compatible alias for legacy name used in Tools tab mapping
function AutoBand.cmd_list_offline(args)
  return AutoBand.cmd_list_toofar(args)
end

function AutoBand.cmd_list_zone(_args)
    local wb_obj = AutoBand.get_wb()
    if (wb_obj.player_count == 0) then
        AB_util.debug("No wb data found")
        return
    end

    local players_by_zid = AutoBand.get_players_zone(wb_obj)
    local num_valid_zones = AB_util.size_table(players_by_zid["valid_as"])
    if (players_by_zid["valid_as"] and num_valid_zones > 0) then
        AB_util.print(AB_const.HEADER_MARGIN ..
            " Leader's and assistants' zones " ..
            AB_const.HEADER_MARGIN)
        for zid, as_zone in pairs(players_by_zid["valid_as"]) do
            local str = ""
            local num_players = AB_util.size_table(players_by_zid["valid_p"][zid])
            local zone_name_str = AB_util.get_zone_name_sanitized(zid)
            str = str .. tostring(zone_name_str) .. " (#" .. num_players .. ") "
            for _, player in ipairs(as_zone) do
                if (player.isGroupLeader) then
                    str = str .. tostring(player.name) ..
                    "(" .. AB_const.ABBREVATIONS["LEADER"] .. ") "
                else
                    str = str .. tostring(player.name) ..
                    "(" .. AB_const.ABBREVATIONS["ASSISTANT"] .. ") "
                end
            end
            AB_util.print(str)
        end
    end

    local num_invalid_zones = AB_util.size_table(players_by_zid["other"])
    if (players_by_zid["other"] and num_invalid_zones > 0) then
        AB_util.print(AB_const.HEADER_MARGIN ..
            " " ..
            AB_const.LABEL_NOTSAMEZONE ..
            " " ..
            AB_const.HEADER_MARGIN)
        for zid, other_zone in pairs(players_by_zid["other"]) do
            local str = ""
            local zone_name_str2 = AB_util.get_zone_name_sanitized(zid)
            str = str .. zone_name_str2 .. " (#" .. #other_zone .. ") "
            for _, player in ipairs(other_zone) do
                str = str .. tostring(player.name) .. " "
            end
            AB_util.print(str)
        end
    end
end

function AutoBand.cmd_kick_notinzone(_args)
    if not AutoBand.require_warband_features_enabled("kicking warband members") then
        return
    end

    if (not AutoBand.is_wb_leader()) then
        AB_util.print("[error] You need to be a wb leader")
        return
    end

    local wb_obj = AutoBand.get_wb()
    if (wb_obj.player_count == 0) then
        AB_util.debug("No wb data found")
        return
    end

    local zone_name_sanitized = AB_util.get_zone_name_sanitized
    local players_by_zid = AutoBand.get_players_zone(wb_obj)
    local num_valid_zones = AB_util.size_table(players_by_zid["valid_as"])

    if (players_by_zid["valid_as"] and num_valid_zones > 0) then
        local safe_zones = players_by_zid["valid_safe"] or players_by_zid["valid_as"]
        local safe_zone_ids = {}
        for zid, _ in pairs(safe_zones) do
            if zid ~= 0 then
                table.insert(safe_zone_ids, zid)
            end
        end
        table.sort(safe_zone_ids, function(a, b)
            local na, nb = tonumber(a), tonumber(b)
            if na and nb then
                return na < nb
            end
            if na then return true end
            if nb then return false end
            return tostring(a) < tostring(b)
        end)
        local zone_names = {}
        for _, zid in ipairs(safe_zone_ids) do
            table.insert(zone_names, tostring(zone_name_sanitized(zid)))
        end
        local valid_zone_str = table.concat(zone_names, ", ")

        local num_invalid_zones = AB_util.size_table(players_by_zid["other"])
        if (players_by_zid["other"] and num_invalid_zones > 0) then
            AB_util.print("Kicking " .. AB_const.LABEL_NOTSAMEZONE)
            for zid, other_zone in pairs(players_by_zid["other"]) do
                if (zid ~= 0) then
                    for _, player in ipairs(other_zone) do
                        AutoBand.enqueue_kick(player.name,
                            "you are not in one of the required zones {" ..
                            valid_zone_str .. "}")
                    end
                end
            end
        end
    end
    AB_util.print("Zone kick complete")
end

-- ZoneVote runtime lives in AB_zonevote.lua.

local function get_safe_lead_assist_zone_set(valid_as)
    local safe_zones = {}
    if (not valid_as) then
        return safe_zones
    end
    local pairings = AB_const.CAMPAIGN_ZONE_PAIRINGS
    for zid, _ in pairs(valid_as) do
        safe_zones[zid] = true
        if (pairings and pairings[zid]) then
            safe_zones[pairings[zid]] = true
        end
    end
    return safe_zones
end

function AutoBand.is_allowed_rvr_or_city_zone(zone_num)
    if zone_num == nil or zone_num == 0 then
        return false
    end

    local zone_id = tonumber(zone_num)
    if zone_id then
        zone_id = math.floor(zone_id)
    end

    local allowed_set = AutoBand.allowed_rvr_zones_set
    if type(allowed_set) == "table" then
        if zone_id and allowed_set[zone_id] then
            return true
        end
        if allowed_set[zone_num] then
            return true
        end
    end

    if AB_util and type(AB_util.get_zone_name_sanitized) == "function" then
        local ok_zone, zone_name = pcall(AB_util.get_zone_name_sanitized, zone_id or zone_num)
        if ok_zone and zone_name and string.lower(tostring(zone_name)) == "dangerous territory" then
            return true
        end
    end

    return false
end

function AutoBand.cmd_toggle_autokick_we_wh(_args)
    AutoBand.set_autokick_we_wh_enabled(not AutoBand.saved.autokick_we_wh_enabled)
end

function AutoBand.cmd_organize(args)
    if not AutoBand.require_warband_features_enabled("organizing the warband") then
        return
    end

    local is_leader_perm = AutoBand.is_wb_leader()
    local is_assist_perm = AutoBand.is_assistant()
    local debug_mode = AutoBand.debugon

    if not (is_leader_perm or is_assist_perm or debug_mode) then
        AB_util.print("[error] You need to be a wb leader or assistant")
        return
    end

    -- Parse flags
    local organize_by_distance_param = false
    local debug_print_requested = false
    local filtered_args = {}
    if args and #args > 0 then
        for i=1,#args do
            local a = tostring(args[i]):lower()
            if a == "debug" then
                debug_print_requested = true
            else
                table.insert(filtered_args, args[i])
            end
        end
    end

    local template_name_arg = filtered_args[1] -- Could be template name OR "distance"
    local distance_keyword_arg = filtered_args[2] -- Could be "distance" if args[1] is a template name

    -- Determine if the "distance" parameter is used and which template key to use
    local tpl_to_use_key

    if template_name_arg and string.lower(template_name_arg) == "distance" then
        organize_by_distance_param = true
        tpl_to_use_key = AutoBand.saved.default_template -- /ab org distance -> use default
        -- No specific template name was given before "distance"
    elseif distance_keyword_arg and string.lower(distance_keyword_arg) == "distance" then
        organize_by_distance_param = true
        tpl_to_use_key = template_name_arg -- /ab org <template> distance -> use specific_template
    else
        -- No "distance" keyword, or not in a recognized position for this simple parse
        tpl_to_use_key = template_name_arg or AutoBand.saved.default_template -- /ab org [template_name_or_nil]
    end

    local tpl_entry = AutoBand.saved.templates[tpl_to_use_key]
    local tpl = AutoBand.template_get_layout(tpl_entry)
    if not tpl and tpl_to_use_key ~= AB_const.EMPTY_TEMPLATE then
        AB_util.print("[Warning] Template '" .. tostring(tpl_to_use_key) .. "' not found. Using empty layout.")
        tpl = nil -- AB_org.auto_organize and AB_template.match will handle nil as empty
    end

    if tpl_to_use_key == AB_const.EMPTY_TEMPLATE or tpl_to_use_key == AB_const.CURRENT_WB or tpl_entry ~= nil then
        if type(AutoBand.remember_active_template_selection) == "function" then
            AutoBand.remember_active_template_selection(tpl_to_use_key)
        else
            AutoBand.template_active_key = tpl_to_use_key or AB_const.EMPTY_TEMPLATE
        end
    end

    if tpl_to_use_key == AB_const.EMPTY_TEMPLATE and type(AutoBand.restore_normal_template_settings) == "function" then
        AutoBand.restore_normal_template_settings({ silent = true, template_name = AB_const.EMPTY_TEMPLATE })
    elseif tpl_entry and type(AutoBand.apply_template_settings) == "function" then
        AutoBand.apply_template_settings(tpl_entry, { silent = true, template_name = tpl_to_use_key })
    end

    -- Range processing logic
    AB_org.is_distance_sort_active = false -- Reset flag

    if organize_by_distance_param then
        if is_leader_perm or debug_mode then
            AB_org.is_distance_sort_active = true
            local current_player_name_for_log = (GameData.Player and GameData.Player.name and tostring(GameData.Player.name)) or "Current Player"
            AB_util.print("Distance-based organization activated (Distances relative to: " .. current_player_name_for_log .. ").")

            local wb_obj_for_distances = AutoBand.get_wb() -- Get the WB object
            if wb_obj_for_distances and wb_obj_for_distances.group then
                local current_player_direct_name = GameData.Player.name -- Assuming this is a wstring for comparison

                local mp_lookup = BuildMapPointLookup()

                wb_obj_for_distances:foreach_player(function(_gid, p_to_update)
                    p_to_update.distance_to_leader = 99999 -- Default to far

                    if p_to_update.name == current_player_direct_name then -- Compare wstring to wstring
                        p_to_update.distance_to_leader = 0
                    else
                        local mpd_p = mp_lookup[p_to_update.name]
                        if mpd_p and type(mpd_p.distance) == "number" then
                            p_to_update.distance_to_leader = mpd_p.distance * DISTANCE_FIX_COEFFICIENT
                        elseif AutoBand.debugon then
                            AB_util.print("[Debug] Player " .. tostring(p_to_update.name) .. " not found on map with valid distance for range sort.")
                        end
                    end
                end)
                -- If get_wb() returned a cached object, we've modified it.
                -- Ensure the cache system knows if it needs to be "dirty" or if this is fine.
                -- For simplicity, we assume get_wb() handles its cache; if it returns a live modifiable object, this is okay.
                -- If AutoBand.cached_wb was returned, it's now updated.
            else
                AB_util.print("[Error] Could not get warband data to calculate distances for distance sort.")
                AB_org.is_distance_sort_active = false -- Disable if we can't process
            end
        else
            -- Ignore "distance" for assistants outside debug mode and explain why.
            AB_org.is_distance_sort_active = false
            AB_util.print("[Info] As an assistant, the 'distance' parameter is ignored. Proceeding with normal warband organization.")
        end
    end

    -- Store original settings
    local original_settings = {
        autokick_enabled = AutoBand.saved.autokick_enabled,
        autokick_toofar_enabled = AutoBand.saved.autokick_toofar_enabled,
        autokick_low_rank_enabled = AutoBand.saved.autokick_low_rank_enabled,
        autokick_we_wh_enabled = AutoBand.saved.autokick_we_wh_enabled,
        notify_buffs_enabled = AutoBand.saved.notify_buffs_enabled
    }

    -- Disable during organization
    AutoBand.saved.autokick_enabled = false
    AutoBand.saved.autokick_toofar_enabled = false
    AutoBand.saved.autokick_low_rank_enabled = false
    AutoBand.saved.autokick_we_wh_enabled = false
    if is_assist_perm or debug_mode then
        AutoBand.saved.notify_buffs_enabled = false
    end

    -- Optional debug snapshot before organizing
    local function summarize_group_counts(wb)
        local sums = {}
        for gid=1, (wb.MAX_GROUPS or AB_const.MAX_WB_GROUPS) do
            local t,h,md,rd = 0,0,0,0
            local grp = wb.group[gid]
            if grp then
                for _, p in ipairs(grp) do
                    if p.role == AB_const.TANK then
                        t = t + 1
                    elseif p.role == AB_const.HEALER then
                        h = h + 1
                    elseif p.role == AB_const.MDPS then
                        md = md + 1
                    elseif p.role == AB_const.RDPS then
                        rd = rd + 1
                    end
                end
            end
            local size = 0; if grp then size = #grp end
            sums[gid] = {t=t,md=md,rd=rd,h=h,tot=size}
        end
        return sums
    end

    local function print_template_snapshot(tpl_obj, tpl_key)
        if not tpl_obj then
            AB_util.print("Template: none")
            return
        end
        -- Count total slots
        local total_slots = AB_util.size_wb(tpl_obj)
        AB_util.print("Template: name=" .. tostring(tpl_key) .. ", slots=" .. tostring(total_slots))
        -- Per-group desired role counts including MD/RD
        for gid = 1, AB_const.MAX_WB_GROUPS do
            local g = tpl_obj[gid]
            if g and #g > 0 then
                local t,h,md,rd = 0,0,0,0
                for _, entry in ipairs(g) do
                    local r = entry.role
                    if r == AB_const.TANK then t = t + 1
                    elseif r == AB_const.HEALER then h = h + 1
                    elseif r == AB_const.MDPS then md = md + 1
                    elseif r == AB_const.RDPS then rd = rd + 1 end
                end
                AB_util.print(string.format("  TPL G%d: T=%d H=%d MD=%d RD=%d (slots=%d)", gid, t, h, md, rd, #g))
            end
        end
    end

    local function print_snapshot(prefix_label, tpl_obj, tpl_key)
        local wb = AutoBand.get_wb()
        local sums = summarize_group_counts(wb)
        local algo = (AutoBand.saved.org_algo_mode == AB_const.MODE_AGGREGATE and "Aggregate" or "Spread")
        local dist = (AB_org.is_distance_sort_active and "ON" or "OFF")
        AB_util.print(prefix_label .. ": algo=" .. algo .. ", focusRole=" .. tostring(AutoBand.saved.org_algo_role) .. ", distance=" .. dist)
        -- Relevant toggles
        AB_util.print("Toggles: altSpec=" .. tostring(AutoBand.saved.alt_speccheck_enabled) .. ", BWSorcAsMDPS=" .. tostring(AutoBand.saved.bw_sorc_as_mdps))
        -- Totals
        local T,H,MD,RD = 0,0,0,0
        wb:foreach_player(function(_, p)
            if p.role == AB_const.TANK then T=T+1
            elseif p.role == AB_const.HEALER then H=H+1
            elseif p.role == AB_const.MDPS then MD=MD+1
            elseif p.role == AB_const.RDPS then RD=RD+1 end
        end)
        AB_util.print(string.format("Totals: Tanks=%d, Heals=%d, mDPS=%d, rDPS=%d, Players=%d", T,H,MD,RD, wb.player_count))
        -- One-line group roles summary
        local summary_line = AB_util.roles_summary_line(wb)
        if summary_line and summary_line ~= "" then AB_util.print("Summary: " .. summary_line) end
        for gid=1,(wb.MAX_GROUPS or AB_const.MAX_WB_GROUPS) do
            local s = sums[gid]
            local dps = (s.md or 0) + (s.rd or 0)
            AB_util.print(string.format("G%d: T=%d H=%d DPS=%d | size=%d", gid, s.t, s.h, dps, s.tot))
        end
        -- If a template is in play, show its per-group desired role counts
        if tpl_obj then
            print_template_snapshot(tpl_obj, tpl_key)
        end
        -- Player roster lines sorted within each group by role order: Tank, Heal, DPS (MDPS+RDPS)
        local grouped = {}
        local maxg = wb.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        for i=1,maxg do grouped[i] = { t={}, h={}, d={} } end
        wb:foreach_player(function(gid, p)
            local role = p.role
            if role == AB_const.TANK then
                table.insert(grouped[gid].t, p)
            elseif role == AB_const.HEALER then
                table.insert(grouped[gid].h, p)
            elseif role == AB_const.MDPS or role == AB_const.RDPS then
                table.insert(grouped[gid].d, p)
            else
                -- Unknown role: append to DPS bucket as a neutral place
                table.insert(grouped[gid].d, p)
            end
        end)
        for gid=1,maxg do
            local function emit(list)
                for _, p in ipairs(list) do
                    local cname = AutoBand.GetCareerName and AutoBand.GetCareerName(p.careerLine or p.career) or tostring(p.careerLine or p.career or "?")
                    AB_util.print(string.format(" - G%d %s (L%d, %s, %s)", gid, tostring(p.name), tonumber(p.level or 0), cname, tostring(p.role)))
                end
            end
            emit(grouped[gid].t)
            emit(grouped[gid].h)
            emit(grouped[gid].d)
        end
    end

    local orig_live_verbose = AutoBand.live_org_verbose
    if debug_print_requested then
        AutoBand.live_org_verbose = true -- enable detailed org logs just for this invocation
        print_snapshot("Org Debug (before)", tpl, tpl_to_use_key)
    end

    AB_org.auto_organize(tpl) -- Call with ONLY the template data

    if debug_print_requested then
        print_snapshot("Org Debug (after)", tpl, tpl_to_use_key)
        AutoBand.live_org_verbose = orig_live_verbose
    end

    -- Restore original flags
    AutoBand.saved.autokick_enabled = original_settings.autokick_enabled
    AutoBand.saved.autokick_toofar_enabled = original_settings.autokick_toofar_enabled
    AutoBand.saved.autokick_low_rank_enabled = original_settings.autokick_low_rank_enabled
    AutoBand.saved.autokick_we_wh_enabled = original_settings.autokick_we_wh_enabled
    if is_assist_perm or debug_mode then
        AutoBand.saved.notify_buffs_enabled = original_settings.notify_buffs_enabled
    end
end

function AutoBand.cmd_autokick_timeout(args)
    if (args[1] == nil) then
        AB_util.print("[error] Missing argument")
        return
    end
    local n = tonumber(args[1])
    if (n < 0) then
        AB_util.print("[error] Invalid timeout value: " .. tostring(n))
        return
    end
    AutoBand.saved.autokick_period = math.floor(n)
    AB_util.print("Auto kick timeout: " .. tostring(AutoBand.saved.autokick_period))
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_mode(args)
    if (args[1] == nil) then
        AB_util.print("[error] Missing argument")
        return
    end
    local n = tonumber(args[1])
    if n == nil or n ~= math.floor(n) or AB_const.ALGO_MODE[n] == nil then
        AB_util.print("[error] Invalid distribution algorithm: " .. tostring(args[1]))
        return
    end
    AutoBand.saved.org_algo_mode = math.floor(n)
    AB_util.print("Distribution algorithm mode: " ..
        tostring(AutoBand.saved.org_algo_mode) ..
        AB_const.ALGO_MODE[AutoBand.saved.org_algo_mode])
    AutoBand.mark_template_settings_modified()
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_set_purpose(args)
    if not AutoBand.is_wb_leader() then
        AB_util.print("[Error] Only the warband leader can set the purpose.")
        return
    end
    local purpose_arg = args[1]
    if not purpose_arg then
        AB_util.print("[Error] Missing purpose type. Usage: /ab purpose <" .. AB_const.GetPurposeNames() .. "|clear>")
        return
    end

    purpose_arg = purpose_arg:lower() -- Convert input to lowercase

    if purpose_arg == "clear" or purpose_arg == "none" then
        if AutoBand.current_purpose then
            AutoBand.current_purpose = nil
            AB_util.print("Warband purpose cleared.")
            AutoBand.mark_template_settings_modified()
            AutoBand.refresh_settings_ui()
        else
            AB_util.print("Warband purpose was not set.")
        end
        return
    end

    local canonical_purpose = AB_const.PURPOSE_ALIASES[purpose_arg]

    if canonical_purpose then
        if AB_const.WARBAND_PURPOSES[canonical_purpose] then
            AutoBand.current_purpose = canonical_purpose -- Store the canonical key
            local purpose_display = AB_const.WARBAND_PURPOSES[canonical_purpose].display or canonical_purpose
            AB_util.print("Warband purpose set to: " .. purpose_display)
            AutoBand.mark_template_settings_modified()
            AutoBand.refresh_settings_ui()
        else
            AB_util.print("[Internal Error] Alias '" .. purpose_arg .. "' maps to invalid purpose '" .. canonical_purpose .. "'.")
            AutoBand.current_purpose = nil -- Ensure purpose is not set incorrectly
        end
    else
        AB_util.print("[Error] Invalid purpose type '" .. purpose_arg .. "'. Valid types: " .. AB_const.GetPurposeNames() .. ", clear")
    end
end

function AutoBand.cmd_list_purposes(_args)
    AB_util.print("Available warband purposes:")
    local purpose_keys = {}
    for key, _ in pairs(AB_const.WARBAND_PURPOSES) do
        table.insert(purpose_keys, key)
    end

    if #purpose_keys == 0 then
        AB_util.print("- None defined.")
        return
    end

    table.sort(purpose_keys)

    for _, key in ipairs(purpose_keys) do
        local purpose_data = AB_const.WARBAND_PURPOSES[key]
        if purpose_data then
            local display_name = purpose_data.display or key -- Fallback to key if display name is missing
            local description = purpose_data.description or "No description available." -- Fallback description
            local output_line = L"- " .. towstring(key) .. L" - " .. towstring(display_name) .. L": " .. towstring(description)
            AB_util.print(output_line)
        end
    end
    AB_util.print(L"Set the current purpose using: /ab purpose <name>")
end

function AutoBand.OnGroupLeave()
    AutoBand.group_leave_core()
    AutoBand.refresh_settings_actions()
end

function AutoBand.group_leave_core()
    if not AutoBand.is_warband_enabled() then
        return
    end
    if type(IsWarBandActive) == "function" then
        local ok_wb, is_active = pcall(IsWarBandActive)
        if ok_wb and is_active == true then
            -- Guard against zone transitions or transient events; keep arrival order.
            AutoBand.inWarband = true
            return
        end
    end
    AutoBand.inWarband = false
    if type(AutoBand.zonevote_close_locally_after_warband_leave) == "function" then
        AutoBand.zonevote_close_locally_after_warband_leave()
    end
    AutoBand.suppressRoleNotifs = false
    AutoBand.suppressCounter = 0
    reset_wb_roster_cache()
    clear_warband_purpose()
end

local function next_social_priority_mode(current_mode)
    local normalized = normalize_social_priority_mode(current_mode, AB_const.SOCIAL_PRIORITY_MODE_OFF)
    local modes = AB_const.SOCIAL_PRIORITY_MODES or {
        AB_const.SOCIAL_PRIORITY_MODE_OFF,
        AB_const.SOCIAL_PRIORITY_MODE_PREFER,
        AB_const.SOCIAL_PRIORITY_MODE_PROTECT,
        AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
    }
    local index = 1
    for i = 1, #modes do
        if modes[i] == normalized then
            index = i
            break
        end
    end
    index = index + 1
    if index > #modes then
        index = 1
    end
    return modes[index]
end

local function parse_social_priority_mode_arg(raw)
    if raw == nil then
        return nil
    end
    local ok_lower, lowered = pcall(string.lower, tostring(raw))
    if not ok_lower or lowered == nil or lowered == "" then
        return nil
    end
    if lowered == "off" or lowered == "false" or lowered == "0" then
        return AB_const.SOCIAL_PRIORITY_MODE_OFF
    elseif lowered == "prefer" or lowered == "on" or lowered == "true" or lowered == "1" then
        return AB_const.SOCIAL_PRIORITY_MODE_PREFER
    elseif lowered == "protect" then
        return AB_const.SOCIAL_PRIORITY_MODE_PROTECT
    elseif lowered == "promote" then
        return AB_const.SOCIAL_PRIORITY_MODE_PROMOTE
    end
    return nil
end

local function parse_toggle_arg(raw)
    if raw == nil then
        return nil
    end
    local ok_lower, lowered = pcall(string.lower, tostring(raw))
    if not ok_lower or lowered == nil or lowered == "" then
        return nil
    end
    if lowered == "on" or lowered == "true" or lowered == "1" then
        return true
    elseif lowered == "off" or lowered == "false" or lowered == "0" then
        return false
    end
    return nil
end

local function handle_social_priority_command(source_key, args)
    local setter = AutoBand.set_guild_priority_mode
    local usage = "Usage: /ab guildpriority [off|prefer|protect|promote]"
    if source_key == "friend" then
        setter = AutoBand.set_friend_priority_mode
        usage = "Usage: /ab friendpriority [off|prefer|protect|promote]"
    end

    local new_mode
    if args and args[1] ~= nil then
        new_mode = parse_social_priority_mode_arg(args[1])
        if new_mode == nil then
            AB_util.print(usage)
            return
        end
    else
        new_mode = next_social_priority_mode(AutoBand.get_saved_social_priority_mode(source_key))
    end

    setter(new_mode)
end

function AutoBand.cmd_flag_guildpriority(args)
    handle_social_priority_command("guild", args)
end

function AutoBand.cmd_flag_friendpriority(args)
    handle_social_priority_command("friend", args)
end

function AutoBand.cmd_toggle_guild_grouping(args)
    local next_state
    if args and args[1] ~= nil then
        next_state = parse_toggle_arg(args[1])
        if next_state == nil then
            AB_util.print("Usage: /ab guildgrouping [on|off]")
            return
        end
    else
        next_state = AutoBand.saved.guild_grouping_enabled ~= true
    end
    AutoBand.set_guild_grouping_enabled(next_state)
end

function AutoBand.cmd_list_template(_args)
    AB_util.print("Default template " .. AutoBand.saved.default_template)
    for tname in pairs(AutoBand.saved.templates) do
        AB_util.print(tname)
    end
end

function AutoBand.cmd_save_template(args)
  if (args[1] == nil) then
    AB_util.print("[Error] Missing argument. Usage: /ab save <name>")
    return
  end
    local template_name = args[1]
    local template_name_lower = template_name:lower() -- Case-insensitive check

    -- Check if the lowercase version of the template name is "distance"
    if template_name_lower == "distance" then
        AB_util.print("[Error] 'distance' is a reserved keyword and cannot be used for template names.")
        return
    end

    -- Also check against other special template names already handled by the GUI's is_special_template
    -- These are <Warband> and <Automatic>
    if template_name == AB_const.CURRENT_WB or template_name == AB_const.EMPTY_TEMPLATE then
         AB_util.print("[Error] '" .. template_name .. "' is a reserved name and cannot be used for templates.")
         return
    end

  AutoBand.saved.templates[template_name] = AutoBand.build_template_snapshot(AB_template.from_wb(AutoBand.get_wb()))
  AB_util.print("Template '" .. template_name .. "' saved.")
end

function AutoBand.cmd_apply_template(args)
    if not AutoBand.require_warband_features_enabled("applying a warband template") then
        return
    end

    if (args[1] == nil) then
        AB_util.print("[error] Missing argument")
        return
    end
    if (AutoBand.saved.templates[args[1]] == nil) then
        AB_util.print("[error] Template " .. args[1] .. " does not exist")
        return
    end
    if type(AutoBand.remember_active_template_selection) == "function" then
        AutoBand.remember_active_template_selection(args[1])
    else
        AutoBand.template_active_key = args[1]
    end
    AutoBand.apply_template_settings(AutoBand.saved.templates[args[1]], { silent = true, template_name = args[1] })
    AB_org.auto_organize(AutoBand.template_get_layout(AutoBand.saved.templates[args[1]]))
    AB_util.print("Template " .. args[1] .. " loaded")
end

function AutoBand.cmd_default_template(args)
    if (#args > 0) then
        if (AutoBand.saved.templates[args[1]] == nil) then
            AB_util.print("[error] Template " .. args[1] .. " does not exist")
            return
        end
        AutoBand.saved.default_template = args[1]
    else
        AutoBand.saved.default_template = AB_const.EMPTY_TEMPLATE
    end
    AB_util.print("Default template set: " .. AutoBand.saved.default_template)
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_toggle_gui(_args)
    if (AutoBandWindow.showing()) then
        AutoBandWindow.Hide()
    else
        AutoBandWindow.Show()
    end
end

function AutoBand.cmd_toggle_icon(_args)
    AutoBandWindow.toggle_mapicon()
    AB_util.print("Show map-icon: " .. tostring(AutoBand.saved.displayicon))
    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_toggle_wbleader_tell_alert(args)
    args = args or {}
    local requested = parse_warband_enabled_arg(args[1])
    if args[1] ~= nil and requested == nil then
        AB_util.print("Usage: /ab wbleadtells [on|off]")
        return
    end
    if requested == nil then
        requested = not AutoBand.is_wbleader_tell_alert_enabled()
    end
    AutoBand.set_wbleader_tell_alert_enabled(requested)
end

local function AutoBand_L_CanUseContextMenu()
    local menu = EA_Window_ContextMenu
    return (type(menu) == "table")
        and (type(menu.CreateContextMenu) == "function")
        and (type(menu.AddMenuDivider) == "function")
        and (type(menu.AddMenuItem) == "function")
        and (type(menu.Finalize) == "function")
end

local function AutoBand_L_GetContextMenuAnchorWindow()
    local windowName = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if not windowName or windowName == "" then
        windowName = SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name
    end
    if not windowName or windowName == "" then
        windowName = "AutoBandMapIconButton"
    end
    return windowName
end

local function AutoBand_L_GetMenuId(preferred, fallback)
    local menu = EA_Window_ContextMenu
    if type(menu) ~= "table" then
        return fallback
    end
    local id = menu[preferred]
    if id == nil then
        return fallback
    end
    return id
end

local function AutoBand_L_FinalizeContextMenu(menuId)
    local menu = EA_Window_ContextMenu
    if type(menu) ~= "table" or type(menu.Finalize) ~= "function" then
        return
    end
    local ok = pcall(menu.Finalize, menuId)
    if not ok then
        menu.Finalize()
    end
end

local function AutoBand_L_AddContextMenuItem(label_w, callback, disabled, menuId)
    local menu = EA_Window_ContextMenu
    if type(menu) ~= "table" or type(menu.AddMenuItem) ~= "function" then
        return
    end
    menu.AddMenuItem(label_w, callback, disabled == true, true, menuId)
end

local function AutoBand_L_AddContextMenuCascade(label_w, callback, menuId)
    local menu = EA_Window_ContextMenu
    if type(menu) ~= "table" then
        return false
    end
    if type(menu.AddCascadingMenuItem) == "function" then
        menu.AddCascadingMenuItem(label_w, callback, false, menuId)
        return true
    end
    return false
end

local function AutoBand_L_OpenMainWindow()
    if AutoBandWindow and type(AutoBandWindow.Show) == "function" then
        AutoBandWindow.Show()
    elseif type(WindowSetShowing) == "function" then
        WindowSetShowing("AutoBandWindow", true)
    end
end

local function AutoBand_L_GetSortedTemplateNames()
    local names = {}
    if AutoBand.saved and type(AutoBand.saved.templates) == "table" then
        for name in pairs(AutoBand.saved.templates) do
            table.insert(names, tostring(name))
        end
    end
    table.sort(names, function(a, b)
        return string.lower(tostring(a)) < string.lower(tostring(b))
    end)
    return names
end

local function AutoBand_L_ShowTemplateOrganizeSubmenu(template_names, use_distance)
    if type(template_names) ~= "table" or #template_names == 0 then
        return false
    end
    if not AutoBand_L_CanUseContextMenu() then
        return false
    end

    local menu = EA_Window_ContextMenu
    local menuId = AutoBand_L_GetMenuId("CONTEXT_MENU_2", 2)
    local title = use_distance and L"AutoBand Organize (distance template)" or L"AutoBand Organize (template)"

    menu.CreateContextMenu("AutoBand Organize", menuId, title)
    menu.AddMenuDivider(menuId)

    for i = 1, #template_names do
        local template_name = template_names[i]
        local label
        if use_distance then
            label = "/ab org " .. template_name .. " distance"
        else
            label = "/ab org " .. template_name
        end
        AutoBand_L_AddContextMenuItem(towstring(label), function()
            if use_distance then
                AutoBand.cmd_organize({ template_name, "distance" })
            else
                AutoBand.cmd_organize({ template_name })
            end
        end, false, menuId)
    end

    AutoBand_L_FinalizeContextMenu(menuId)
    return true
end

function AutoBand.ShowIconOrganizeMenu(options)
    if not AutoBand_L_CanUseContextMenu() then
        return false
    end

    local menu = EA_Window_ContextMenu
    local menuId = AutoBand_L_GetMenuId("CONTEXT_MENU_1", 1)
    local anchor = AutoBand_L_GetContextMenuAnchorWindow()
    local template_names = AutoBand_L_GetSortedTemplateNames()
    local include_template_variants = AutoBand.saved and AutoBand.saved.right_click_organize_include_templates == true
    local warband_enabled = AutoBand.is_warband_enabled()
    local include_open_window = true
    if type(options) == "table" and options.include_open_window == false then
        include_open_window = false
    end

    local can_organize = warband_enabled and (AutoBand.is_wb_leader() or AutoBand.is_assistant() or AutoBand.debugon)
    local can_distance = warband_enabled and (AutoBand.is_wb_leader() or AutoBand.debugon)

    menu.CreateContextMenu(anchor, menuId, L"AutoBand")
    menu.AddMenuDivider(menuId)

    local added_organize_items = false

    if warband_enabled then
        added_organize_items = true

        AutoBand_L_AddContextMenuItem(L"/ab org", function()
            AutoBand.cmd_organize({})
        end, (not can_organize), menuId)

        AutoBand_L_AddContextMenuItem(L"/ab org distance", function()
            AutoBand.cmd_organize({ "distance" })
        end, ((not can_organize) or (not can_distance)), menuId)

        if include_template_variants and #template_names == 1 then
            local only_template = template_names[1]
            menu.AddMenuDivider(menuId)

            AutoBand_L_AddContextMenuItem(towstring("/ab org " .. only_template), function()
                AutoBand.cmd_organize({ only_template })
            end, (not can_organize), menuId)

            AutoBand_L_AddContextMenuItem(towstring("/ab org " .. only_template .. " distance"), function()
                AutoBand.cmd_organize({ only_template, "distance" })
            end, ((not can_organize) or (not can_distance)), menuId)
        elseif include_template_variants and #template_names > 1 then
            menu.AddMenuDivider(menuId)

            local template_label = L"/ab org <template>"
            local template_cascade_shown = false
            if can_organize then
                template_cascade_shown = AutoBand_L_AddContextMenuCascade(template_label, function()
                    AutoBand_L_ShowTemplateOrganizeSubmenu(template_names, false)
                end, menuId)
            end
            if not template_cascade_shown then
                AutoBand_L_AddContextMenuItem(template_label, function()
                    AutoBand_L_ShowTemplateOrganizeSubmenu(template_names, false)
                end, (not can_organize), menuId)
            end

            local template_dist_label = L"/ab org <template> distance"
            local template_dist_cascade_shown = false
            if can_organize and can_distance then
                template_dist_cascade_shown = AutoBand_L_AddContextMenuCascade(template_dist_label, function()
                    AutoBand_L_ShowTemplateOrganizeSubmenu(template_names, true)
                end, menuId)
            end
            if not template_dist_cascade_shown then
                AutoBand_L_AddContextMenuItem(template_dist_label, function()
                    AutoBand_L_ShowTemplateOrganizeSubmenu(template_names, true)
                end, ((not can_organize) or (not can_distance)), menuId)
            end
        end
    end

    if added_organize_items then
        menu.AddMenuDivider(menuId)
    end
    if warband_enabled then
        AutoBand_L_AddContextMenuItem(L"Disable WB features", function()
            AutoBand.set_warband_enabled(false)
        end, false, menuId)
    else
        AutoBand_L_AddContextMenuItem(L"Enable WB features", function()
            AutoBand.set_warband_enabled(true)
        end, false, menuId)
    end
    if include_open_window then
        AutoBand_L_AddContextMenuItem(L"Open AutoBand Window", function()
            AutoBand_L_OpenMainWindow()
        end, false, menuId)
    end

    AutoBand_L_FinalizeContextMenu(menuId)
    return true
end

function AutoBand.HandleIconRightClick(options)
    PlaySound(GameData.Sound.BUTTON_CLICK)
    if not AutoBand.ShowIconOrganizeMenu(options) then
        if not AutoBand.is_warband_enabled() then
            AB_util.print("Icon menu unavailable. Use /ab enable to re-enable warband features.")
        else
            AB_util.print("Icon organize menu unavailable. Running default organize.")
            AutoBand.cmd_organize({})
        end
    end
end

--[[
    New Tooltip Functions
]]
local function AutoBand_L_GetTooltipFontLinespacing()
    if type(WindowUtils) == "table" and tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING) ~= nil then
        return tonumber(WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
    end
    return 20
end

local function AutoBand_L_ApplySmallTooltipFont()
    if type(LabelSetFont) ~= "function" then
        return
    end
    local linespacing = AutoBand_L_GetTooltipFontLinespacing()
    LabelSetFont("DefaultTooltipRow1Col1Text", "font_clear_small", linespacing)
    LabelSetFont("DefaultTooltipRow1Col2Text", "font_clear_small", linespacing)
    LabelSetFont("DefaultTooltipRow1Col3Text", "font_clear_small", linespacing)
end

local function AutoBand_L_RestoreTooltipFont()
    if type(LabelSetFont) ~= "function" then
        return
    end
    local linespacing = AutoBand_L_GetTooltipFontLinespacing()
    LabelSetFont("DefaultTooltipRow1Col1Text", "font_default_text", linespacing)
    LabelSetFont("DefaultTooltipRow1Col2Text", "font_default_text", linespacing)
    LabelSetFont("DefaultTooltipRow1Col3Text", "font_default_text", linespacing)
end

function AutoBand.OnIconMouseOver()
    -- Define anchor point for the tooltip relative to the icon
    local anchor = { Point="topleft", RelativeTo=SystemData.ActiveWindow.name, RelativePoint="bottomleft", XOffset=5, YOffset=-10 }
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)

    local warband_enabled = AutoBand.is_warband_enabled()
    local tooltipText
    if not warband_enabled then
        tooltipText = L"AutoBand - WB OFF\n" ..
                      L"Warband features disabled\n" ..
                      L"LClick: Open AutoBand Window\n" ..
                      L"RClick: AutoBand Menu"
    else
        tooltipText = L"AutoBand\n" ..
                      L"LClick: Open AutoBand Window\n" ..
                      L"RClick: AutoBand Menu"
    end

    if warband_enabled then
        tooltipText = tooltipText .. L"\nOrganize shortcuts: enabled"
    end

    -- Set, finalize, and anchor the tooltip
    AutoBand_L_ApplySmallTooltipFont()
    Tooltips.SetTooltipText(1, 1, tooltipText)
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor)
end

function AutoBand.OnIconMouseLeave()
    AutoBand_L_RestoreTooltipFont()
    Tooltips.DestroyTooltip(SystemData.ActiveWindow.name)
end

function AutoBand.cmd_list_dump(_args)
    if (AutoBand.saved.dumped_wb ~= nil) then
        AB_util.print("[AutoBand] default dump " .. AutoBand.saved.default_dump)
    end
    for tname in pairs(AutoBand.saved.dumps) do
        AB_util.print(tname)
    end
end

function AutoBand.cmd_load_dump(args)
    if (#args > 0) then
        if (AutoBand.saved.dumps[args[1]] == nil) then
            AB_util.print("[error] Dump " .. args[1] .. " does not exist")
            return
        end
        AutoBand.saved.default_dump = args[1]
        AutoBand.saved.dumped_wb = AutoBand.saved.dumps[AutoBand.saved.default_dump]
    end
    AB_util.print("[AutoBand] Default dump set: " .. AutoBand.saved.default_dump)
end

function AutoBand.cmd_dump_from_template(args)
    if (AutoBand.debugon) then
        if (#args > 1) then
            local template_name = args[1]
            local dump_name = args[2]
            if (AutoBand.saved.templates[template_name] == nil) then
                AB_util.print("[error] Template " .. template_name .. " does not exist")
                return
            end
            AutoBand.saved.dumped_wb = AutoBand.get_fakewb(AutoBand.saved.templates[template_name])
            AutoBand.saved.dumps[dump_name] = AutoBand.saved.dumped_wb
            AutoBand.saved.default_dump = dump_name
        end
    end
end

function AutoBand.auto_kick_toofar()
    if (not AutoBand.saved.autokick_toofar_enabled or not AutoBand.is_wb_leader() or AutoBand.debugon) then
        return
    end
    local wb_obj = AutoBand.get_wb()
    local prefix_raw_wspace = AutoBand.GetFormattedPrefixRaw(true)
    local current_toofar_distance = AutoBand.get_current_toofar_distance() -- Get dynamic distance
    local guild_member_set, friend_member_set = get_toofar_social_priority_membership_sets(AutoBand.saved)
    local mp_lookup = BuildMapPointLookup()
    local warn_names = {}

    local function clear_toofar_tracking(player_name)
        toofar[player_name] = nil
        toofar_not_changed[player_name] = nil
        warned[player_name] = nil
    end

    wb_obj:foreach_player(
        function(_gid, player)
            if player_is_exempt_from_toofar_kick(player.name, guild_member_set, friend_member_set, AutoBand.saved) then
                clear_toofar_tracking(player.name)
                return
            end

            local mpd = mp_lookup[player.name]
            if mpd and mpd.distance then
                player.distance = mpd.distance * DISTANCE_FIX_COEFFICIENT
                if player.distance > current_toofar_distance then -- Use dynamic distance
                    if toofar[player.name] then
                        toofar[player.name] = toofar[player.name] + 1
                    else
                        toofar[player.name] = 1
                    end
                    if (toofar[player.name] == 6) then -- Initial warning
                        if not warned[player.name] then
                            if not AutoBand.is_player_ignored(tostring(player.name)) then
                                warn_names[#warn_names + 1] = tostring(player.name)
                            end
                            warned[player.name] = true
                        end
                    end
                    if (toofar[player.name] > (AutoBand.saved.autokick_period * 12)) then -- Kick condition
                        AutoBand.enqueue_kick(player.name,
                            "you were too far (>" .. current_toofar_distance .. " units) from warband leader for a long time", "autokick")
                    end
                else
                    toofar[player.name] = nil -- Player is back in range
                end
            end
        end
    )

    -- Warnings go to warband chat, one line per pass naming everyone warned: since the
    -- 2026-10-29 RoR patch the server limits starting tells with many different
    -- players. Kick reasons stay tells, because a kicked player no longer reads /wb.
    if #warn_names > 0 then
        local warn_lines = AB_util.build_name_list_lines("/wb " .. prefix_raw_wspace ..
            "You are too far from leader (current max: " .. current_toofar_distance .. " units), you will be removed in " ..
            (AutoBand.saved.autokick_period * 60 - 30) ..
            " sec! Follow the leader PLEASE: ", warn_names, AB_const.CHAT_LINE_MAX_LEN)
        for i = 1, #warn_lines do
            AutoBand.enqueue_command(warn_lines[i], nil, nil, "autokick")
        end
    end

    for i_key, v_val in pairs(toofar) do
        local old_val = toofar_old[i_key]
        if old_val ~= nil then
            if v_val == old_val then
                if toofar_not_changed[i_key] then
                    toofar_not_changed[i_key] = toofar_not_changed[i_key] + 1
                else
                    toofar_not_changed[i_key] = 1
                end
                if toofar_not_changed[i_key] > 60 then -- roughly 5 minutes of no change (60 * 5s heartbeat)
                    toofar[i_key] = nil
                    toofar_not_changed[i_key] = nil
                end
            else
                toofar_not_changed[i_key] = nil -- Value changed, reset counter
            end
        else
            toofar_not_changed[i_key] = nil -- New entry in toofar, clear any stale not_changed
        end
    end

    toofar_old = {}
    for key, value in pairs(toofar) do
        toofar_old[key] = value
    end
end

function AutoBand.GetLeaderEffectiveRoleCategory(ignore_custom_role_for_this_check)
    ignore_custom_role_for_this_check = ignore_custom_role_for_this_check or false
    local leader_name_lower
    local leader_career_line
    local leader_archtype = 0 -- Default to main spec (path 0)

    if GameData and GameData.Player and GameData.Player.name and GameData.Player.career and GameData.Player.career.line then
        leader_name_lower = tostring(AutoBand.FixString(GameData.Player.name)):lower()
        leader_career_line = GameData.Player.career.line
        if GameData.Player.archtype then -- archtype is 0, 1, or 2
            leader_archtype = GameData.Player.archtype
        end
    else
        if AutoBand.roleDetermined == true and AutoBand.role then
            return AutoBand.role
        end
        AB_util.print("[Warning] GetLeaderEffectiveRoleCategory: Could not get complete player data.")
        return AB_const.MDPS -- Fallback to a generic DPS to be safe, or handle error
    end

    AutoBand.DeterminePlayerBaseRole()

    -- 1. Custom Role (Highest priority, unless explicitly ignoring for this check)
    if not ignore_custom_role_for_this_check then
        local custom_role = AutoBand.saved.custom_roles and AutoBand.saved.custom_roles[leader_name_lower]
        if custom_role and (custom_role == AB_const.TANK or custom_role == AB_const.HEALER or custom_role == AB_const.MDPS or custom_role == AB_const.RDPS) then
            return custom_role
        end
    end

    -- 2. Alt spec for the local player; keep this aligned with AB_wb:getArcheType.
    local effective_career_for_role_calc = leader_career_line
    if AutoBand.saved.alt_speccheck_enabled and leader_archtype > 0 then
        if leader_career_line == GameData.CareerLine.ZEALOT then effective_career_for_role_calc = GameData.CareerLine.MAGUS
        elseif leader_career_line == GameData.CareerLine.WARRIOR_PRIEST then effective_career_for_role_calc = GameData.CareerLine.SLAYER
        elseif leader_career_line == GameData.CareerLine.RUNE_PRIEST then effective_career_for_role_calc = GameData.CareerLine.ENGINEER
        elseif leader_career_line == GameData.CareerLine.ARCHMAGE then effective_career_for_role_calc = GameData.CareerLine.ENGINEER
        elseif leader_career_line == GameData.CareerLine.SHAMAN then effective_career_for_role_calc = GameData.CareerLine.MAGUS
        elseif leader_career_line == GameData.CareerLine.DISCIPLE then effective_career_for_role_calc = GameData.CareerLine.CHOPPA
        elseif leader_career_line == GameData.CareerLine.SQUIG_HERDER and leader_archtype > 0 then effective_career_for_role_calc = GameData.CareerLine.CHOPPA
        elseif leader_career_line == GameData.CareerLine.SHADOW_WARRIOR and leader_archtype > 0 then effective_career_for_role_calc = GameData.CareerLine.SLAYER
        end
    end
    local current_role_category = AutoBand.role
    if effective_career_for_role_calc ~= leader_career_line or current_role_category == nil then
        current_role_category = AB_util.career_category(effective_career_for_role_calc)
    end

    -- 3. BW/Sorc as MDPS Toggle (Applied if not overridden by custom role and if currently RDPS)
    if AutoBand.saved.bw_sorc_as_mdps then
        if (leader_career_line == GameData.CareerLine.BRIGHT_WIZARD or leader_career_line == GameData.CareerLine.SORCERER) then
            if current_role_category == AB_const.RDPS then -- Only switch if they are effectively RDPS before this toggle
                current_role_category = AB_const.MDPS
            end
        end
    end

    return current_role_category
end

function AutoBand.cmd_toggle_dps_weighting(args)
    local current_dps_weighting_state = AutoBand.saved.dps_weighting_enabled
    local new_dps_weighting_state

    local state_arg = args and args[1] and args[1]:lower()
    if state_arg == "on" then new_dps_weighting_state = true
    elseif state_arg == "off" then new_dps_weighting_state = false
    else new_dps_weighting_state = not current_dps_weighting_state end

    if new_dps_weighting_state == true and current_dps_weighting_state == false then -- Only check when turning ON
        local leader_effective_role = AutoBand.GetLeaderEffectiveRoleCategory()
        if leader_effective_role then
            if (leader_effective_role == AB_const.MDPS) then
                if AutoBand.saved.max_mdps == 0 then
                    AB_util.print("[Error] Cannot enable DPS weighting. Your effective role (MDPS) has a max limit of 0.")
                    AB_util.print("Use /ab setdps or /ab setroles to adjust mDPS/rDPS limits first.")
                    return
                end
            elseif (leader_effective_role == AB_const.RDPS) then
                 if AutoBand.saved.max_rdps == 0 then
                    AB_util.print("[Error] Cannot enable DPS weighting. Your effective role (RDPS) has a max limit of 0.")
                    AB_util.print("Use /ab setdps or /ab setroles to adjust mDPS/rDPS limits first.")
                    return
                end
            end
        end
    end

    AutoBand.saved.dps_weighting_enabled = new_dps_weighting_state

    local composition_str = AutoBand.saved.max_tanks .. "-" .. AutoBand.saved.max_healers .. "-" .. AutoBand.saved.max_dps
    if AutoBand.saved.dps_weighting_enabled then
        AB_util.print("DPS weighting for " .. composition_str .." enabled. Max MDPS: " .. AutoBand.saved.max_mdps .. ", Max RDPS: " .. AutoBand.saved.max_rdps)
        if not AutoBand.saved.autokick_enabled then
            AB_util.print("[Warning] DPS weighting only enforced when 'Auto enforcing " .. composition_str .." WB' (/ab ak) is also enabled.")
        end
    else
        AB_util.print("DPS weighting for " .. composition_str .." disabled.")
    end
    AutoBand.mark_template_settings_modified()

    AutoBand.refresh_settings_ui()
end

function AutoBand.cmd_set_dps_weights(args, called_from_gui)
    called_from_gui = called_from_gui or false -- Default to false if not provided

    local mdps_count_input = tonumber(args[1])
    local rdps_count_input = tonumber(args[2])

    if not mdps_count_input or not rdps_count_input then
        AB_util.print("[Error] Missing MDPS or RDPS count. Usage: /ab setdps <mdps_count> <rdps_count>")
        return
    end

    local new_max_mdps = math.floor(mdps_count_input)
    local new_max_rdps = math.floor(rdps_count_input)

    if new_max_mdps < 0 or new_max_rdps < 0 then
        AB_util.print("[Error] MDPS and RDPS counts cannot be negative.")
        return
    end

    if new_max_mdps + new_max_rdps ~= AutoBand.saved.max_dps then
        AB_util.print("[Error] Counts must sum to the current max DPS setting (" .. AutoBand.saved.max_dps .. "). Provided: " .. new_max_mdps .. " MDPS + " .. new_max_rdps .. " RDPS = " .. (new_max_mdps + new_max_rdps) .. ".")
        return
    end

    local leader_effective_role = AutoBand.GetLeaderEffectiveRoleCategory()
    if leader_effective_role then
        if (leader_effective_role == AB_const.MDPS) and new_max_mdps == 0 then
            AB_util.print("[Error] Cannot set max mDPS to 0. Your current effective role is mDPS.")
            return
        elseif (leader_effective_role == AB_const.RDPS) and new_max_rdps == 0 then
            AB_util.print("[Error] Cannot set max rDPS to 0. Your current effective role is rDPS.")
            return
        end
    end

    -- If checks pass:
    AutoBand.saved.max_mdps = new_max_mdps
    AutoBand.saved.max_rdps = new_max_rdps

    if not called_from_gui then
        -- Only print success message and related warnings if NOT called from GUI
        AB_util.print("DPS weights set. Max MDPS: " .. AutoBand.saved.max_mdps .. ", Max RDPS: " .. AutoBand.saved.max_rdps)

        if not AutoBand.saved.dps_weighting_enabled then
            AB_util.print("[Warning] DPS weighting is currently disabled (/ab dw on). Changes will apply if/when enabled.")
        end
        if not AutoBand.saved.autokick_enabled then
            AB_util.print("[Warning] DPS weighting only enforced when 'Auto enforcing " .. AutoBand.saved.max_tanks .. "-" .. AutoBand.saved.max_healers .. "-" .. AutoBand.saved.max_dps .." WB' (/ab ak) is also enabled.")
        end
    end

    -- Refresh GUI if it's open and the relevant tab is selected
    AutoBand.refresh_settings_ui()
    AutoBand.mark_template_settings_modified()
end

function AutoBand.cmd_toggle_bw_sorc_mdps(_args)
    local current_bw_sorc_setting = AutoBand.saved.bw_sorc_as_mdps
    local new_bw_sorc_setting = not current_bw_sorc_setting

    if GameData and GameData.Player and GameData.Player.career and GameData.Player.career.line then
        local leader_career_line = GameData.Player.career.line
        local is_leader_bw_or_sorc = (leader_career_line == GameData.CareerLine.BRIGHT_WIZARD or
                                      leader_career_line == GameData.CareerLine.SORCERER)

        if is_leader_bw_or_sorc and AutoBand.saved.dps_weighting_enabled then
            -- Determine what the leader's effective sub-role WILL BE after this toggle
            local future_leader_effective_role_is_mdps
            if new_bw_sorc_setting then -- If BW/Sorc will be treated as MDPS
                future_leader_effective_role_is_mdps = true
            else -- BW/Sorc will revert to default (RDPS)
                future_leader_effective_role_is_mdps = false
            end

            if future_leader_effective_role_is_mdps and AutoBand.saved.max_mdps == 0 then
                AB_util.print("[Error] Cannot treat you as MDPS because max MDPS is currently 0.")
                AB_util.print("Use /ab setdps or /ab setroles to allow at least one MDPS slot.")
                return
            elseif not future_leader_effective_role_is_mdps and AutoBand.saved.max_rdps == 0 then
                AB_util.print("[Error] Cannot revert to treating you as RDPS because max RDPS is currently 0.")
                AB_util.print("Use /ab setdps or /ab setroles to allow at least one RDPS slot.")
                return
            end
        end
    end

    AutoBand.saved.bw_sorc_as_mdps = new_bw_sorc_setting

    local bw_sorc_label = AB_const.GetBWSorcAsMDPSLabel()
    AB_util.print(bw_sorc_label .. ": " .. tostring(AutoBand.saved.bw_sorc_as_mdps))
    AutoBand.mark_template_settings_modified()

    AutoBand.refresh_settings_ui()
    AutoBand.need_role_update = true
end

function AutoBand.cmd_toggle_restrict_race(_args)
    AutoBand.saved.restrict_same_race = not AutoBand.saved.restrict_same_race
    local restrict_race_label = AB_const.GetRestrictRaceLabel()
    AB_util.print(restrict_race_label .. ": " .. tostring(AutoBand.saved.restrict_same_race))
    AutoBand.mark_template_settings_modified()
    if AutoBand.saved.restrict_same_race and not AutoBand.raceDetermined then
        AB_util.print("[Warning] Could not determine your race. Restriction might not work correctly.")
    end
     -- Refresh GUI if open
    AutoBand.refresh_settings_ui()
end

local function pick_article_for_title(title)
    if not title or title == "" then
        return "a"
    end
    local first = string.sub(tostring(title), 1, 1)
    first = string.lower(first)
    if first == "a" or first == "e" or first == "i" or first == "o" or first == "u" then
        return "an"
    end
    return "a"
end

local function ensure_backfill_notice_state()
    if type(AutoBand.backfill_notice_state) ~= "table" then
        AutoBand.backfill_notice_state = {}
    end
    return AutoBand.backfill_notice_state
end

local function enqueue_backfill_notice(player_name, msg_text)
    if not player_name or not msg_text or msg_text == "" then
        return
    end
    if AutoBand.is_player_ignored and AutoBand.is_player_ignored(tostring(player_name)) then
        return
    end
    local prefix_raw_wspace = AutoBand.GetFormattedPrefixRaw(true)
    AutoBand.enqueue_command("/tell " .. tostring(player_name) .. " " .. prefix_raw_wspace .. msg_text, nil, nil, "autokick")
end

local function build_promote_source_text(promote_guild, promote_friend)
    if promote_guild and promote_friend then
        return "guild member or friend"
    elseif promote_guild then
        return "guild member"
    elseif promote_friend then
        return "friend"
    end
    return "priority member"
end

local function build_risk_warning_message(risk)
    if risk and risk.mode == "promote" then
        local role_label = tostring((risk and risk.role_label) or "role")
        local source_text = build_promote_source_text(risk and risk.promote_guild == true, risk and risk.promote_friend == true)
        return "Heads up: your current " .. role_label .. " spot may need to open if a matching " .. source_text .. " joins."
    end
    if type(AutoBand.realmrank_build_backfill_warning_message) == "function" then
        return AutoBand.realmrank_build_backfill_warning_message(risk)
    end
    return "Heads up: you may be removed later if matching players join."
end

local function build_risk_safe_message(prev_state, current_state)
    if prev_state and prev_state.mode == "promote" then
        local role_label = nil
        if prev_state and prev_state.role_label then
            role_label = tostring(prev_state.role_label)
        end
        if role_label and role_label ~= "" then
            return "Update: your current " .. role_label .. " spot is safe for now unless things change."
        end
        return "Update: your spot is safe for now unless things change."
    end
    if type(AutoBand.realmrank_build_backfill_safe_message) == "function" then
        return AutoBand.realmrank_build_backfill_safe_message(prev_state, current_state)
    end
    return "Update: your spot is safe for now unless things change."
end

local function is_backfill_heads_up_suppressed(notice_state)
    if not (AutoBand.saved and AutoBand.saved.backfill_no_headsups_enabled == true) then
        return false
    end
    return not (notice_state and notice_state.mode == "promote")
end

local function sync_backfill_notice_state(live_members_by_key, at_risk_by_key, pending_kick_by_key, notices_enabled, live_member_state_by_key)
    local state = ensure_backfill_notice_state()

    for key, _ in pairs(state) do
        if not (live_members_by_key and live_members_by_key[key]) then
            state[key] = nil
        end
    end

    if not notices_enabled then
        for key, _ in pairs(state) do
            state[key] = nil
        end
        return
    end

    for key, player_name in pairs(live_members_by_key or {}) do
        if pending_kick_by_key and pending_kick_by_key[key] then
            state[key] = nil
        else
            local risk = at_risk_by_key and at_risk_by_key[key]
            local prev = state[key]
            if risk then
                if is_backfill_heads_up_suppressed(risk) then
                    state[key] = nil
                else
                    local warned = prev and prev.warned == true
                    if (risk.warn ~= false) and not warned then
                        local warning_message = build_risk_warning_message(risk)
                        enqueue_backfill_notice(player_name, warning_message)
                        warned = true
                    end
                    state[key] = {
                        at_risk = true,
                        mode = risk.mode,
                        role_label = risk.role_label,
                        warned = warned == true,
                        promote_guild = risk.promote_guild == true,
                        promote_friend = risk.promote_friend == true,
                        below_rank = risk.below_rank == true,
                        queued_below_rank = risk.queued_below_rank == true,
                        required_rank = risk.required_rank,
                        required_metric = risk.required_metric,
                        rank_unknown = risk.rank_unknown == true
                    }
                end
            else
                if prev and prev.at_risk == true and prev.warned == true and not is_backfill_heads_up_suppressed(prev) then
                    local current_state = live_member_state_by_key and live_member_state_by_key[key]
                    local safe_message = build_risk_safe_message(prev, current_state)
                    enqueue_backfill_notice(player_name, safe_message)
                end
                state[key] = nil
            end
        end
    end
end

local function backfill_route_mode_info()
    local saved = AutoBand.saved or {}
    local backfill_enabled = saved.backfill_enabled == true
    local ak_enabled = saved.autokick_enabled == true
    local ak_low_enabled = saved.autokick_low_rank_enabled == true

    if not backfill_enabled then
        return "disabled", false, false, false
    end
    if ak_enabled and ak_low_enabled then
        return "role+rank", true, true, true
    end
    if ak_enabled then
        return "role", true, true, false
    end
    if ak_low_enabled then
        return "rank-only", true, false, true
    end
    return "idle", false, false, false
end

-- Career rank of the actual WB leader, without a new roster read: the player's own CR
-- when they lead (authoritative, and every marker path is leader-only), else the
-- leader flagged in the supplied WB context; nil when unknown.
function AutoBand.get_wb_leader_career_rank(wb)
    local player = GameData and GameData.Player
    if type(player) == "table" and player.isGroupLeader == true and tonumber(player.level) then
        return tonumber(player.level)
    end
    if type(wb) == "table" and type(wb.group) == "table" then
        for _, grp in ipairs(wb.group) do
            for _, member in ipairs(grp) do
                if type(member) == "table" and member.isGroupLeader == true then
                    return tonumber(member.level)
                end
            end
        end
    end
    return nil
end

-- Whether adverts and party notes say BackFill (display only; enforcement uses
-- backfill_route_mode_info). Needs backfill on; shown with Auto enforce; otherwise
-- needs Rank requirement, and is hidden when all three rank requirements are the
-- fixed T2 floor of 16 while the actual WB leader is CR 16+, since that bar admits
-- everyone who can join.
function AutoBand.should_show_backfill_marker(wb)
    local T2_FLOOR = 16
    local saved = AutoBand.saved or {}
    if saved.backfill_enabled ~= true then
        return false
    end
    if saved.autokick_enabled == true then
        return true
    end
    if saved.autokick_low_rank_enabled ~= true then
        return false
    end
    local tank_rank, healer_rank, dps_rank = AutoBand.get_saved_rank_requirements(saved)
    if tank_rank == T2_FLOOR and healer_rank == T2_FLOOR and dps_rank == T2_FLOOR then
        local leader_rank = AutoBand.get_wb_leader_career_rank(wb)
        if leader_rank ~= nil and leader_rank >= T2_FLOOR then
            return false
        end
    end
    return true
end

function AutoBand.build_search_backfill_suffix(_saved, wb)
    if AutoBand.should_show_backfill_marker(wb) then
        return " - BackFill active"
    end
    return ""
end

local function sort_backfill_candidates(candidates, prioritize_below_rank)
    table.sort(candidates, function(a, b)
        if prioritize_below_rank then
            local a_below = a.below_rank == true
            local b_below = b.below_rank == true
            if a_below ~= b_below then
                return a_below
            end
        end

        local a_idx = a.arrival_idx or -1
        local b_idx = b.arrival_idx or -1
        if a_idx ~= b_idx then
            return a_idx > b_idx
        end

        return a.name < b.name
    end)
end

local function compute_role_backfill_need_count(current_count, qualified_count, max_allowed, rank_mode_active)
    local current = tonumber(current_count) or 0
    local qualified = tonumber(qualified_count)
    local max_role = tonumber(max_allowed) or 0

    if qualified == nil then
        qualified = current
    end

    local needed = max_role - current
    if needed < 0 then
        needed = 0
    end

    if rank_mode_active and current >= max_role and qualified < max_role then
        needed = 1
    end

    return needed
end

local function state_has_blocked_backfill_slot(state, rank_mode_active)
    if not rank_mode_active or not state then
        return false
    end

    local current = tonumber(state.current_count) or 0
    local qualified = tonumber(state.qualified_count)
    local max_role = tonumber(state.max_allowed) or 0

    if qualified == nil then
        qualified = current
    end

    return current >= max_role and qualified < max_role
end

local function select_backfill_state_to_trim(role_states, rank_mode_active)
    local selected_blocked_state = nil
    local selected_blocked_need = 0

    if rank_mode_active then
        for _, state in ipairs(role_states or {}) do
            if state_has_blocked_backfill_slot(state, true) then
                local current = tonumber(state.current_count) or 0
                local qualified = tonumber(state.qualified_count)
                local max_role = tonumber(state.max_allowed) or 0
                local need = 1

                if qualified == nil then
                    qualified = current
                end

                if max_role > qualified then
                    need = max_role - qualified
                end

                if not selected_blocked_state or need > selected_blocked_need then
                    selected_blocked_state = state
                    selected_blocked_need = need
                end
            end
        end
    end

    if selected_blocked_state then
        return selected_blocked_state, true
    end

    local selected_surplus_state = nil
    local selected_surplus = 0
    for _, state in ipairs(role_states or {}) do
        local surplus = (tonumber(state.current_count) or 0) - (tonumber(state.max_allowed) or 0)
        if surplus > 0 then
            if not selected_surplus_state or surplus > selected_surplus then
                selected_surplus_state = state
                selected_surplus = surplus
            end
        end
    end

    if selected_surplus_state then
        return selected_surplus_state, false
    end

    return nil, false
end

local function build_rank_social_priority_context(saved)
    saved = saved or AutoBand.saved or {}

    local guild_mode = AutoBand.get_saved_social_priority_mode("guild", saved)
    local friend_mode = AutoBand.get_saved_social_priority_mode("friend", saved)
    local social_priority_grace_active =
        (guild_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF or
         friend_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF) and
        type(AutoBand.is_social_priority_grace_active) == "function" and
        AutoBand.is_social_priority_grace_active()

    if social_priority_grace_active then
        guild_mode = AB_const.SOCIAL_PRIORITY_MODE_OFF
        friend_mode = AB_const.SOCIAL_PRIORITY_MODE_OFF
    end

    local enabled =
        guild_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF or
        friend_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF

    local context = {
        enabled = enabled == true,
        guild_mode = guild_mode,
        friend_mode = friend_mode,
        guild_member_set = {},
        friend_member_set = {},
        container = {
            guild_priority_mode = guild_mode,
            friend_priority_mode = friend_mode,
        }
    }

    if context.enabled then
        if type(AutoBand.get_guild_membership_set_ref) == "function" then
            context.guild_member_set = AutoBand.get_guild_membership_set_ref()
        end
        if type(AutoBand.get_friend_membership_set_ref) == "function" then
            context.friend_member_set = AutoBand.get_friend_membership_set_ref()
        end
    end

    return context
end

local function player_has_social_priority_rank_exemption(player_name, social_context)
    if not social_context or social_context.enabled ~= true or player_name == nil then
        return false
    end

    local _, guild_match, friend_match = AutoBand.get_effective_social_priority_mode(
        player_name,
        social_context.guild_member_set,
        social_context.friend_member_set,
        social_context.container
    )

    return (guild_match and social_priority_mode_grants_rank_exemption(social_context.guild_mode)) or
           (friend_match and social_priority_mode_grants_rank_exemption(social_context.friend_mode))
end

local function build_wb_roster_need_summary(wb, saved)
    if not wb or not saved then
        return nil
    end

    local summary = {
        tanks = 0,
        healers = 0,
        mdpss = 0,
        rdpss = 0,
        qualified_tanks = 0,
        qualified_healers = 0,
        qualified_mdpss = 0,
        qualified_rdpss = 0,
        rank_requirements_met = true,
    }

    local rank_check_enabled =
        saved.autokick_low_rank_enabled and
        type(AutoBand.get_rank_requirement_status_for_player) == "function"
    local social_context = nil
    if rank_check_enabled then
        social_context = build_rank_social_priority_context(saved)
    end

    summary.role_rank_backfill_active =
        saved.autokick_enabled and
        saved.backfill_enabled == true and
        rank_check_enabled
    summary.use_dps_weighting_for_message = saved.autokick_enabled and saved.dps_weighting_enabled

    wb:foreach_player(function(_, player)
        if not player then
            return
        end

        local below_required = false
        if rank_check_enabled then
            local required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(player.role)
            required_rank = AutoBand.normalize_rank_requirement_value(required_rank, 0)
            local rank_state = AutoBand.get_rank_requirement_status_for_player(player, required_rank, {
                treat_unknown_rr_as_below = true,
            })
            below_required = rank_state and rank_state.below_required == true
            if below_required and player_has_social_priority_rank_exemption(player.name, social_context) then
                below_required = false
            end
            if below_required then
                summary.rank_requirements_met = false
            end
        end

        if player.role == AB_const.TANK then
            summary.tanks = summary.tanks + 1
            if not below_required then
                summary.qualified_tanks = summary.qualified_tanks + 1
            end
        elseif player.role == AB_const.HEALER then
            summary.healers = summary.healers + 1
            if not below_required then
                summary.qualified_healers = summary.qualified_healers + 1
            end
        elseif player.role == AB_const.MDPS then
            summary.mdpss = summary.mdpss + 1
            if not below_required then
                summary.qualified_mdpss = summary.qualified_mdpss + 1
            end
        elseif player.role == AB_const.RDPS then
            summary.rdpss = summary.rdpss + 1
            if not below_required then
                summary.qualified_rdpss = summary.qualified_rdpss + 1
            end
        end
    end)

    summary.total_players = summary.tanks + summary.healers + summary.mdpss + summary.rdpss
    summary.dpss = summary.mdpss + summary.rdpss
    summary.qualified_dpss = summary.qualified_mdpss + summary.qualified_rdpss
    summary.roster_players = summary.total_players
    if type(wb.player_count) == "number" and wb.player_count > summary.roster_players then
        summary.roster_players = wb.player_count
    end
    summary.available_spots = math.max(0, 24 - summary.roster_players)

    summary.neededTank = math.max(0, saved.max_tanks - summary.tanks)
    summary.neededHealer = math.max(0, saved.max_healers - summary.healers)
    summary.neededMdps = 0
    summary.neededRdps = 0
    summary.neededDps = 0

    if summary.use_dps_weighting_for_message then
        summary.neededMdps = math.max(0, saved.max_mdps - summary.mdpss)
        summary.neededRdps = math.max(0, saved.max_rdps - summary.rdpss)
    else
        summary.neededDps = math.max(0, saved.max_dps - summary.dpss)
    end

    summary.blocked_role_replacements_needed = false
    if summary.role_rank_backfill_active then
        summary.neededTank = compute_role_backfill_need_count(summary.tanks, summary.qualified_tanks, saved.max_tanks, true)
        summary.neededHealer = compute_role_backfill_need_count(summary.healers, summary.qualified_healers, saved.max_healers, true)
        if summary.use_dps_weighting_for_message then
            summary.neededMdps = compute_role_backfill_need_count(summary.mdpss, summary.qualified_mdpss, saved.max_mdps, true)
            summary.neededRdps = compute_role_backfill_need_count(summary.rdpss, summary.qualified_rdpss, saved.max_rdps, true)
            summary.blocked_role_replacements_needed =
                state_has_blocked_backfill_slot({ current_count = summary.tanks, qualified_count = summary.qualified_tanks, max_allowed = saved.max_tanks }, true) or
                state_has_blocked_backfill_slot({ current_count = summary.healers, qualified_count = summary.qualified_healers, max_allowed = saved.max_healers }, true) or
                state_has_blocked_backfill_slot({ current_count = summary.mdpss, qualified_count = summary.qualified_mdpss, max_allowed = saved.max_mdps }, true) or
                state_has_blocked_backfill_slot({ current_count = summary.rdpss, qualified_count = summary.qualified_rdpss, max_allowed = saved.max_rdps }, true)
        else
            summary.neededDps = compute_role_backfill_need_count(summary.dpss, summary.qualified_dpss, saved.max_dps, true)
            summary.blocked_role_replacements_needed =
                state_has_blocked_backfill_slot({ current_count = summary.tanks, qualified_count = summary.qualified_tanks, max_allowed = saved.max_tanks }, true) or
                state_has_blocked_backfill_slot({ current_count = summary.healers, qualified_count = summary.qualified_healers, max_allowed = saved.max_healers }, true) or
                state_has_blocked_backfill_slot({ current_count = summary.dpss, qualified_count = summary.qualified_dpss, max_allowed = saved.max_dps }, true)
        end
    end

    summary.role_requirements_met = true
    if saved.autokick_enabled then
        if summary.use_dps_weighting_for_message then
            summary.role_requirements_met =
                summary.neededTank == 0 and
                summary.neededHealer == 0 and
                summary.neededMdps == 0 and
                summary.neededRdps == 0
        else
            summary.role_requirements_met =
                summary.neededTank == 0 and
                summary.neededHealer == 0 and
                summary.neededDps == 0
        end
    end

    summary.requirements_met = summary.role_requirements_met and summary.rank_requirements_met
    summary.can_show_currently_full = summary.available_spots == 0 and summary.requirements_met
    summary.role_message_gate = summary.available_spots
    if summary.available_spots == 0 and not summary.can_show_currently_full then
        summary.role_message_gate = 1
    end

    if type(AutoBand.get_saved_rank_requirements) == "function" then
        summary.saved_rank_tank, summary.saved_rank_healer, summary.saved_rank_dps = AutoBand.get_saved_rank_requirements(saved)
    else
        summary.saved_rank_tank = saved.min_rank_tank or saved.min_rank or 0
        summary.saved_rank_healer = saved.min_rank_healer or saved.min_rank or 0
        summary.saved_rank_dps = saved.min_rank_dps or saved.min_rank or 0
    end

    return summary
end

-- Returns the current backfill-trim order as display names, matching live
-- backfill policy (role, role+rank, or rank-only) without mutating state.
function AutoBand.get_backfill_route_members(wb_obj)
    local mode, is_active, role_mode_active, rank_mode_active = backfill_route_mode_info()
    if not is_active then
        return {}, mode
    end

    if not wb_obj and AutoBand.get_wb then
        wb_obj = AutoBand.get_wb()
    end
    if not wb_obj or type(wb_obj.foreach_player) ~= "function" then
        return {}, mode
    end

    local saved = AutoBand.saved or {}
    local wb_player_count = 0

    local social_context = nil
    if rank_mode_active then
        social_context = build_rank_social_priority_context(saved)
    end

    local tanks = 0
    local healers = 0
    local dpss = 0
    local mdpss = 0
    local rdpss = 0
    local qualified_tanks = 0
    local qualified_healers = 0
    local qualified_dpss = 0
    local qualified_mdpss = 0
    local qualified_rdpss = 0

    local tanks_members = {}
    local healers_members = {}
    local dps_members = {}
    local mdps_members = {}
    local rdps_members = {}
    local rank_only_candidates = {}

    wb_obj:foreach_player(function(_gid, player)
        if not player or not player.name then
            return
        end

        local key, display_name = AutoBand.normalize_wb_player_name(player.name)
        if not key or not display_name or display_name == "" then
            return
        end

	        wb_player_count = wb_player_count + 1

	        local role = player.role
	        local required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(role)
	        required_rank = AutoBand.normalize_rank_requirement_value(required_rank, 0)
	        local rank_state = AutoBand.get_rank_requirement_status_for_player(player, required_rank, {
	            treat_unknown_rr_as_below = rank_mode_active
	        })
	        local below_rank = rank_mode_active and rank_state.below_required == true
            if below_rank and player_has_social_priority_rank_exemption(player.name, social_context) then
                below_rank = false
            end
	        local arrival_idx = AutoBand.get_arrival_index(player.name)

	        local entry = {
	            key = key,
	            name = display_name,
	            arrival_idx = arrival_idx,
	            below_rank = below_rank,
	            required_metric = rank_state.required_metric,
	            rank_unknown = rank_state.rr_unknown == true
	        }

        if role == AB_const.TANK then
            tanks = tanks + 1
            if not below_rank then
                qualified_tanks = qualified_tanks + 1
            end
            tanks_members[#tanks_members + 1] = entry
        elseif role == AB_const.HEALER then
            healers = healers + 1
            if not below_rank then
                qualified_healers = qualified_healers + 1
            end
            healers_members[#healers_members + 1] = entry
        elseif role == AB_const.MDPS then
            dpss = dpss + 1
            mdpss = mdpss + 1
            if not below_rank then
                qualified_dpss = qualified_dpss + 1
                qualified_mdpss = qualified_mdpss + 1
            end
            dps_members[#dps_members + 1] = entry
            mdps_members[#mdps_members + 1] = entry
        elseif role == AB_const.RDPS then
            dpss = dpss + 1
            rdpss = rdpss + 1
            if not below_rank then
                qualified_dpss = qualified_dpss + 1
                qualified_rdpss = qualified_rdpss + 1
            end
            dps_members[#dps_members + 1] = entry
            rdps_members[#rdps_members + 1] = entry
        end

        if mode == "rank-only" and below_rank then
            rank_only_candidates[#rank_only_candidates + 1] = entry
        end
    end)

    local route_members = {}

    if mode == "rank-only" then
        local players_to_trim = wb_player_count - 22
        if players_to_trim <= 0 then
            return route_members, mode
        end

        sort_backfill_candidates(rank_only_candidates, false)
        for i = 1, players_to_trim do
            local candidate = rank_only_candidates[i]
            if not candidate then
                break
            end
            route_members[#route_members + 1] = candidate.name
        end

        return route_members, mode
    end

    if role_mode_active then
        local role_states = {
            {
                members = tanks_members,
                max_allowed = tonumber(saved.max_tanks) or 0,
                current_count = tanks,
                qualified_count = qualified_tanks
            },
            {
                members = healers_members,
                max_allowed = tonumber(saved.max_healers) or 0,
                current_count = healers,
                qualified_count = qualified_healers
            }
        }

        if saved.dps_weighting_enabled then
            role_states[#role_states + 1] = {
                members = mdps_members,
                max_allowed = tonumber(saved.max_mdps) or 0,
                current_count = mdpss,
                qualified_count = qualified_mdpss
            }
            role_states[#role_states + 1] = {
                members = rdps_members,
                max_allowed = tonumber(saved.max_rdps) or 0,
                current_count = rdpss,
                qualified_count = qualified_rdpss
            }
        else
            role_states[#role_states + 1] = {
                members = dps_members,
                max_allowed = tonumber(saved.max_dps) or 0,
                current_count = dpss,
                qualified_count = qualified_dpss
            }
        end

        local capacity_total = (tonumber(saved.max_tanks) or 0) + (tonumber(saved.max_healers) or 0) + (tonumber(saved.max_dps) or 0)
        local missing_role_type_count = 0
        for _, state in ipairs(role_states) do
            local need = compute_role_backfill_need_count(state.current_count, state.qualified_count, state.max_allowed, rank_mode_active)
            if need > 0 then
                missing_role_type_count = missing_role_type_count + 1
            end
        end
        if missing_role_type_count > ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS then
            missing_role_type_count = ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS
        end

        local target_player_count = capacity_total - missing_role_type_count
        local players_to_trim = wb_player_count - target_player_count
        if players_to_trim <= 0 then
            return route_members, mode
        end

        local selected_lookup = {}
        local trimmed = 0
        while trimmed < players_to_trim do
            local selected_state, blocked_required_slot = select_backfill_state_to_trim(role_states, rank_mode_active)
            if not selected_state then
                break
            end

            local candidates = {}
            for _, member in ipairs(selected_state.members or {}) do
                if member and member.key and not selected_lookup[member.key] then
                    if not blocked_required_slot or member.below_rank == true then
                        candidates[#candidates + 1] = {
                            key = member.key,
                            name = member.name,
                            arrival_idx = member.arrival_idx,
                            below_rank = member.below_rank,
                            required_metric = member.required_metric,
                            rank_unknown = member.rank_unknown,
                            blocking_required_slot = blocked_required_slot == true
                        }
                    end
                end
            end
            if #candidates == 0 then
                break
            end

            sort_backfill_candidates(candidates, (not blocked_required_slot) and rank_mode_active)
            local picked = candidates[1]
            if not picked then
                break
            end

            selected_lookup[picked.key] = true
            route_members[#route_members + 1] = picked.name
            selected_state.current_count = selected_state.current_count - 1
            trimmed = trimmed + 1
        end
    end

    return route_members, mode
end

function AutoBand.get_backfill_route_lookup(wb_obj)
    local route_members, route_mode = AutoBand.get_backfill_route_members(wb_obj)
    local lookup = {}
    for _, name in ipairs(route_members) do
        local key = AutoBand.normalize_wb_player_name(name)
        if key then
            lookup[key] = true
        end
    end
    return lookup, route_members, route_mode
end

function AutoBand.format_backfill_route_members(route_members, max_entries)
    if type(route_members) ~= "table" or #route_members == 0 then
        return "none"
    end

    local count = #route_members
    local limit = max_entries or count
    if limit < 1 then
        limit = 1
    end
    if limit > count then
        limit = count
    end

    local parts = {}
    for i = 1, limit do
        local name = tostring(route_members[i] or "")
        parts[#parts + 1] = name .. AutoBand.format_arrival_tag(name)
    end

    local text = table.concat(parts, " -> ")
    if count > limit then
        text = text .. " (+" .. tostring(count - limit) .. " more)"
    end
    return text
end

function AutoBand.auto_kick()
  if (not AutoBand.is_wb_leader() or AutoBand.debugon) then
    return false
  end

  -- Cache frequently used saved settings locally for this function execution
  local ak_low_enabled = AutoBand.saved.autokick_low_rank_enabled == true
  -- Rank edits pause rank enforcement briefly; social-priority edits are gated
  -- separately below before their role/rank effects become live again.
  local rank_requirement_grace_active = ak_low_enabled and AutoBand.is_rank_requirement_grace_active()
  local ak_low_enforcement_enabled = ak_low_enabled and not rank_requirement_grace_active
  local ak_enabled = AutoBand.saved.autokick_enabled
  local ak_wewh_enabled = AutoBand.saved.autokick_we_wh_enabled
  local ak_zone_enabled = AutoBand.saved.autokick_rvrzone_enabled
  local ak_ignore_enabled = AutoBand.saved.autokick_ignorelist_enabled
  local backfill_enabled = AutoBand.saved.backfill_enabled == true
  local rank_backfill_enabled = backfill_enabled and ak_low_enforcement_enabled
  local rank_only_backfill_enabled = rank_backfill_enabled and not ak_enabled
  local role_cap_backfill_enabled = ak_enabled
  local rank_only_keep_open_slots = 2
  local restrict_race_enabled = AutoBand.saved.restrict_same_race
  local guild_priority_mode = AutoBand.get_saved_social_priority_mode("guild")
  local friend_priority_mode = AutoBand.get_saved_social_priority_mode("friend")
  local social_priority_grace_active =
    (guild_priority_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF or
     friend_priority_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF) and
    AutoBand.is_social_priority_grace_active()
  -- Let social-priority edits settle before they start affecting live
  -- role-cap and rank-based auto-enforcement.
  if social_priority_grace_active then
    guild_priority_mode = AB_const.SOCIAL_PRIORITY_MODE_OFF
    friend_priority_mode = AB_const.SOCIAL_PRIORITY_MODE_OFF
  end
  local promote_guild_enabled = social_priority_mode_is_promote(guild_priority_mode)
  local promote_friend_enabled = social_priority_mode_is_promote(friend_priority_mode)
  local promote_notice_enabled = promote_guild_enabled or promote_friend_enabled
  local social_priority_enabled =
    guild_priority_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF or
    friend_priority_mode ~= AB_const.SOCIAL_PRIORITY_MODE_OFF

  -- Early exit if no relevant auto-kick features are enabled
  if not ak_low_enforcement_enabled and not ak_enabled and not ak_wewh_enabled and not ak_zone_enabled and not restrict_race_enabled and not ak_ignore_enabled then
    -- Clear _old tables if features are off to prevent stale data
    tanks_t_old, healers_t_old, dps_t_old, mdps_t_old, rdps_t_old = {}, {}, {}, {}, {}
    return false
  end

  local wb_obj = AutoBand.get_wb()
  if not wb_obj then AB_util.print("AutoKick: Could not get Warband Object."); return false end -- Safety check

  local pending_kicks = {} -- Store all players to kick { [name] = reason }
  local pending_kick_count = 0

  local function mark_pending_kick(player_name, reason)
    if not player_name or pending_kicks[player_name] then
      return false
    end
    pending_kicks[player_name] = reason
    pending_kick_count = pending_kick_count + 1
    return true
  end

  -- Working state used by role-cap and rank-only auto-kick/backfill paths.
  local tanks_t, healers_t, dps_t, mdps_t, rdps_t
  local tanks, healers, dpss, mdpss, rdpss
  local qualified_tanks, qualified_healers, qualified_dpss, qualified_mdpss, qualified_rdpss
  local backfill_needed_roles_text = nil
  local backfill_needed_join_roles_text = nil
  local backfill_rank_enabled = ak_low_enforcement_enabled == true
  local player_required_rank = {}
  local player_required_metric = {}
  local player_guild_promote_match = {}
  local player_friend_promote_match = {}
  local rank_only_backfill_candidates = {}
  local wb_player_count = 0
  local guild_member_set, friend_member_set, ignore_set
  local live_members_by_key = {}
  local live_member_state_by_key = {}
  local at_risk_by_key = {}
  local pending_rr_notice_state = AutoBand.realmrank_ensure_pending_notice_state()
  local self_key = nil
  if GameData and GameData.Player and GameData.Player.name then
    self_key = AutoBand.normalize_wb_player_name(GameData.Player.name)
  end

  local function role_to_backfill_label(role_key)
    if role_key == AB_const.TANK then
      return "tank"
    elseif role_key == AB_const.HEALER then
      return "healer"
    elseif role_key == AB_const.MDPS then
      return "mdps"
    elseif role_key == AB_const.RDPS then
      return "rdps"
    elseif role_key == "dps" then
      return "dps"
    end
    return "character"
  end

  local function role_to_backfill_message_label(role_key)
    if role_key == AB_const.TANK or role_key == "tank" then
      return "tank"
    elseif role_key == AB_const.HEALER or role_key == "healer" then
      return "healer"
    elseif role_key == AB_const.MDPS or role_key == "mdps" then
      return "mDPS"
    elseif role_key == AB_const.RDPS or role_key == "rdps" then
      return "rDPS"
    elseif role_key == "dps" then
      return "DPS"
    end
    return "player"
  end

    local function remember_live_member(key, display_name)
    if key and display_name and key ~= self_key then
      live_members_by_key[key] = display_name
    end
  end

  local function mark_backfill_risk(player_name, risk)
    if not player_name or not risk then
      return
    end
    if pending_kicks[player_name] then
      return
    end
    local key, display_name = AutoBand.normalize_wb_player_name(player_name)
    if not key or key == self_key then
      return
    end
    local live_name = live_members_by_key[key] or display_name
    if not live_name then
      return
    end
    at_risk_by_key[key] = risk
  end

  local function get_candidate_social_mode_rank(candidate)
    if candidate and candidate.social_mode_rank ~= nil then
      return tonumber(candidate.social_mode_rank) or 0
    end
    if candidate and candidate.social_mode ~= nil then
      return get_social_priority_mode_trim_rank(candidate.social_mode)
    end
    return 0
  end

  local rank_only_backfill_candidates_sorted = false
  local function ensure_rank_only_backfill_sorted()
    if rank_only_backfill_candidates_sorted or #rank_only_backfill_candidates <= 1 then
      rank_only_backfill_candidates_sorted = true
      return
    end

    table.sort(rank_only_backfill_candidates, function(a, b)
      local a_social = get_candidate_social_mode_rank(a)
      local b_social = get_candidate_social_mode_rank(b)
      if a_social ~= b_social then
        return a_social < b_social
      end
      local a_idx = a.arrival_idx or -1
      local b_idx = b.arrival_idx or -1
      if a_idx ~= b_idx then
        return a_idx > b_idx
      end
      return a.name < b.name
    end)

    rank_only_backfill_candidates_sorted = true
  end

    local role_candidate_cache = role_cap_backfill_enabled and backfill_enabled and {
    tank = { items = {}, sorted_social = nil, sorted_backfill = nil },
    healer = { items = {}, sorted_social = nil, sorted_backfill = nil },
    mdps = { items = {}, sorted_social = nil, sorted_backfill = nil },
    rdps = { items = {}, sorted_social = nil, sorted_backfill = nil },
    dps = { items = {}, sorted_social = nil, sorted_backfill = nil }
    } or nil

  local function role_candidates_copy(items)
    local copy = {}
    for i = 1, #items do
      copy[i] = items[i]
    end
    return copy
  end

  local function sort_candidates_social(candidates)
    table.sort(candidates, function(a, b)
      local a_social = get_candidate_social_mode_rank(a)
      local b_social = get_candidate_social_mode_rank(b)
      if a_social ~= b_social then
        return a_social < b_social
      end
      local a_idx = a.arrival_idx or -1
      local b_idx = b.arrival_idx or -1
      if a_idx ~= b_idx then
        return a_idx > b_idx
      end
      return a.name < b.name
    end)
  end

  local function sort_candidates_backfill(candidates)
    table.sort(candidates, function(a, b)
      local a_below = (a.below_rank == true)
      local b_below = (b.below_rank == true)
      if a_below ~= b_below then
        return a_below
      end
      local a_social = get_candidate_social_mode_rank(a)
      local b_social = get_candidate_social_mode_rank(b)
      if a_social ~= b_social then
        return a_social < b_social
      end
      local a_idx = a.arrival_idx or -1
      local b_idx = b.arrival_idx or -1
      if a_idx ~= b_idx then
        return a_idx > b_idx
      end
      return a.name < b.name
    end)
  end

  local function get_role_candidate_state(role_key)
    return role_candidate_cache and role_candidate_cache[role_key]
  end

  local function add_role_candidate(role_key, candidate)
    local state = get_role_candidate_state(role_key)
    if not state then
      return
    end
    local items = state.items
    items[#items + 1] = candidate
    state.sorted_social = nil
    state.sorted_backfill = nil
  end

  local function get_role_candidates(role_key, prioritize_below_rank)
    local state = get_role_candidate_state(role_key)
    if not state then
      return {}
    end

    if prioritize_below_rank then
      if state.sorted_backfill == nil then
        state.sorted_backfill = role_candidates_copy(state.items)
        if #state.sorted_backfill > 1 then
          sort_candidates_backfill(state.sorted_backfill)
        end
      end
      return state.sorted_backfill
    end

    if state.sorted_social == nil then
      state.sorted_social = role_candidates_copy(state.items)
      if #state.sorted_social > 1 then
        sort_candidates_social(state.sorted_social)
      end
    end
    return state.sorted_social
  end

  local function find_role_candidate(role_key, prioritize_below_rank, require_below_rank, skip_lookup)
    local candidates = get_role_candidates(role_key, prioritize_below_rank)
    for i = 1, #candidates do
      local candidate = candidates[i]
      local candidate_name = candidate and candidate.name
      if candidate_name and not pending_kicks[candidate_name] and
         (not require_below_rank or candidate.below_rank == true) and
         (not skip_lookup or not skip_lookup[candidate_name]) then
        return candidate
      end
    end
    return nil
  end

  local function get_player_career_rank(player)
    local current_rank = tonumber(player and player.level) or 0
    current_rank = math.floor(current_rank)
    if current_rank < 0 then
      current_rank = 0
    end
    return current_rank
  end

  local function get_backfill_floor_rank(required_rank)
    local normalized_required = AutoBand.normalize_rank_requirement_value(required_rank, 0)
    local minimum_rank = tonumber(AB_const.MINIMUM_RANK) or 16
    if normalized_required < minimum_rank then
      return nil
    end
    return minimum_rank
  end

  if type(AutoBand.realmrank_maybe_warn_requirement_snapshot) == "function" then
    AutoBand.realmrank_maybe_warn_requirement_snapshot(ak_low_enforcement_enabled == true)
  end

  -- Initialize role composition specific variables and data
  if ak_ignore_enabled then
    ignore_set = AutoBand.get_ignore_membership_set_ref()
  end
  guild_member_set = {}
  friend_member_set = {}
  if social_priority_enabled and (ak_enabled or ak_low_enforcement_enabled or rank_only_backfill_enabled) then
    guild_member_set = AutoBand.get_guild_membership_set_ref()
    friend_member_set = AutoBand.get_friend_membership_set_ref()
  end
  if ak_enabled then
    tanks_t, healers_t, dps_t, mdps_t, rdps_t = {}, {}, {}, {}, {}
    tanks, healers, dpss, mdpss, rdpss = 0, 0, 0, 0, 0
    qualified_tanks, qualified_healers, qualified_dpss, qualified_mdpss, qualified_rdpss = 0, 0, 0, 0, 0
  end

  -- Single Loop Player Processing
  wb_obj:foreach_player(
    function(_gid, player)
      -- Ensure player.name exists before proceeding (safety)
      if not player or not player.name then return end
      local player_name = player.name -- Cache for pending_kicks key
        local player_name_key, player_display_name = AutoBand.normalize_wb_player_name(player_name)
      local leader_race = AutoBand.race  -- Get leader's race
      local race_ok = AutoBand.raceDetermined -- Check if leader's race is known
      wb_player_count = wb_player_count + 1
        remember_live_member(player_name_key, player_display_name)
      local social_mode = AB_const.SOCIAL_PRIORITY_MODE_OFF
      local guild_match = false
      local friend_match = false
      if social_priority_enabled then
        social_mode, guild_match, friend_match = AutoBand.get_effective_social_priority_mode(player_name, guild_member_set, friend_member_set)
      end
      local social_mode_rank = get_social_priority_mode_trim_rank(social_mode)
      local rank_candidacy_exempt =
        (guild_match and social_priority_mode_grants_rank_exemption(guild_priority_mode)) or
        (friend_match and social_priority_mode_grants_rank_exemption(friend_priority_mode))
      player_guild_promote_match[player_name] = guild_match and promote_guild_enabled
      player_friend_promote_match[player_name] = friend_match and promote_friend_enabled

      -- Race Restriction Check (Run if restrict_race_enabled)
      if restrict_race_enabled and race_ok and not pending_kicks[player_name] then
        local player_race = AB_const.CAREERLINE_RACEMAP[player.careerLine]
        if player_race and player_race ~= leader_race then
          local race_title = AB_const.GetRaceThemeTitle(leader_race)
          local article = pick_article_for_title(race_title)
          mark_pending_kick(player_name, "this is " .. article .. " " .. race_title .. " only warband.")
        end
      end

	      local required_rank = nil
	      local required_metric = nil
	      local rank_state = nil
	      local is_below_required_rank = false
	      local rank_is_unknown = false
      local backfill_floor_rank = nil
      local below_backfill_floor_rank = false
	      if ak_low_enforcement_enabled then
	        required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(player.role)
	        required_rank = AutoBand.normalize_rank_requirement_value(required_rank, 0)
	        rank_state = AutoBand.get_rank_requirement_status_for_player(player, required_rank, { treat_unknown_rr_as_below = rank_backfill_enabled })
	        required_metric = rank_state.required_metric
	        player_required_rank[player_name] = required_rank
	        player_required_metric[player_name] = required_metric
	        is_below_required_rank = rank_state.below_required == true
	        rank_is_unknown = rank_state.rr_unknown == true
	          if rank_candidacy_exempt then
	            is_below_required_rank = false
	            rank_is_unknown = false
	          end
          if rank_backfill_enabled and is_below_required_rank then
            backfill_floor_rank = get_backfill_floor_rank(required_rank)
            if backfill_floor_rank ~= nil and get_player_career_rank(player) < backfill_floor_rank then
              below_backfill_floor_rank = true
            end
          end
	        if not rank_is_unknown then
	          AutoBand.realmrank_clear_pending_notice(player_name, pending_rr_notice_state)
	        end
	      end
      local live_key = player_name_key
      if live_key and live_key ~= self_key then
	        live_member_state_by_key[live_key] = {
	          required_rank = required_rank,
	          required_metric = required_metric,
	          below_rank = is_below_required_rank == true,
	          rank_unknown = rank_is_unknown == true
	        }
	      end

      -- Low Rank Check (Run if autokick_low_rank_enabled)
      -- Check if not already marked for kick
	      if ak_low_enforcement_enabled and not pending_kicks[player_name] then
	        if rank_is_unknown and required_metric == "RR" and not rank_backfill_enabled then
	          AutoBand.realmrank_maybe_send_pending_notice(player_name, required_rank, pending_rr_notice_state, self_key, enqueue_backfill_notice)
	        elseif is_below_required_rank then
          if rank_backfill_enabled and below_backfill_floor_rank then
            mark_pending_kick(player_name, "this is a T2+ warband. Please come back when you are " .. tostring(backfill_floor_rank) .. "+.")
	          -- With backfill enabled, low-rank trims above the T2 floor are handled in the surplus pass.
	          elseif not rank_backfill_enabled then
	            local current_rank
	            if rank_state and rank_state.rank_value ~= nil then
	              current_rank = rank_state.rank_value
	            else
	              current_rank = get_player_career_rank(player)
	            end
	            local metric = required_metric or "CR"
		            mark_pending_kick(player_name, "you are below required " .. metric .. " (" .. metric .. " " .. tostring(current_rank) .. " < " .. tostring(required_rank) .. ").")
		          end
		        end
		      end

      -- WE/WH Check (Run if autokick_we_wh_enabled)
      -- Check if not already marked for kick
	      if ak_wewh_enabled and not pending_kicks[player_name] then
	        if player.careerLine == GameData.CareerLine.WITCH_ELF or player.careerLine == GameData.CareerLine.WITCH_HUNTER then
	          mark_pending_kick(player_name, "autokick of stealthers is enabled.")
	        end
	      end

      -- Check if in a scenario or unsupported zone (Run if autokick_rvrzone_enabled)
      -- Check if not already marked for kick
	      if ak_zone_enabled and not pending_kicks[player_name] then
	        if player.zoneNum and player.zoneNum ~= 0 then
	          -- Check if their zone is NOT in the allowed set
	          if not AutoBand.is_allowed_rvr_or_city_zone(player.zoneNum) then
	            local zoneName = AB_util.get_zone_name_sanitized(player.zoneNum)
	            mark_pending_kick(player_name, "you appear to be in a scenario or another unsupported zone (Your zone: " .. zoneName .. ").")
	          end
	        end
	      end

      -- Ignore List Check (independent toggle)
	      if ak_ignore_enabled and not pending_kicks[player_name] then
	        if ignore_set and player_name_key and ignore_set[player_name_key] then
	          mark_pending_kick(player_name, "you are on my ignore list.")
	        end
	      end

	      -- Rank-only backfill (no role enforcement): keep a small fixed number of slots open.
	      if rank_only_backfill_enabled and not pending_kicks[player_name] and is_below_required_rank then
	        table.insert(rank_only_backfill_candidates, {
	          name = player_name,
	          required_rank = required_rank,
	          required_metric = required_metric,
	          arrival_idx = AutoBand.get_arrival_index(player_name),
	          social_mode = social_mode,
	          social_mode_rank = social_mode_rank,
	          role_name_singular = role_to_backfill_label(player.role),
		          rank_unknown = rank_is_unknown == true
		        })
	      end

	      local role_candidate = nil
        if role_cap_backfill_enabled and backfill_enabled and not pending_kicks[player_name] then
	        role_candidate = {
	          name = player_name,
	          social_mode = normalize_social_priority_mode(social_mode, AB_const.SOCIAL_PRIORITY_MODE_OFF),
	          social_mode_rank = social_mode_rank,
	          arrival_idx = AutoBand.get_arrival_index(player_name),
	          below_rank = is_below_required_rank == true,
	          required_metric = required_metric,
	          rank_unknown = rank_is_unknown == true
	        }
	      end

	      -- Role-cap backfill bookkeeping (used when AKick role caps are enabled)
	      -- Check if not already marked for kick
	      if role_cap_backfill_enabled and not pending_kicks[player_name] then

        -- Role counting for role composition limits (only if not kicked for ignore)
        if not pending_kicks[player_name] then
          -- Populate role tables for role composition logic after loop
	          if (player.role == AB_const.TANK) then
	            tanks_t[player_name] = social_mode; tanks = tanks + 1
	            if role_candidate then
	              add_role_candidate("tank", role_candidate)
	            end
	            if not backfill_rank_enabled or not is_below_required_rank then
	              qualified_tanks = qualified_tanks + 1
	            end
	          elseif (player.role == AB_const.HEALER) then
	            healers_t[player_name] = social_mode; healers = healers + 1
	            if role_candidate then
	              add_role_candidate("healer", role_candidate)
	            end
	            if not backfill_rank_enabled or not is_below_required_rank then
	              qualified_healers = qualified_healers + 1
	            end
	          elseif (player.role == AB_const.MDPS) then
	            dps_t[player_name] = social_mode; mdps_t[player_name] = social_mode; dpss = dpss + 1; mdpss = mdpss + 1
	            if role_candidate then
	              add_role_candidate("mdps", role_candidate)
	              add_role_candidate("dps", role_candidate)
	            end
	            if not backfill_rank_enabled or not is_below_required_rank then
	              qualified_dpss = qualified_dpss + 1
	              qualified_mdpss = qualified_mdpss + 1
	            end
	          elseif (player.role == AB_const.RDPS) then
	            dps_t[player_name] = social_mode; rdps_t[player_name] = social_mode; dpss = dpss + 1; rdpss = rdpss + 1
	            if role_candidate then
	              add_role_candidate("rdps", role_candidate)
	              add_role_candidate("dps", role_candidate)
	            end
	            if not backfill_rank_enabled or not is_below_required_rank then
	              qualified_dpss = qualified_dpss + 1
	              qualified_rdpss = qualified_rdpss + 1
	            end
          end
        end
      end
    end
  )

  if ak_enabled then
    local needed_parts = {}
    local needed_join_roles = {}
    local function add_needed_part(count, singular, plural)
      if not count or count <= 0 then
        return
      end
      local label = singular
      if count ~= 1 then
        label = plural or (singular .. "s")
      end
      table.insert(needed_parts, tostring(count) .. " " .. label)
    end
    local function add_needed_join_role(count, join_label)
      if not count or count <= 0 then
        return
      end
      table.insert(needed_join_roles, join_label)
    end

    local need_tanks = compute_role_backfill_need_count(tanks, qualified_tanks, AutoBand.saved.max_tanks, backfill_rank_enabled)
    local need_healers = compute_role_backfill_need_count(healers, qualified_healers, AutoBand.saved.max_healers, backfill_rank_enabled)
    add_needed_part(need_tanks, role_to_backfill_message_label(AB_const.TANK))
    add_needed_part(need_healers, role_to_backfill_message_label(AB_const.HEALER))
    add_needed_join_role(need_tanks, "tanks")
    add_needed_join_role(need_healers, "healers")

    if AutoBand.saved.dps_weighting_enabled then
      local need_mdps = compute_role_backfill_need_count(mdpss, qualified_mdpss, AutoBand.saved.max_mdps, backfill_rank_enabled)
      local need_rdps = compute_role_backfill_need_count(rdpss, qualified_rdpss, AutoBand.saved.max_rdps, backfill_rank_enabled)
      add_needed_part(need_mdps, role_to_backfill_message_label(AB_const.MDPS), role_to_backfill_message_label(AB_const.MDPS))
      add_needed_part(need_rdps, role_to_backfill_message_label(AB_const.RDPS), role_to_backfill_message_label(AB_const.RDPS))
      add_needed_join_role(need_mdps, "mDPS players")
      add_needed_join_role(need_rdps, "rDPS players")
    else
      local need_dps = compute_role_backfill_need_count(dpss, qualified_dpss, AutoBand.saved.max_dps, backfill_rank_enabled)
      add_needed_part(need_dps, role_to_backfill_message_label("dps"), role_to_backfill_message_label("dps"))
      add_needed_join_role(need_dps, "DPS players")
    end

    backfill_needed_roles_text = join_list_with_conjunction(needed_parts, "and")
    if backfill_needed_roles_text == "" then
      backfill_needed_roles_text = nil
    end
    backfill_needed_join_roles_text = join_list_with_conjunction(needed_join_roles, "or")
    if backfill_needed_join_roles_text == "" then
      backfill_needed_join_roles_text = nil
    end
  end

  -- Perform role-cap backfill logic (AKick role enforcement mode)
  if role_cap_backfill_enabled then
    if backfill_enabled then
      local function build_survivor_table(role_table)
        local new_old_table = {}
        for k, v in pairs(role_table or {}) do
          if not pending_kicks[k] then
            new_old_table[k] = v
          end
        end
        return new_old_table
      end

	      local function build_backfill_kick_reason(candidate, role_name_singular, blocking_required_slot)
	        local role_and_rank_backfill_enabled = backfill_rank_enabled and role_cap_backfill_enabled
	        local candidate_rank_text = nil
	        local candidate_required_metric = candidate.required_metric
	        local candidate_should_include_rank_text = false
	        if role_and_rank_backfill_enabled then
	          local candidate_required_rank = player_required_rank[candidate.name]
	          if candidate_required_rank == nil then
	            candidate_required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(role_name_singular)
	          end
	          if not candidate_required_metric then
	            candidate_required_metric = AutoBand.get_rank_requirement_metric_label(candidate_required_rank)
	          end
	          candidate_rank_text = AutoBand.format_rank_requirement_value(candidate_required_rank)
	          candidate_should_include_rank_text = (candidate.below_rank == true)
	        end

		        if blocking_required_slot and candidate_should_include_rank_text and candidate_rank_text then
		          if candidate.rank_unknown and candidate_required_metric == "RR" then
		            return candidate_rank_text .. " is required. Please try again soon."
		          end
		          return candidate_rank_text .. " is required. Please try again later."
		        end
	        if backfill_needed_join_roles_text and candidate_should_include_rank_text and candidate_rank_text then
	          return "we need to make room for " .. backfill_needed_join_roles_text .. ". " .. candidate_rank_text .. " is required. Please try again later."
	        end
	        if backfill_needed_join_roles_text then
	          return "we need to make room for " .. backfill_needed_join_roles_text .. ". Please try again later."
	        end
	        if candidate_should_include_rank_text and candidate_rank_text then
	          if candidate.rank_unknown and candidate_required_metric == "RR" then
	            return candidate_rank_text .. " is required. Please try again soon."
	          end
	          return candidate_rank_text .. " is required. Please try again later."
	        end

	        return "we are rebalancing roles. Please try again later."
	      end
	      local role_states = {
        {
          role_table = tanks_t,
          max_allowed = AutoBand.saved.max_tanks,
          current_count = tanks,
          qualified_count = qualified_tanks,
          role_name_singular = "tank"
        },
        {
          role_table = healers_t,
          max_allowed = AutoBand.saved.max_healers,
          current_count = healers,
          qualified_count = qualified_healers,
          role_name_singular = "healer"
        }
      }

      if AutoBand.saved.dps_weighting_enabled then
        table.insert(role_states, {
          role_table = mdps_t,
          max_allowed = AutoBand.saved.max_mdps,
          current_count = mdpss,
          qualified_count = qualified_mdpss,
          role_name_singular = "mdps"
        })
        table.insert(role_states, {
          role_table = rdps_t,
          max_allowed = AutoBand.saved.max_rdps,
          current_count = rdpss,
          qualified_count = qualified_rdpss,
          role_name_singular = "rdps"
        })
      else
        table.insert(role_states, {
          role_table = dps_t,
          max_allowed = AutoBand.saved.max_dps,
          current_count = dpss,
          qualified_count = qualified_dpss,
          role_name_singular = "dps"
        })
      end

      local capacity_total = AutoBand.saved.max_tanks + AutoBand.saved.max_healers + AutoBand.saved.max_dps
      local missing_role_type_count = 0
      for _, state in ipairs(role_states) do
        local need = compute_role_backfill_need_count(state.current_count, state.qualified_count, state.max_allowed, backfill_rank_enabled)
        if need > 0 then
          missing_role_type_count = missing_role_type_count + 1
        end
      end
      if missing_role_type_count > ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS then
        missing_role_type_count = ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS
      end

	      local target_player_count = capacity_total - missing_role_type_count
	      local active_player_count = wb_player_count - pending_kick_count
	      local players_to_kick_count = active_player_count - target_player_count
	      local reserve_kicked = 0

	      if backfill_rank_enabled then
	        local function queue_under_rank_backfill_risk(state)
          local current_count = tonumber(state and state.current_count) or 0
          local max_allowed = tonumber(state and state.max_allowed) or 0
          if current_count >= max_allowed then
	            return
	          end

	          local role_label = role_to_backfill_message_label(state.role_name_singular)
	          local candidates = get_role_candidates(state.role_name_singular, true)
		          for _, candidate in ipairs(candidates) do
		            if not pending_kicks[candidate.name] and candidate.below_rank == true then
		              local queued_required_rank = player_required_rank[candidate.name]
		              if queued_required_rank == nil then
		                queued_required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(state.role_name_singular)
	              end
              local queued_required_metric = player_required_metric[candidate.name]
              if not queued_required_metric then
                queued_required_metric = AutoBand.get_rank_requirement_metric_label(queued_required_rank)
              end
              mark_backfill_risk(candidate.name, {
                mode = "role+rank",
                role_label = role_label,
                needed_roles_text = backfill_needed_roles_text,
                needed_roles_join_text = backfill_needed_join_roles_text,
                below_rank = true,
                queued_below_rank = true,
                required_rank = queued_required_rank,
                required_metric = queued_required_metric,
                rank_unknown = candidate.rank_unknown == true,
                active_count = active_player_count,
                target_count = target_player_count,
                warn = true
              })
            end
          end
        end

        for _, state in ipairs(role_states) do
          if not state_has_blocked_backfill_slot(state, true) then
            queue_under_rank_backfill_risk(state)
          end
        end
      end

      while reserve_kicked < players_to_kick_count do
        local selected_state, blocked_required_slot = select_backfill_state_to_trim(role_states, backfill_rank_enabled)
	        if not selected_state then
	          break
	        end

	        local candidate = find_role_candidate(
	          selected_state.role_name_singular,
	          (not blocked_required_slot) and backfill_rank_enabled,
	          blocked_required_slot
	        )
	        if not candidate then
	          break
	        end

	        local kick_reason = build_backfill_kick_reason(candidate, selected_state.role_name_singular, blocked_required_slot)
	        if not mark_pending_kick(candidate.name, kick_reason) then
	          break
	        end

	        selected_state.current_count = selected_state.current_count - 1
	        reserve_kicked = reserve_kicked + 1
	      end

      local active_player_count_after = active_player_count - reserve_kicked
      if active_player_count_after < 0 then
        active_player_count_after = 0
      end
      local slots_until_trim = target_player_count - active_player_count_after
      if slots_until_trim < 0 then
        slots_until_trim = 0
      end
      if slots_until_trim <= ROLE_CAP_BACKFILL_MAX_OPEN_SLOTS then
        local preview_states = {}
        for _, state in ipairs(role_states) do
          preview_states[#preview_states + 1] = {
            role_table = state.role_table,
            max_allowed = state.max_allowed,
            current_count = state.current_count,
            qualified_count = state.qualified_count,
            role_name_singular = state.role_name_singular
          }
        end

	        local preview_selected = {}
	        local preview_order = 0
	        while true do
	          local preview_state, preview_blocked_slot = select_backfill_state_to_trim(preview_states, backfill_rank_enabled)
	          if not preview_state then
	            break
	          end

	          local preview_candidate = find_role_candidate(
	            preview_state.role_name_singular,
	            (not preview_blocked_slot) and backfill_rank_enabled,
	            preview_blocked_slot,
	            preview_selected
	          )
	          if not preview_candidate then
	            break
	          end

          preview_selected[preview_candidate.name] = true
	          preview_order = preview_order + 1

	          local preview_required_rank = player_required_rank[preview_candidate.name]
	          if preview_required_rank == nil then
	            preview_required_rank = AutoBand.get_effective_saved_rank_requirement_for_role(preview_state.role_name_singular)
	          end
	          local preview_required_metric = player_required_metric[preview_candidate.name]
	          if not preview_required_metric then
	            preview_required_metric = AutoBand.get_rank_requirement_metric_label(preview_required_rank)
	          end
		          mark_backfill_risk(preview_candidate.name, {
		            mode = backfill_rank_enabled and "role+rank" or "role",
		            role_label = role_to_backfill_message_label(preview_state.role_name_singular),
		            needed_roles_text = backfill_needed_roles_text,
		            needed_roles_join_text = backfill_needed_join_roles_text,
		            below_rank = preview_candidate.below_rank == true,
		            blocking_required_slot = preview_blocked_slot == true,
		            required_rank = preview_required_rank,
		            required_metric = preview_required_metric,
		            rank_unknown = preview_candidate.rank_unknown == true,
		            active_count = active_player_count_after,
	            target_count = target_player_count,
	            warn = (preview_order == 1)
	          })

          preview_state.current_count = preview_state.current_count - 1
        end
      end

      tanks_t_old = build_survivor_table(tanks_t)
      healers_t_old = build_survivor_table(healers_t)
      if AutoBand.saved.dps_weighting_enabled then
        mdps_t_old = build_survivor_table(mdps_t)
        rdps_t_old = build_survivor_table(rdps_t)
        dps_t_old = {}
      else
        dps_t_old = build_survivor_table(dps_t)
        mdps_t_old = {}
        rdps_t_old = {}
      end
    else
      -- Helper function to find and mark players for kick based on role limits
      local function mark_excess_roles(role_table, old_role_table, max_allowed, role_name_plural, role_name_singular, current_count_ref)
        local current_count = current_count_ref[1]
        local kicked_count = 0 -- How many we mark in this function call

        local function was_in_old_role(player_key)
          return old_role_table and old_role_table[player_key] ~= nil or false
        end

        local function sort_newest_first(candidates)
          table.sort(candidates, function(a, b)
            local a_idx = a.arrival_idx or -1
            local b_idx = b.arrival_idx or -1
            if a_idx ~= b_idx then
              return a_idx > b_idx
            end
            return a.name < b.name
          end)
        end

        if current_count > max_allowed then
          local players_to_kick_count = current_count - max_allowed

          if promote_notice_enabled then
            local promote_arrivals = 0
            local promote_sources_guild = false
            local promote_sources_friend = false
            local off_candidates = {}

            for key, candidate_social_mode in pairs(role_table or {}) do
              if not pending_kicks[key] then
                local social_rank = get_social_priority_mode_trim_rank(candidate_social_mode)
                if social_rank <= SOCIAL_PRIORITY_MODE_ORDER[AB_const.SOCIAL_PRIORITY_MODE_OFF] then
                  off_candidates[#off_candidates + 1] = {
                    name = key,
                    arrival_idx = AutoBand.get_arrival_index(key)
                  }
                end
                if not was_in_old_role(key) and normalize_social_priority_mode(candidate_social_mode, AB_const.SOCIAL_PRIORITY_MODE_OFF) == AB_const.SOCIAL_PRIORITY_MODE_PROMOTE then
                  promote_arrivals = promote_arrivals + 1
                  if player_guild_promote_match[key] then
                    promote_sources_guild = true
                  end
                  if player_friend_promote_match[key] then
                    promote_sources_friend = true
                  end
                end
              end
            end

            sort_newest_first(off_candidates)

            local promote_kicks_to_apply = promote_arrivals
            if promote_kicks_to_apply > players_to_kick_count then
              promote_kicks_to_apply = players_to_kick_count
            end
            if promote_kicks_to_apply > #off_candidates then
              promote_kicks_to_apply = #off_candidates
            end

            if promote_kicks_to_apply > 0 then
              local source_text = build_promote_source_text(promote_sources_guild, promote_sources_friend)
	              local kick_reason = "we needed to free this " .. tostring(role_name_singular) .. " slot for a matching " .. source_text .. ". Please try again later."
	              for i = 1, promote_kicks_to_apply do
	                local candidate = off_candidates[i]
	                local kick_target = candidate and candidate.name
	                if kick_target and not pending_kicks[kick_target] then
	                  if mark_pending_kick(kick_target, kick_reason) then
	                    kicked_count = kicked_count + 1
	                  end
	                end
	              end
	              players_to_kick_count = players_to_kick_count - kicked_count
	            end
	          end

          -- Build candidate list for the non-backfill overflow path: only newly-added players
          -- for this role are eligible here.
          local candidates = {}
          local highest_social_rank = 0
          for key, candidate_social_mode in pairs(role_table or {}) do
            if not pending_kicks[key] then -- Only consider if not already marked for other reasons
              if not was_in_old_role(key) then
                local social_rank = get_social_priority_mode_trim_rank(candidate_social_mode)
                if social_rank > highest_social_rank then
                  highest_social_rank = social_rank
                end
                table.insert(candidates, {
                  name = key,
                  social_mode = normalize_social_priority_mode(candidate_social_mode, AB_const.SOCIAL_PRIORITY_MODE_OFF),
                  social_mode_rank = social_rank,
                  arrival_idx = AutoBand.get_arrival_index(key)
                })
              end
            end
          end

          -- Sort candidates:
          -- 1) lower social priority first
          -- 2) newest arrival first
          -- 3) name tie-breaker
          table.sort(candidates, function(a, b)
            local a_social = get_candidate_social_mode_rank(a)
            local b_social = get_candidate_social_mode_rank(b)
            if a_social ~= b_social then
              return a_social < b_social
            end
            local a_idx = a.arrival_idx or -1
            local b_idx = b.arrival_idx or -1
            if a_idx ~= b_idx then
              return a_idx > b_idx
            end
            return a.name < b.name
          end)

          -- Iterate through sorted candidates and mark for kick
          if players_to_kick_count > 0 then
            for _, candidate in ipairs(candidates) do
              if players_to_kick_count <= 0 then
                break
              end

              local kick_target = candidate.name
	              if not pending_kicks[kick_target] then
	                local kick_reason = "there are too many " .. role_name_plural .. " in it right now."
	                if highest_social_rank > get_candidate_social_mode_rank(candidate) then
	                  kick_reason = kick_reason .. " (social priority)."
	                end

	                if mark_pending_kick(kick_target, kick_reason) then
	                  kicked_count = kicked_count + 1
	                  players_to_kick_count = players_to_kick_count - 1
	                end
	                if players_to_kick_count <= 0 then
	                  break
	                end
	              end
	            end
	          end
        end

        -- Update the referenced count accurately based on how many were marked
        current_count_ref[1] = current_count - kicked_count

        -- Update the _old table with players *not* marked for kick
        local new_old_table = {}
        for k, v in pairs(role_table or {}) do -- Add 'or {}' for safety
          if not pending_kicks[k] then new_old_table[k] = v end
        end

        if promote_notice_enabled and current_count_ref[1] >= max_allowed then
          local newest_off = nil
          for key, candidate_social_mode in pairs(new_old_table) do
            local social_rank = get_social_priority_mode_trim_rank(candidate_social_mode)
            if social_rank <= SOCIAL_PRIORITY_MODE_ORDER[AB_const.SOCIAL_PRIORITY_MODE_OFF] then
              local arrival_idx = AutoBand.get_arrival_index(key) or -1
              if (not newest_off) or arrival_idx > newest_off.arrival_idx or (arrival_idx == newest_off.arrival_idx and key < newest_off.name) then
                newest_off = {
                  name = key,
                  arrival_idx = arrival_idx
                }
              end
            end
          end
          if newest_off and newest_off.name then
            mark_backfill_risk(newest_off.name, {
              mode = "promote",
              role_label = role_name_singular,
              promote_guild = promote_guild_enabled,
              promote_friend = promote_friend_enabled,
              warn = true
            })
          end
        end

        return new_old_table -- Return the updated _old table
      end

      -- Use the helper function (pass counts by reference using a table)
      tanks_t_old = mark_excess_roles(tanks_t, tanks_t_old, AutoBand.saved.max_tanks, "tanks", "tank", {tanks})
      healers_t_old = mark_excess_roles(healers_t, healers_t_old, AutoBand.saved.max_healers, "healers", "healer", {healers})

      if AutoBand.saved.dps_weighting_enabled then
        mdps_t_old = mark_excess_roles(mdps_t, mdps_t_old, AutoBand.saved.max_mdps, "melee dps", "mDPS", {mdpss})
        rdps_t_old = mark_excess_roles(rdps_t, rdps_t_old, AutoBand.saved.max_rdps, "ranged dps", "rDPS", {rdpss})
        dps_t_old = {}
      else
        dps_t_old = mark_excess_roles(dps_t, dps_t_old, AutoBand.saved.max_dps, "dps", "DPS", {dpss})
        mdps_t_old = {}
        rdps_t_old = {}
      end
    end
  else
    -- Clear _old tables if role composition is off to prevent stale data affecting next enable
    tanks_t_old, healers_t_old, dps_t_old, mdps_t_old, rdps_t_old = {}, {}, {}, {}, {}
  end

  if rank_only_backfill_enabled then
	    local active_player_count_rank_only = wb_player_count - pending_kick_count
	    local rank_only_target_count = 24 - rank_only_keep_open_slots
	    local players_to_kick_count = active_player_count_rank_only - rank_only_target_count
	    local rank_only_kicked_count = 0
    if players_to_kick_count > 0 then
      ensure_rank_only_backfill_sorted()

      local kicked_count = 0
      for _, candidate in ipairs(rank_only_backfill_candidates) do
        if kicked_count >= players_to_kick_count then
          break
        end

	        local kick_target = candidate.name
	        if not pending_kicks[kick_target] then
	          local candidate_required_rank = candidate.required_rank
	          if candidate_required_rank == nil then
	            candidate_required_rank = AutoBand.get_effective_saved_rank_requirement_for_role("dps")
	          end
	          local candidate_required_metric = candidate.required_metric
	          if not candidate_required_metric then
	            candidate_required_metric = AutoBand.get_rank_requirement_metric_label(candidate_required_rank)
	          end
	          local candidate_rank_text = AutoBand.format_rank_requirement_value(candidate_required_rank)
	          local kick_reason
		          if candidate.rank_unknown and candidate_required_metric == "RR" then
		            kick_reason = "we need to keep " .. tostring(rank_only_keep_open_slots) .. " slots open. " .. candidate_rank_text .. " is required and your RR is still unconfirmed. Please try again soon."
		          else
		            kick_reason = "we need to keep " .. tostring(rank_only_keep_open_slots) .. " slots open. " .. candidate_rank_text .. " is required. Please try again later."
		          end

		          if mark_pending_kick(kick_target, kick_reason) then
		            kicked_count = kicked_count + 1
		          end
		        end
	      end
      rank_only_kicked_count = kicked_count
    end

    local active_player_count_rank_only_after = active_player_count_rank_only - rank_only_kicked_count
    if active_player_count_rank_only_after < 0 then
      active_player_count_rank_only_after = 0
    end
    local rank_only_slots_until_trim = rank_only_target_count - active_player_count_rank_only_after
    if rank_only_slots_until_trim < 0 then
      rank_only_slots_until_trim = 0
    end
    if rank_only_slots_until_trim <= 2 and #rank_only_backfill_candidates > 0 then
      ensure_rank_only_backfill_sorted()
      local preview_order = 0
      for _, candidate in ipairs(rank_only_backfill_candidates) do
        if not pending_kicks[candidate.name] then
          preview_order = preview_order + 1
	          local preview_required_rank = candidate.required_rank
	          if preview_required_rank == nil then
	            preview_required_rank = AutoBand.get_effective_saved_rank_requirement_for_role("dps")
	          end
	          local preview_required_metric = candidate.required_metric
	          if not preview_required_metric then
	            preview_required_metric = AutoBand.get_rank_requirement_metric_label(preview_required_rank)
	          end
	          mark_backfill_risk(candidate.name, {
	            mode = "rank-only",
	            required_rank = preview_required_rank,
	            required_metric = preview_required_metric,
	            below_rank = true,
	            rank_unknown = candidate.rank_unknown == true,
	            active_count = active_player_count_rank_only_after,
	            target_count = rank_only_target_count,
	            warn = (preview_order == 1)
	          })
        end
      end
    end
  end

  local pending_kick_by_key = {}
  for name, _ in pairs(pending_kicks) do
    local key = AutoBand.normalize_wb_player_name(name)
    if key then
      pending_kick_by_key[key] = true
    end
  end
  AutoBand.realmrank_prune_pending_notices(
    ak_low_enforcement_enabled,
    pending_rr_notice_state,
    live_members_by_key,
    pending_kick_by_key,
    live_member_state_by_key
  )
  local risk_notice_enabled = (backfill_enabled and (role_cap_backfill_enabled or rank_only_backfill_enabled)) or promote_notice_enabled
  sync_backfill_notice_state(live_members_by_key, at_risk_by_key, pending_kick_by_key, risk_notice_enabled, live_member_state_by_key)

  -- Enqueue all pending kicks
  local kicked_any = false
  for name, reason in pairs(pending_kicks) do
    if AutoBand.enqueue_kick(name, reason, "autokick") then
      kicked_any = true
    end
  end
  return kicked_any

end

local function add_role_to_message(needed, available, singular_name_full, plural_name_full_override, message_parts)
    -- singular_name_full example: "<icon123> mdps (no wh)" or "<icon456> tank"
    -- plural_name_full_override is usually nil from current calls.

    if not (needed > 0 and available > 0) then
        return -- No spots needed or no spots available, don't add to message
    end

    local role_display_name_final

    if needed == 1 then
        role_display_name_final = singular_name_full
    else -- needed > 1, so we need a plural form (or non-plural for dps variants)
        local base_name_for_plural_logic = singular_name_full
        local suffix_text_for_plural = ""

        -- Intelligently find the suffix like " (no wh)" to separate it from the base role name
        -- This looks for the last occurrence of " (" to ensure it's a suffix pattern
        local suffix_start_position = nil
        for i = #singular_name_full - 1, 1, -1 do -- Iterate backwards
            if string.sub(singular_name_full, i, i + 1) == " (" then
                suffix_start_position = i
                break
            end
        end

        if suffix_start_position then
            base_name_for_plural_logic = string.sub(singular_name_full, 1, suffix_start_position - 1) -- e.g., "<icon> mdps" or "<icon> tank"
            suffix_text_for_plural = string.sub(singular_name_full, suffix_start_position)          -- e.g., " (no wh)"
        end

        local plural_form_of_role_name
        if plural_name_full_override then
            plural_form_of_role_name = plural_name_full_override -- Use override if provided
        else
            -- Check the end of the base_name_for_plural_logic (which has icons and role text)
            if string.match(base_name_for_plural_logic, " mdps$") or
               string.match(base_name_for_plural_logic, " rdps$") or
               string.match(base_name_for_plural_logic, " dps$") then
                plural_form_of_role_name = base_name_for_plural_logic .. suffix_text_for_plural -- No 's' added
            else
                plural_form_of_role_name = base_name_for_plural_logic .. "s" .. suffix_text_for_plural -- Add 's' for others
            end
        end
        role_display_name_final = needed .. " " .. plural_form_of_role_name
    end

    table.insert(message_parts, role_display_name_final)
end

local function strip_icon_token(icon_list, icon_token)
    if not icon_list or icon_list == "" or not icon_token or icon_token == "" then
        return icon_list or ""
    end
    if not string.find(icon_list, icon_token, 1, true) then
        return icon_list
    end
    return string.gsub(icon_list, icon_token, "")
end

local function get_race_healer_icon_to_strip_from_dps(race_icons_table)
    if not race_icons_table or not AutoBand or not AutoBand.saved then
        return nil
    end

    local alt_spec_enabled = AutoBand.saved.alt_speccheck_enabled
    if alt_spec_enabled == nil then
        alt_spec_enabled = AB_const.ALTCHECK
    end
    if alt_spec_enabled ~= true then
        return race_icons_table.healer or nil
    end

    local exclude_realm_healer_alt_spec = AutoBand.saved.exclude_realm_healer_alt_spec
    if exclude_realm_healer_alt_spec == nil then
        exclude_realm_healer_alt_spec = AB_const.EXCLUDE_REALM_HEALER_ALT_SPEC
    end
    if exclude_realm_healer_alt_spec ~= true then
        return nil
    end

    if AutoBand.faction == AB_const.ORDER and AutoBand.race == AB_const.DWARFS then
        return race_icons_table.healer or nil
    end
    if AutoBand.faction == AB_const.DESTRUCTION and AutoBand.race == AB_const.CHAOS then
        return race_icons_table.healer or nil
    end

    return nil
end

function AutoBand.GetRoleIcons(role_key, generic_mode)
    local use_race_specific_icons = false
    if not generic_mode then
        use_race_specific_icons = AutoBand.saved.restrict_same_race and
                                  AutoBand.factionDetermined and
                                  AutoBand.raceDetermined and
                                  AB_const.RACE_CAREER_ROLE_ICONS and
                                  AB_const.RACE_CAREER_ROLE_ICONS[AutoBand.faction] and
                                  AB_const.RACE_CAREER_ROLE_ICONS[AutoBand.faction][AutoBand.race]
    end

    local icons_string

    if use_race_specific_icons then
        local race_icons_table = AB_const.RACE_CAREER_ROLE_ICONS[AutoBand.faction][AutoBand.race]

        -- Start with the base icons from the static table for the requested role_key
        icons_string = race_icons_table[role_key] or ""

        -- Apply BW/Sorc as MDPS logic if the setting is enabled
        if AutoBand.saved.bw_sorc_as_mdps then
            local bw_icon_str = AB_const.ICONS.bw or ""
            local sorc_icon_str = AB_const.ICONS.sorc or ""
            local current_faction = AutoBand.faction
            local current_race = AutoBand.race

            if role_key == AB_const.MDPS then
                -- Add BW/Sorc to the MDPS string if they are not already listed (e.g. by RACE_CAREER_ROLE_ICONS)
                if current_faction == AB_const.ORDER and current_race == AB_const.EMPIRE and bw_icon_str ~= "" then
                    if not string.find(icons_string, bw_icon_str, 1, true) then
                        icons_string = icons_string .. (icons_string ~= "" and "" or "") .. bw_icon_str
                    end
                elseif current_faction == AB_const.DESTRUCTION and current_race == AB_const.DARKELVES and sorc_icon_str ~= "" then
                    if not string.find(icons_string, sorc_icon_str, 1, true) then
                        icons_string = icons_string .. (icons_string ~= "" and "" or "") .. sorc_icon_str
                    end
                end
            end
        end

        if role_key == AB_const.MDPS or role_key == AB_const.RDPS or role_key == "dps" then
            -- Keep race-restricted advertise icons aligned with the active healer alt-spec rules.
            local healer_icon_to_strip = get_race_healer_icon_to_strip_from_dps(race_icons_table)
            if healer_icon_to_strip then
                icons_string = strip_icon_token(icons_string, healer_icon_to_strip)
            end
        end

        -- Strip WH/WE if autokick_we_wh is enabled (applied AFTER BW/Sorc logic for MDPS)
        if (not generic_mode) and AutoBand.saved.autokick_we_wh_enabled and (role_key == AB_const.MDPS or role_key == "dps") then
            local temp_icons_string = icons_string
            local stripped_this_pass = false

            if AutoBand.race == AB_const.EMPIRE and AB_const.ICONS.wh and string.find(temp_icons_string, AB_const.ICONS.wh, 1, true) then
                temp_icons_string = string.gsub(temp_icons_string, AB_const.ICONS.wh, "")
                stripped_this_pass = true
            elseif AutoBand.race == AB_const.DARKELVES and AB_const.ICONS.we and string.find(temp_icons_string, AB_const.ICONS.we, 1, true) then
                temp_icons_string = string.gsub(temp_icons_string, AB_const.ICONS.we, "")
                stripped_this_pass = true
            end

            if stripped_this_pass then
                if temp_icons_string == "" and icons_string ~= "" then
                    icons_string = ""
                else
                    icons_string = temp_icons_string
                end
            end
        end

    else -- Generic icons (not race-restricted)
        if role_key == "dps" then
            icons_string = AB_const.ICONS.dps or ""
        elseif role_key == AB_const.MDPS then
             icons_string = AB_const.ICONS.mdps or AB_const.ICONS.dps or ""
        elseif role_key == AB_const.RDPS then
            icons_string = AB_const.ICONS.rdps or ""
        else
            icons_string = AB_const.ICONS[role_key] or ""
        end
    end
    return icons_string
end

function AutoBand.auto_note()
    local saved = AutoBand.saved
    if not saved.autonote_enabled then return end
    -- Channel gate first: without Region the auto-search does no work and stays silent;
    -- the Tools-tab checkbox tooltip and /ab show explain why.
    local region = AB_util.get_chat_channel(AB_util.REGION_CHANNEL_KEY)
    if not region then return end
    if AutoBand.debugon then return end
    if is_player_in_combat() then return end
    if not AutoBand.is_wb_leader() then return end
    ab_auto_note_counter = ab_auto_note_counter + 1
    if ab_auto_note_counter <= 60 then return end
    ab_auto_note_counter = 0

    local wb = AutoBand.get_wb()
    if not wb then return end
    local summary = build_wb_roster_need_summary(wb, saved)
    if not summary then return end

    local available_spots = summary.available_spots or 0
    local neededTank = summary.neededTank or 0
    local neededHealer = summary.neededHealer or 0
    local neededMdps = summary.neededMdps or 0
    local neededRdps = summary.neededRdps or 0
    local neededDps = summary.neededDps or 0
    local use_dps_weighting_for_message = summary.use_dps_weighting_for_message == true

    local parts = {}

    local stealth_suffix = ""
    if saved.autokick_we_wh_enabled then
        -- Only add the textual suffix if the warband is NOT effectively race-restricted.
        if not (saved.restrict_same_race and AutoBand.raceDetermined) then
            local stealth_icon_to_mention = ""
            -- Determine which icon to mention based on the leader's overall faction for a generic message
            if AutoBand.faction == AB_const.ORDER then
                stealth_icon_to_mention = AB_const.ICONS.wh or ""
            elseif AutoBand.faction == AB_const.DESTRUCTION then
                stealth_icon_to_mention = AB_const.ICONS.we or ""
            end

            if stealth_icon_to_mention ~= "" then
                stealth_suffix = " (no " .. stealth_icon_to_mention .. ")"
            end
        end
    end

    local tank_icons_str = AutoBand.GetRoleIcons(AB_const.TANK)
    local healer_icons_str = AutoBand.GetRoleIcons(AB_const.HEALER)

    if tank_icons_str ~= "" then add_role_to_message(neededTank, available_spots, tank_icons_str .. " tank", nil, parts) end
    if healer_icons_str ~= "" then add_role_to_message(neededHealer, available_spots, healer_icons_str .. " healer", nil, parts) end

    if use_dps_weighting_for_message then
        local mdps_icons_str = AutoBand.GetRoleIcons(AB_const.MDPS)
        local rdps_icons_str = AutoBand.GetRoleIcons(AB_const.RDPS)
        if mdps_icons_str ~= "" then add_role_to_message(neededMdps, available_spots, mdps_icons_str .. " mdps" .. stealth_suffix, nil, parts) end
        if rdps_icons_str ~= "" then add_role_to_message(neededRdps, available_spots, rdps_icons_str .. " rdps", nil, parts) end -- Typically no stealth suffix for RDPS unless specific design.
    else
        local dps_icons_str = AutoBand.GetRoleIcons("dps")
        if dps_icons_str ~= "" then add_role_to_message(neededDps, available_spots, dps_icons_str .. " dps" .. stealth_suffix, nil, parts) end
    end

    local final_parts = {}
    for _, part_text in ipairs(parts) do
        if not string.match(part_text, "^%s*+(tank|healer|mdps|rdps|dps)%s*$") or string.find(part_text, "<icon") then
            table.insert(final_parts, part_text)
        end
    end
    parts = final_parts

    if #parts > 0 and available_spots > 0 then
        local prefixicon = AB_const.ICONS.prefix or ""
        local suffixicon = AB_const.ICONS.suffix or ""
        local purpose_string = ""
        if AutoBand.current_purpose then
            purpose_string = (AB_const.WARBAND_PURPOSES[AutoBand.current_purpose].display or AutoBand.current_purpose) .. " "
        end
        local race_prefix = ""
        if saved.restrict_same_race and AutoBand.raceDetermined then
            race_prefix = AB_const.GetRaceThemePrefix(AutoBand.race)
        end

        local sep = (#parts > 1 and available_spots == 1) and " or " or " / "
        if sep == " / " then
            local need_num = false
            for _,p_text in ipairs(parts) do if p_text:match("^%d+ ") then need_num = true; break end end
            if need_num then
                for i,p_text in ipairs(parts) do
                    if not p_text:match("^%d+ ") then
                        if neededTank   == 1 and p_text:find(" tank", 1, true) then parts[i] = "1 " .. p_text
                        elseif neededHealer == 1 and p_text:find(" healer", 1, true) then parts[i] = "1 " .. p_text
                        elseif use_dps_weighting_for_message then -- Check if we are in weighted mode
                            if neededMdps == 1 and p_text:find(" mdps", 1, true) then parts[i] = "1 " .. p_text
                            elseif neededRdps == 1 and p_text:find(" rdps", 1, true) then parts[i] = "1 " .. p_text end
                        elseif neededDps == 1 and p_text:find(" dps", 1, true) then parts[i] = "1 " .. p_text end
                    end
                end
            end
        end

        local needs_prefix_text
        if AutoBand.saved.autokick_enabled then
            needs_prefix_text = AutoBand.saved.max_tanks .. "-" .. AutoBand.saved.max_healers .. "-" .. AutoBand.saved.max_dps .. " Warband needs - "
        else
            needs_prefix_text = "Warband needs - "
        end
        local payload = race_prefix .. purpose_string .. needs_prefix_text .. table.concat(parts, sep)
        local total_needed = neededTank + neededHealer
        if use_dps_weighting_for_message then
            total_needed = total_needed + neededMdps + neededRdps
        else
            total_needed = total_needed + neededDps
        end

        if total_needed > available_spots and not saved.autokick_enabled then
            payload = payload .. " - (" .. available_spots .. " spot" .. (available_spots == 1 and "" or "s") .. " available) - "
        else
            payload = payload .. " - "
        end

        local backfill_suffix = AutoBand.build_search_backfill_suffix(saved, wb)
        if backfill_suffix ~= "" then
            payload = payload .. string.sub(backfill_suffix, 4) .. " - "
        end

	        -- Only print rank requirements if low-rank autokick is enabled (i.e., rank is enforced)
	        if saved.autokick_low_rank_enabled then
	            local saved_rank_tank, saved_rank_healer, saved_rank_dps = AutoBand.get_saved_rank_requirements(saved)
	            payload = payload .. AutoBand.build_rank_requirement_text(saved_rank_tank, saved_rank_healer, saved_rank_dps, "long", {
	                show_roles = {
	                    [AB_const.TANK] = neededTank > 0,
	                    [AB_const.HEALER] = neededHealer > 0,
	                    ["dps"] = (saved.dps_weighting_enabled and ((neededMdps > 0) or (neededRdps > 0))) or (neededDps > 0),
	                }
	            })
	            local join_text = "msg/join" -- default prompt assumes a public warband
            if AutoBand.is_open_party then
                local is_public = AutoBand.is_open_party()
                if not is_public then
                    join_text = "msg"
                end
            end
            local self_name_raw = GameData.Player.name
            local self_name_str = "Leader"
            if self_name_raw then self_name_str = tostring(AutoBand.FixString(self_name_raw)) end
            local lead_color_name_self = AutoBand.saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME
            local rgb_self = AVAILABLE_COLORS[lead_color_name_self] or AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME]
            local r_self, g_self, b_self = rgb_self[1], rgb_self[2], rgb_self[3]
            local display_self = "@"..self_name_str
            local colored_link_self = string.format(
                "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
                self_name_str, r_self, g_self, b_self, display_self)
            payload = payload .. " - Please " .. join_text .. " " .. colored_link_self
        else
            if string.sub(payload, -3) == " - " then
                payload = string.sub(payload, 1, -4)
            end
            local self_name_raw = GameData.Player.name
            local self_name_str = "Leader"
            if self_name_raw then self_name_str = tostring(AutoBand.FixString(self_name_raw)) end
            local lead_color_name_self = AutoBand.saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME
            local rgb_self = AVAILABLE_COLORS[lead_color_name_self] or AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME]
            local r_self, g_self, b_self = rgb_self[1], rgb_self[2], rgb_self[3]
            local display_self = "@"..self_name_str
            local colored_link_self = string.format(
                "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
                self_name_str, r_self, g_self, b_self, display_self)
            local join_text = "msg/join" -- mirror the leader prompt for non-healers
            if AutoBand.is_open_party then
                local is_public = AutoBand.is_open_party()
                if not is_public then
                    join_text = "msg"
                end
            end
            if payload ~= "" then payload = payload .. " - Please " .. join_text .. " " .. colored_link_self
            else payload = "Please " .. join_text .. " " .. colored_link_self end
        end
        payload = payload .. AutoBand.build_search_discord_suffix()
        payload = payload .. AutoBand.build_search_priority_suffix(saved)
        AutoBand.allow_guild_prefix_override = true
        AutoBand.enqueue_command("/" .. region.number .. " " .. prefixicon .. AutoBand.GetFormattedPrefixRaw(true) .. payload .. suffixicon)
    end
end

function AutoBand.ensure_warband_before_search(args, skip_autoform)
    if not AutoBand.require_warband_features_enabled("searching for warband roles") then
        return true
    end

    if skip_autoform then
        return false
    end

    if not AutoBand.saved.autoform_search_enabled then
        return false
    end

    if is_warband_active_safe() then
        return false
    end

    local party_active = is_party_active()
    local is_party_leader = GameData and GameData.Player and GameData.Player.isGroupLeader == true
    AutoBand.pending_search_roles_args = copy_args_table(args)
    AutoBand.pending_search_roles_attempts = 0

    if party_active then
        if not is_party_leader then
            AutoBand.pending_search_roles_args = nil
            return false
        end
        AutoBand.pending_search_roles_delay = 1
        AB_util.print("Converting party to warband before searching for roles...")
        AutoBand.enqueue_command("/warbandc")
        return true
    end

    AutoBand.pending_search_roles_delay = FORM_WARBAND_DELAY_TICKS + 1
    AB_util.print("Forming warband before searching for roles...")
    AutoBand.enqueue_command("/openpartyinterest")
    AutoBand.enqueue_command("/warbandc", FORM_WARBAND_DELAY_TICKS)
    return true
end

local normalize_zone_num_value
local get_current_player_zone_num
local build_advert_zone_suffix_from_zone_num

function AutoBand.resume_pending_search_roles()
    if not AutoBand.pending_search_roles_args then
        return
    end

    if AutoBand.pending_search_roles_delay > 0 then
        return
    end

    if not is_warband_active_safe() then
        AutoBand.pending_search_roles_attempts = AutoBand.pending_search_roles_attempts + 1
        if AutoBand.pending_search_roles_attempts >= 6 then
            AB_util.print("[Error] Warband not formed after waiting. Please retry /ab searchroles.")
            AutoBand.pending_search_roles_args = nil
            AutoBand.pending_search_roles_delay = 0
            AutoBand.pending_search_roles_attempts = 0
        else
            AutoBand.pending_search_roles_delay = 1
        end
        return
    end

    local wb_obj = AutoBand.get_wb()
    if not wb_obj or wb_obj.player_count == 0 then
        AutoBand.pending_search_roles_attempts = AutoBand.pending_search_roles_attempts + 1
        if AutoBand.pending_search_roles_attempts >= 6 then
            AB_util.print("[Error] Warband data unavailable. Please retry /ab searchroles.")
            AutoBand.pending_search_roles_args = nil
            AutoBand.pending_search_roles_delay = 0
            AutoBand.pending_search_roles_attempts = 0
        else
            AutoBand.pending_search_roles_delay = 1
        end
        return
    end

    local args = AutoBand.pending_search_roles_args
    AutoBand.pending_search_roles_args = nil
    AutoBand.pending_search_roles_delay = 0
    AutoBand.pending_search_roles_attempts = 0
    AutoBand.cmd_search_roles(args, true)
end

-- Parses /ab searchroles channel tokens and resolves Region/LFG by name (slots are per
-- player). Returns region, lfg, want_t4: a channel entry when joined, false when selected
-- but not joined, nil when not selected. "1" and "5" are the legacy Region/LFG tokens.
function AutoBand.resolve_search_channels(args)
    local want_region, want_lfg, want_t4 = false, false, false
    for _, arg_val in ipairs(args or {}) do
        local c = string.lower(tostring(arg_val or ""))
        c = string.gsub(c, "/", "")
        if c == "region" or c == "1" then
            want_region = true
        elseif c == "lfg" or c == "5" then
            want_lfg = true
        elseif c == "t4" then
            want_t4 = true
        end
    end
    local region, lfg = nil, nil
    if want_region then region = AB_util.get_chat_channel(AB_util.REGION_CHANNEL_KEY) or false end
    if want_lfg then lfg = AB_util.get_chat_channel(AB_util.LFG_CHANNEL_KEY) or false end
    return region, lfg, want_t4
end

-- Joins text_fn(name) for each selected-but-missing channel; nil when none is missing.
function AutoBand.search_channels_missing_text(region, lfg, separator, text_fn)
    local text = nil
    if region == false then text = text_fn("Region") end
    if lfg == false then
        local lfg_text = text_fn("LFG")
        text = text and (text .. separator .. lfg_text) or lfg_text
    end
    return text
end

function AutoBand.build_search_roles_messages(args, opts)
    opts = opts or {}
    args = args or {}

    -- Channel gate first: nothing is read or built unless a selected channel is usable.
    local region, lfg, want_t4 = opts.region, opts.lfg, opts.want_t4
    if opts.channels_resolved ~= true then
        region, lfg, want_t4 = AutoBand.resolve_search_channels(args)
    end
    if region == nil and lfg == nil and not want_t4 then
        return nil, "no_channels"
    end
    if not region and not lfg and not want_t4 then
        return nil, "not_joined", region, lfg
    end

    if type(AutoBand.is_warband_enabled) == "function" and not AutoBand.is_warband_enabled() then
        return nil, "warband_disabled"
    end

    local saved = AutoBand.saved
    local wb_obj = opts.wb_obj or AutoBand.get_wb()
    if not wb_obj or wb_obj.player_count == 0 then
        return nil, "no_wb"
    end

    local is_current_player_leader = AutoBand.is_wb_leader()
    local generic_mode = not is_current_player_leader

    local is_wb_open = false
    if type(AutoBand.is_open_party) == "function" then
        local ok_open, open_state = pcall(AutoBand.is_open_party)
        if ok_open and open_state then
            is_wb_open = true
        end
    end

    local actual_leader_name_str = nil
    local leader_name_found = false
    local success_pu, leaderInfo = pcall(PartyUtils.GetWarbandLeader)
    if success_pu and leaderInfo and leaderInfo.name then
        actual_leader_name_str = tostring(AutoBand.FixString(leaderInfo.name))
        leader_name_found = true
    end
    if not leader_name_found then
        wb_obj:foreach_player(function(_gid, player)
            if player.isGroupLeader then
                actual_leader_name_str = tostring(AutoBand.FixString(player.name))
                leader_name_found = true
                return
            end
        end)
    end
    if not leader_name_found or not actual_leader_name_str or actual_leader_name_str == "" then
        return nil, "no_leader"
    end

    local summary = build_wb_roster_need_summary(wb_obj, saved)
    if not summary then
        return nil, "no_summary"
    end

    local warnings = {}
    local players_by_zid = AutoBand.get_players_zone(wb_obj)
    local leader_zone_name_str = "Unknown Zone/Offline"
    local leader_zone_suffix_override = nil
    local found_zone = false
    if players_by_zid and players_by_zid["valid_as"] then
        for zid, group_zone in pairs(players_by_zid["valid_as"]) do
            if found_zone then break end
            for _, pl_zone in ipairs(group_zone) do
                if pl_zone.isGroupLeader then
                    leader_zone_name_str = AB_util.get_advert_zone_name_sanitized(zid)
                    found_zone = true
                    break
                end
            end
        end
    end

    if not found_zone or leader_zone_name_str == "Offline" then
        local fallback_zone_num = get_current_player_zone_num and get_current_player_zone_num()
        if fallback_zone_num ~= nil then
            local fallback_zone_suffix, fallback_zone_name = nil, nil
            if build_advert_zone_suffix_from_zone_num then
                fallback_zone_suffix, fallback_zone_name = build_advert_zone_suffix_from_zone_num(fallback_zone_num)
            end
            if fallback_zone_suffix and fallback_zone_suffix ~= "" and fallback_zone_name and fallback_zone_name ~= "" and fallback_zone_name ~= "Offline" then
                leader_zone_name_str = fallback_zone_name
                leader_zone_suffix_override = fallback_zone_suffix
                found_zone = true
            end
        end
    end

    if not found_zone and (not players_by_zid or not players_by_zid["valid_as"]) then
        table.insert(warnings, "[Warning] Could not get zone data structure.")
    elseif not found_zone then
        table.insert(warnings, "[Warning] Could not determine leader's zone precisely.")
    end

    local neededTank = summary.neededTank or 0
    local neededHealer = summary.neededHealer or 0
    local neededMdps = summary.neededMdps or 0
    local neededRdps = summary.neededRdps or 0
    local neededDps = summary.neededDps or 0
    local available_spots = summary.available_spots or 0

    local use_dps_weighting_for_message = summary.use_dps_weighting_for_message == true
    if generic_mode then
        use_dps_weighting_for_message = false
        neededDps = math.max(0, saved.max_dps - (summary.dpss or 0))
    end

    local total_needed_spots
    if use_dps_weighting_for_message then
        total_needed_spots = neededTank + neededHealer + neededMdps + neededRdps
    else
        total_needed_spots = neededTank + neededHealer + neededDps
    end

    local message_parts = {}
    local stealth_suffix = ""
    if (not generic_mode) and saved.autokick_we_wh_enabled then
        if not (saved.restrict_same_race and AutoBand.raceDetermined) then
            local stealth_icon_to_mention = ""
            if AutoBand.faction == AB_const.ORDER then
                stealth_icon_to_mention = AB_const.ICONS.wh or ""
            elseif AutoBand.faction == AB_const.DESTRUCTION then
                stealth_icon_to_mention = AB_const.ICONS.we or ""
            end

            if stealth_icon_to_mention ~= "" then
                stealth_suffix = " (no " .. stealth_icon_to_mention .. ")"
            end
        end
    end

    local tank_icons_str = AutoBand.GetRoleIcons(AB_const.TANK, generic_mode)
    local healer_icons_str = AutoBand.GetRoleIcons(AB_const.HEALER, generic_mode)

    if tank_icons_str ~= "" then add_role_to_message(neededTank, available_spots, tank_icons_str .. " tank", nil, message_parts) end
    if healer_icons_str ~= "" then add_role_to_message(neededHealer, available_spots, healer_icons_str .. " healer", nil, message_parts) end

    if use_dps_weighting_for_message then
        local mdps_icons_str = AutoBand.GetRoleIcons(AB_const.MDPS, generic_mode)
        local rdps_icons_str = AutoBand.GetRoleIcons(AB_const.RDPS, generic_mode)
        if mdps_icons_str ~= "" then add_role_to_message(neededMdps, available_spots, mdps_icons_str .. " mdps" .. stealth_suffix, nil, message_parts) end
        if rdps_icons_str ~= "" then add_role_to_message(neededRdps, available_spots, rdps_icons_str .. " rdps", nil, message_parts) end
    else
        local dps_icons_str = AutoBand.GetRoleIcons("dps", generic_mode)
        if dps_icons_str ~= "" then add_role_to_message(neededDps, available_spots, dps_icons_str .. " dps" .. stealth_suffix, nil, message_parts) end
    end

    local final_parts = {}
    for _, part_text in ipairs(message_parts) do
        if not string.match(part_text, "^%s*+(tank|healer|mdps|rdps|dps)%s*$") or string.find(part_text, "<icon") then
            table.insert(final_parts, part_text)
        end
    end
    message_parts = final_parts

    if #message_parts == 0 or available_spots <= 0 then
        return {
            empty = true,
            warnings = warnings,
        }
    end

    local message_start, join_suffix, rank_info_str, add_prefix_str
    local prefixicon = AB_const.ICONS["prefix"] or ""
    local suffixicon = AB_const.ICONS["suffix"] or ""
    local purpose_string = ""
    local race_prefix_for_msg = ""
    local leader_race_for_theme = AutoBand.race

    if is_current_player_leader then
        if AutoBand.current_purpose and AB_const.WARBAND_PURPOSES[AutoBand.current_purpose] then
            purpose_string = (AB_const.WARBAND_PURPOSES[AutoBand.current_purpose].display or AutoBand.current_purpose) .. " "
        end
        if saved.restrict_same_race and AutoBand.raceDetermined then
            race_prefix_for_msg = AB_const.GetRaceThemePrefix(leader_race_for_theme)
        end

        if saved.autokick_enabled then
            message_start = race_prefix_for_msg .. purpose_string .. saved.max_tanks .. "-" .. saved.max_healers .. "-" .. saved.max_dps .. " Warband needs - "
        else
            message_start = race_prefix_for_msg .. purpose_string .. "Warband needs - "
        end
        local previous_prefix_override = AutoBand.allow_guild_prefix_override
        AutoBand.allow_guild_prefix_override = true
        add_prefix_str = prefixicon .. AutoBand.GetFormattedPrefixRaw(true)
        if opts.preserve_prefix_override then
            AutoBand.allow_guild_prefix_override = previous_prefix_override
        end

        local self_name_raw = GameData.Player.name
        local self_name_str_val = "Leader"
        if self_name_raw then self_name_str_val = tostring(AutoBand.FixString(self_name_raw)) end
        local lead_color_name_self = saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME
        local rgb_self = AVAILABLE_COLORS[lead_color_name_self] or AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME]
        local r_self, g_self, b_self = rgb_self[1], rgb_self[2], rgb_self[3]
        local display_self = "@" .. self_name_str_val
        local colored_link_self = string.format(
            "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
            self_name_str_val, r_self, g_self, b_self, display_self)
        local join_text = is_wb_open and "msg/join" or "msg"
        join_suffix = " - Please " .. join_text .. " " .. colored_link_self

        if saved.autokick_low_rank_enabled then
            local saved_rank_tank, saved_rank_healer, saved_rank_dps = AutoBand.get_saved_rank_requirements(saved)
            rank_info_str = " - " .. AutoBand.build_rank_requirement_text(saved_rank_tank, saved_rank_healer, saved_rank_dps, "long", {
                show_roles = {
                    [AB_const.TANK] = neededTank > 0,
                    [AB_const.HEALER] = neededHealer > 0,
                    ["dps"] = (saved.dps_weighting_enabled and ((neededMdps > 0) or (neededRdps > 0))) or (neededDps > 0),
                }
            })
        else
            rank_info_str = ""
        end
    else
        local lead_color_name = saved.lead_color_name or AB_const.DEFAULT_LEAD_COLOR_NAME
        local rgb = AVAILABLE_COLORS[lead_color_name] or AVAILABLE_COLORS[AB_const.DEFAULT_LEAD_COLOR_NAME]
        local r, g, b = rgb[1], rgb[2], rgb[3]
        local display_leader = "@" .. actual_leader_name_str
        local colored_link_leader = string.format(
            "<LINK data=\"PLAYER:%s\" color=\"%d,%d,%d\" text=\"%s\">",
            actual_leader_name_str, r, g, b, display_leader)
        message_start = prefixicon .. colored_link_leader .. " Warband needs - "
        local join_text = is_wb_open and "msg/join" or "msg"
        join_suffix = " - Please " .. join_text .. " " .. colored_link_leader
        rank_info_str = ""
        add_prefix_str = ""
    end

    local sep = (#message_parts > 1 and available_spots == 1) and " or " or " / "
    if sep == " / " then
        local needNumeric = false
        for _, p_text in ipairs(message_parts) do
            if p_text:match("^%d+ ") then
                needNumeric = true
                break
            end
        end
        if needNumeric then
            for i, p_text in ipairs(message_parts) do
                if not p_text:match("^%d+ ") then
                    if neededTank == 1 and p_text:find(" tank", 1, true) then
                        message_parts[i] = "1 " .. p_text
                    elseif neededHealer == 1 and p_text:find(" healer", 1, true) then
                        message_parts[i] = "1 " .. p_text
                    elseif use_dps_weighting_for_message then
                        if neededMdps == 1 and p_text:find(" mdps", 1, true) then
                            message_parts[i] = "1 " .. p_text
                        elseif neededRdps == 1 and p_text:find(" rdps", 1, true) then
                            message_parts[i] = "1 " .. p_text
                        end
                    elseif neededDps == 1 and p_text:find(" dps", 1, true) then
                        message_parts[i] = "1 " .. p_text
                    end
                end
            end
        end
    end

    local base = message_start .. table.concat(message_parts, sep)
    if total_needed_spots > available_spots and not saved.autokick_enabled then
        base = base .. " - (" .. available_spots .. " spot" .. (available_spots == 1 and "" or "s") .. " available)"
    end

    local discord_req_suffix = AutoBand.build_search_discord_suffix()
    local priority_suffix = AutoBand.build_search_priority_suffix(saved)
    local backfill_suffix = ""
    if is_current_player_leader then
        backfill_suffix = AutoBand.build_search_backfill_suffix(saved, wb_obj)
    end
    local zone_suffix = leader_zone_suffix_override or ""
    if zone_suffix == "" and leader_zone_name_str and leader_zone_name_str ~= "" and leader_zone_name_str ~= "Offline" then
        zone_suffix = " - in - " .. leader_zone_name_str
    end
    local payload_t4 = base .. zone_suffix .. backfill_suffix .. rank_info_str .. join_suffix .. discord_req_suffix .. priority_suffix
    local payload_1 = base .. backfill_suffix .. rank_info_str .. join_suffix .. discord_req_suffix .. priority_suffix

    -- Region and LFG were resolved by name at the gate above; missing ones are skipped.
    local messages = {}
    local feedback = {}
    if region then
        local chan_cmd = "/" .. region.number
        table.insert(messages, { channel = chan_cmd, cmd = chan_cmd .. " " .. add_prefix_str .. payload_1 .. suffixicon })
        table.insert(feedback, "Region (" .. chan_cmd .. ")")
    end
    if lfg then
        local chan_cmd = "/" .. lfg.number
        table.insert(messages, { channel = chan_cmd, cmd = chan_cmd .. " " .. add_prefix_str .. payload_t4 .. suffixicon })
        table.insert(feedback, "LFG (" .. chan_cmd .. ")")
    end
    if want_t4 then
        table.insert(messages, { channel = "/t4", cmd = "/t4 " .. add_prefix_str .. payload_t4 .. suffixicon })
        table.insert(feedback, "/t4")
    end

    return {
        messages = messages,
        feedback = feedback,
        warnings = warnings,
        region = region,
        lfg = lfg,
    }
end

-- opts.channel_reason(name): wording for a missing channel (the settings tooltip
-- passes its short form); defaults to the chat wording.
function AutoBand.build_search_roles_preview_text(args, opts)
    local channel_reason = type(opts) == "table" and type(opts.channel_reason) == "function" and opts.channel_reason or
        AB_util.chat_channel_requirement_text
    local function tooltip_preview_text(text)
        local s = tostring(text or "")
        s = string.gsub(s, '%<LINK[^>]-text="([^"]*)"[^>]*%>', "%1")
        s = string.gsub(s, "%s+", " ")
        s = string.gsub(s, "^%s*(.-)%s*$", "%1")
        return s
    end

    local result, reason, missing_region, missing_lfg = AutoBand.build_search_roles_messages(args, { preserve_prefix_override = true })
    if not result then
        if reason == "not_joined" then
            return "Search preview unavailable:\n" ..
                AutoBand.search_channels_missing_text(missing_region, missing_lfg, "\n", channel_reason)
        elseif reason == "warband_disabled" then
            return "Search preview unavailable:\nWarband features are off."
        elseif reason == "no_wb" then
            return "Search preview unavailable:\nNot in a warband (or turn on Autoform)."
        elseif reason == "no_channels" then
            return "Search preview unavailable:\nSelect at least one search channel."
        elseif reason == "no_leader" then
            return "Search preview unavailable:\nCould not determine the WB leader."
        elseif reason == "no_summary" then
            return "Search preview unavailable:\nCould not summarize the current WB."
        end
        return "Search preview unavailable."
    end

    if result.empty then
        return "Search preview unavailable:\nWarband is full or no roles needed."
    end

    local messages = result.messages or {}
    local channels = result.feedback or {}
    local lines = {
        "Search preview:",
        "Channels: " .. table.concat(channels, ", "),
    }
    local missing_text = AutoBand.search_channels_missing_text(result.region, result.lfg, "\n", channel_reason)
    if missing_text then
        table.insert(lines, missing_text)
    end
    if messages[1] then
        local preview = tooltip_preview_text(messages[1].cmd)
        preview = string.gsub(preview, "^/%w+%s+", "")
        table.insert(lines, preview)
    end
    return table.concat(lines, "\n")
end

function AutoBand.cmd_search_roles(args, skip_autoform)
    -- Channel gate first: with no usable channel nothing is formed, kicked, built or queued.
    args = args or {}
    local region, lfg, want_t4 = AutoBand.resolve_search_channels(args)
    if region == nil and lfg == nil and not want_t4 then
        AB_util.print("Usage: /ab searchroles <region|t4|lfg>")
        AB_util.print("Please specify at least one channel (region, t4, lfg).")
        return
    end
    if not region and not lfg and not want_t4 then
        AB_util.print(AutoBand.search_channels_missing_text(region, lfg, " ", AB_util.chat_channel_not_joined_text))
        return
    end

    if not AutoBand.require_warband_features_enabled("searching for warband roles") then
        return
    end

    if AutoBand.ensure_warband_before_search(args, skip_autoform) then
        return
    end

    local wb_obj = AutoBand.get_wb()
    if not wb_obj or wb_obj.player_count == 0 then
        local hint
        if AutoBand.saved.autoform_search_enabled then
            hint = " Rerun this command to auto-form one (party leader or solo)."
        else
            hint = " Start a WB first (or enable autoform in Tools to auto-form one)."
        end
        AB_util.print("[Error] Not currently in an active WB." .. hint)
        return
    end

    if AutoBand.is_wb_leader() then
        AutoBand.auto_kick()
    end

    local result, reason = AutoBand.build_search_roles_messages(args, {
        wb_obj = wb_obj, channels_resolved = true, region = region, lfg = lfg, want_t4 = want_t4,
    })
    if not result then
        if reason == "no_leader" then
            AB_util.print("[Error] Could not determine the warband leader's name.")
        elseif reason == "no_summary" then
            AB_util.print("[Error] Could not summarize the current warband.")
        elseif reason == "warband_disabled" then
            AB_util.print("AutoBand warband features are disabled. Use /ab enable before searching for warband roles.")
        else
            AB_util.print("[Error] Could not build the search message.")
        end
        return
    end

    if result.empty then
        AB_util.print("Warband is full or no roles needed.")
        return
    end

    for _, warning in ipairs(result.warnings or {}) do
        AB_util.print(warning)
    end
    -- One reply per typed command for selected channels that were skipped.
    local missing_text = AutoBand.search_channels_missing_text(region, lfg, " ", AB_util.chat_channel_not_joined_text)
    if missing_text then
        AB_util.print(missing_text)
    end
    for _, item in ipairs(result.messages or {}) do
        AutoBand.enqueue_command(item.cmd)
    end
    AB_util.print("Search sent in " .. table.concat(result.feedback or {}, ", ") .. ".")
end

function AutoBand.wb(_args)
    local wb_obj = AutoBand.get_wb()
    local tanks, healers, dpss, mdps, rdps, w_wh = 0, 0, 0, 0, 0, 0
    local rr_state = AutoBand.realmrank_create_wb_average_state()
    local guild_member_count = 0
    local guild_members_in_wb = {}
    local guild_member_names = {}

    AutoBand.realmrank_seed_wb_snapshot()

    local guild_member_data = GetGuildMemberData() or {}
    for _, value in pairs(guild_member_data) do
        if value and value.name then
            table.insert(guild_member_names, value.name)
        end
    end

    wb_obj:foreach_player(
        function(_gid, player)
            if (player.role == "tank") then
                tanks = tanks + 1
            elseif (player.role == "healer") then
                healers = healers + 1
            elseif (player.role == "mdps") then
                mdps = mdps + 1
                dpss = dpss + 1
            elseif (player.role == "rdps") then
                rdps = rdps + 1
                dpss = dpss + 1
            end

            if (player.careerLine == GameData.CareerLine.WITCH_ELF or player.careerLine == GameData.CareerLine.WITCH_HUNTER) then
                w_wh = w_wh + 1
            end

            AutoBand.realmrank_accumulate_wb_average(rr_state, player)

            for _, value in pairs(guild_member_names) do
                if value:match(L"([^^]+)^?([^^]*)") == player.name then
                    guild_member_count = guild_member_count + 1
                    table.insert(guild_members_in_wb, player.name)
                    break
                end
            end
        end
    )

    AB_util.print("Tanks in WB: " .. tanks)
    AB_util.print("Healers in WB: " .. healers)
    AB_util.print("DPSs in WB: " .. dpss .. " - " .. mdps .." MDPS, " .. rdps .. " RDPS.")
    local wb_average_rr = AutoBand.realmrank_get_wb_average(rr_state)
    if wb_average_rr ~= nil then
        AB_util.print(string.format("Average RR in WB: %.1f", wb_average_rr))
    end
    local can_show_backfill_route = false
    if AutoBand.is_wb_leader then
        local ok_lead, is_lead = pcall(AutoBand.is_wb_leader)
        if ok_lead and is_lead then
            can_show_backfill_route = true
        end
    end
    if can_show_backfill_route then
        local route_members, route_mode = AutoBand.get_backfill_route_members(wb_obj)
        if route_mode == "disabled" then
            AB_util.print("Trim order: off.")
        elseif route_mode == "idle" then
            AB_util.print("Trim order: inactive (enable /ab ak or /ab akl).")
        else
            AB_util.print("Trim order (" .. route_mode .. "): " .. AutoBand.format_backfill_route_members(route_members, 12))
        end
    end
    AB_util.print("Guild members (including you) in WB: " .. guild_member_count)
    for _, value in pairs(guild_members_in_wb) do
        AB_util.print(tostring(value))
    end
end

function AutoBand.get_players_zone(wb_obj)
    local zids = { ["valid_as"] = {}, ["valid_p"] = {}, ["valid_safe"] = {} }
    local leader_zone = nil

    wb_obj:foreach_player(
        function(_gid, player)
            if (player.isGroupLeader or player.isAssistant) then
                if (zids["valid_as"][player.zoneNum] == nil) then
                    zids["valid_as"][player.zoneNum] = {}
                end
                if (player.isGroupLeader) then
                    leader_zone = player.zoneNum
                    table.insert(zids["valid_as"][player.zoneNum], 1, player)
                else
                    table.insert(zids["valid_as"][player.zoneNum], player)
                end
            end
        end
    )

    if (leader_zone) then
        zids["valid_safe"] = get_safe_lead_assist_zone_set(zids["valid_as"])
        zids["other"] = {}
        wb_obj:foreach_player(
            function(_gid, player)
                if (zids["valid_safe"][player.zoneNum]) then
                    if (zids["valid_p"][player.zoneNum] == nil) then
                        zids["valid_p"][player.zoneNum] = {}
                    end
                    table.insert(zids["valid_p"][player.zoneNum], player)
                else
                    if (zids["other"][player.zoneNum] == nil) then
                        zids["other"][player.zoneNum] = {}
                    end
                    table.insert(zids["other"][player.zoneNum], player)
                end
            end
        )
    else
        AB_util.print("[ERROR] Leader cannot be found, the warband is BUGGED, reform a warband")
    end
    return zids
end

function AutoBand.get_fakewb(template)
    template = AutoBand.template_get_layout(template)
    local wb = AB_wb:new()
    wb:set_groups()
    local num_players = 1
    for gid, tgroup in ipairs(template) do
        for _, tplayer in ipairs(tgroup) do
            wb:add_to_gid(tplayer.role, num_players, gid)
            num_players = num_players + 1
        end
    end
    wb:recalc_counters()
    wb:print()
    return wb
end

function AutoBand.FixString(str)
    if (str == nil) then
        return nil
    end
    local pos = str:find(L"^", 1, true)
    if (pos) then
        str = str:sub(1, pos - 1)
    end
    return str
end

function AutoBand.cmd_end(_args)
    if not AutoBand.require_warband_features_enabled("ending the warband") then
        return
    end

    AutoBand.clear_partynote_if_autoband()
    local wb_obj = AutoBand.get_wb()
    wb_obj:foreach_player(
        function(_gid, player)
            AutoBand.enqueue_kick(player.name, "it ended, see you next time!")
        end
    )
    AutoBand.queue_group_leave_broadcast()
end

normalize_zone_num_value = function(raw)
    if type(raw) == "number" then
        if raw >= 0 then
            return math.floor(raw)
        end
        return nil
    end

    if type(raw) == "string" and raw ~= "" then
        local parsed = tonumber(raw)
        if parsed and parsed >= 0 then
            return math.floor(parsed)
        end
    end

    return nil
end

get_current_player_zone_num = function()
    if not GameData or type(GameData) ~= "table" then
        return nil
    end

    local player = GameData.Player
    if type(player) ~= "table" then
        return nil
    end

    local zone_num = normalize_zone_num_value(player.zoneNum)
    if zone_num ~= nil then
        return zone_num
    end

    zone_num = normalize_zone_num_value(player.zone)
    if zone_num ~= nil then
        return zone_num
    end

    zone_num = normalize_zone_num_value(player.Zone)
    if zone_num ~= nil then
        return zone_num
    end

    local zone_keys = { "zoneNum", "zoneId", "zoneID", "id" }
    local zone_candidates = {}
    if type(player.zone) == "table" then
        table.insert(zone_candidates, player.zone)
    end
    if type(player.Zone) == "table" then
        table.insert(zone_candidates, player.Zone)
    end
    for _, zone_data in ipairs(zone_candidates) do
        if type(zone_data) == "table" then
            for _, key in ipairs(zone_keys) do
                zone_num = normalize_zone_num_value(zone_data[key])
                if zone_num ~= nil then
                    return zone_num
                end
            end
        end
    end

    return nil
end

build_advert_zone_suffix_from_zone_num = function(zone_num)
    local zone_name = AB_util.get_advert_zone_name_sanitized(zone_num)
    if zone_name and zone_name ~= "" and zone_name ~= "Offline" then
        return " - in - " .. zone_name, zone_name
    end
    return "", nil
end

function AutoBand.cmd_advert_zone(args)
    local zone_num
    if args and args[1] ~= nil and tostring(args[1]) ~= "" then
        zone_num = normalize_zone_num_value(args[1])
        if zone_num == nil then
            AB_util.print("[Error] Usage: /ab adzone [zoneId]")
            return
        end
    else
        zone_num = get_current_player_zone_num()
        if zone_num == nil then
            AB_util.print("[Debug] Current player zone is unavailable. Try /ab dumpplayer.")
            return
        end
    end

    local zone_suffix = build_advert_zone_suffix_from_zone_num(zone_num)
    if zone_suffix ~= "" then
        AB_util.print("[Debug] Advert zone suffix: " .. zone_suffix .. " (zone #" .. tostring(zone_num) .. ")")
        return
    end

    AB_util.print("[Debug] Advert zone suffix omitted (no valid zone).")
end

function AutoBand.cmd_dump_player_data(_args)
    AB_util.print("--- Dumping GameData.Player ---")
    -- Basic safety checks
    if not GameData or type(GameData) ~= "table" then
        AB_util.print("[Error] GameData object is not available or not a table.")
        AB_util.print("--- End GameData.Player Dump ---")
        return
    end
     if not GameData.Player or type(GameData.Player) ~= "table" then
         AB_util.print("[Error] GameData.Player is not available or not a table.")
         AB_util.print("Available keys directly under GameData:")
         -- Attempt to print top-level keys of GameData if Player is missing
         local game_data_keys = {}
         for k, _ in pairs(GameData) do
             table.insert(game_data_keys, tostring(k))
         end
         table.sort(game_data_keys)
         if #game_data_keys > 0 then
              AB_util.print("  " .. table.concat(game_data_keys, ", "))
         else
              AB_util.print("  (Could not list keys)")
         end
         AB_util.print("--- End GameData.Player Dump ---")
         return
     end

    -- Call the recursive dump function, wrapped in pcall for overall safety
    local success, err = pcall(AB_util.dump_recursive, GameData.Player, "  ") -- Start with indentation
     if not success then
         AB_util.print("[Error] An error occurred during the dump process: " .. tostring(err))
     end

    AB_util.print("--- End GameData.Player Dump ---")
end

function AutoBand.cmd_dump_guild_data(_args)
    AB_util.print("--- Dumping GameData.Guild ---")
    -- Basic safety checks
    if not GameData or type(GameData) ~= "table" then
        AB_util.print("[Error] GameData object is not available or not a table.")
        AB_util.print("--- End GameData.Guild Dump ---")
        return
    end
     if not GameData.Guild or type(GameData.Guild) ~= "table" then
         AB_util.print("[Error] GameData.Guild is not available or not a table.")
         AB_util.print("Available keys directly under GameData:")
         -- Attempt to print top-level keys of GameData if Guild is missing
         local game_data_keys = {}
         for k, _ in pairs(GameData) do
             table.insert(game_data_keys, tostring(k))
         end
         table.sort(game_data_keys)
         if #game_data_keys > 0 then
              AB_util.print("  " .. table.concat(game_data_keys, ", "))
         else
              AB_util.print("  (Could not list keys)")
         end
         AB_util.print("--- End GameData.Guild Dump ---")
         return
     end

    -- Call the recursive dump function, wrapped in pcall for overall safety
    local success, err = pcall(AB_util.dump_recursive, GameData.Guild, "  ") -- Start with indentation
     if not success then
         AB_util.print("[Error] An error occurred during the dump process: " .. tostring(err))
     end

    AB_util.print("--- End GameData.Guild Dump ---")
end

function AutoBand.cmd_dump_warband_data(_args)
    AB_util.print("--- Dumping GetBattlegroupMemberData() (Raw Warband/Battlegroup Data) ---")

    -- Directly call the game API function
    local raw_warband_data = GetBattlegroupMemberData()

    if not raw_warband_data then
        AB_util.print("[Error] GetBattlegroupMemberData() returned nil or no data.")
    elseif type(raw_warband_data) ~= "table" then
        AB_util.print("[Error] GetBattlegroupMemberData() did not return a table. Type: " .. type(raw_warband_data) .. ", Value: " .. tostring(raw_warband_data))
    else
        if next(raw_warband_data) == nil then -- Check if the table is empty
             AB_util.print("(GetBattlegroupMemberData() returned an empty table - likely not in a warband)")
        else
            -- Call the recursive dump function, wrapped in pcall for overall safety
            local success, err = pcall(AB_util.dump_recursive, raw_warband_data, "  ", 0, 7) -- Explicitly pass depth and max_depth
            if not success then
                AB_util.print("[Error] An error occurred during the raw warband data dump process: " .. tostring(err))
            end
        end
    end
    AB_util.print("--- End GetBattlegroupMemberData() Dump ---")
end

function AutoBand.cmd_dump_party_data(_args)
  AB_util.print("--- Dumping PartyUtils.GetPartyData() ---")

  -- Directly call the game API function you requested
  local party_data = PartyUtils.GetPartyData()

  if not party_data then
    AB_util.print("[Info] PartyUtils.GetPartyData() returned nil. (Not in a party)")
  elseif type(party_data) ~= "table" then
    AB_util.print("[Error] PartyUtils.GetPartyData() did not return a table. Type: " .. type(party_data) .. ", Value: " .. tostring(party_data))
  else
    if next(party_data) == nil then -- Check if the table is empty
      AB_util.print("(PartyUtils.GetPartyData() returned an empty table)")
    else
      -- Call the addon's existing recursive dump function for nice formatting
      local success, err = pcall(AB_util.dump_recursive, party_data, "  ", 0, 7)
      if not success then
        AB_util.print("[Error] An error occurred during the party data dump process: " .. tostring(err))
      end
    end
  end
  AB_util.print("--- End PartyUtils.GetPartyData() Dump ---")
end

function AutoBand.cmd_dump_ignore_list(_args)
    AB_util.print("--- Dumping Ignore List ---")

    -- Get the ignore list from the game's API
    local ignore_list = GetIgnoreList()

    -- Check if the API returned anything valid
    if not ignore_list or type(ignore_list) ~= "table" then
        AB_util.print(L"[Error] GetIgnoreList() returned nil or is not a table.")
        AB_util.print(L"--- End Ignore List Dump ---")
        return
    end

    -- Check if the returned list is empty
    if next(ignore_list) == nil then
        AB_util.print(L"(Ignore list is empty)")
    else
        AB_util.print(L"Found " .. towstring(#ignore_list) .. L" entries. Dumping recursively:")
        -- Use the existing recursive dump utility for maximum detail.
        -- This will show the exact structure and content of the list.
        local success, err = pcall(AB_util.dump_recursive, ignore_list, "  ")
        if not success then
            AB_util.print(L"[Error] An error occurred during the dump process: " .. tostring(err))
        end
    end

    AB_util.print(L"--- End Ignore List Dump ---")
end

function AutoBand.cmd_dump_social_cache(args)
    local targets = ab_social_list_parse_debug_targets(args)
    if targets == nil then
        AB_util.print("Usage: /ab socialcache [guild|friends|ignore|all]")
        return
    end

    AB_util.print("[Debug] AutoBand social cache uses normalized lowercase names.")
    for i = 1, #targets do
        ab_social_list_print_cache_debug(targets[i])
    end
end

function AutoBand.cmd_refresh_social_cache(args)
    local targets = ab_social_list_parse_debug_targets(args)
    if targets == nil then
        AB_util.print("Usage: /ab socialrefresh [guild|friends|ignore|all]")
        return
    end

    for i = 1, #targets do
        local list_key = targets[i]
        local getter = ab_social_list_get_membership_getter(list_key)
        if getter ~= nil then
            ab_social_list_mark_cache_dirty(list_key)
            getter()
        end
        ab_social_list_print_cache_debug(list_key)
    end
end

local function resolve_open_flag(candidate)
    if type(candidate) ~= "table" then
        return nil
    end

    local keys = {
        "openParty",
        "openWarband",
        "isOpenParty",
        "isPublic",
        "isWarbandPublic",
        "isPartyPublic",
    }

    for i = 1, #keys do
        local flag = candidate[keys[i]]
        if type(flag) == "boolean" then
            return flag, keys[i]
        end
    end

    return nil
end

local function note_to_string(note_raw)
    if note_raw == nil then
        return nil
    end
    if type(note_raw) == "string" then
        return note_raw
    end
    if type(WStringToString) == "function" then
        local ok_ws, ws_val = pcall(WStringToString, note_raw)
        if ok_ws and ws_val then
            return ws_val
        end
    end
    local ok_str, str_val = pcall(tostring, note_raw)
    if ok_str and str_val then
        return str_val
    end
    return nil
end

local function note_is_blank(note_raw)
    if note_raw == nil then
        return true
    end
    if note_raw == "" or note_raw == L"" then
        return true
    end
    local note_str = note_to_string(note_raw)
    if not note_str or note_str == "" then
        return true
    end
    return false
end

local function normalize_note_text(note_raw)
    local note_str = note_to_string(note_raw)
    if not note_str then
        return nil
    end
    note_str = string.gsub(note_str, "%s+", " ")
    note_str = string.gsub(note_str, "^%s*(.-)%s*$", "%1")
    if note_str == "" then
        return nil
    end
    return note_str
end

local function note_contains_autoband(note_raw)
    local note_norm = normalize_note_text(note_raw)
    if not note_norm then
        return false
    end
    return string.find(note_norm, "[AutoBand]", 1, true) ~= nil
        or string.find(note_norm, "[AB BackFill]", 1, true) ~= nil
        or string.find(note_norm, "[AB]", 1, true) ~= nil
end

local function strip_trailing_partial_tag(note_str)
    if not note_str then
        return nil
    end
    local last_lt = nil
    local search_pos = 1
    while true do
        local lt = string.find(note_str, "<", search_pos, true)
        if not lt then
            break
        end
        last_lt = lt
        search_pos = lt + 1
    end
    if not last_lt then
        return note_str
    end
    if string.find(note_str, ">", last_lt, true) then
        return note_str
    end
    return string.sub(note_str, 1, last_lt - 1)
end

local function truncate_note_text(note_str, max_len)
    if not note_str then
        return nil
    end
    if max_len == nil then
        return note_str
    end
    if #note_str <= max_len then
        return note_str
    end
    if max_len <= 0 then
        return ""
    end
    local truncated = strip_trailing_partial_tag(string.sub(note_str, 1, max_len))
    if not truncated or truncated == "" then
        return truncated
    end

    local last_char = string.sub(truncated, #truncated, #truncated)
    local next_char = string.sub(note_str, #truncated + 1, #truncated + 1)
    local cut_inside_word =
        last_char ~= nil and last_char ~= "" and
        next_char ~= nil and next_char ~= "" and
        string.find(last_char, "%w") ~= nil and
        string.find(next_char, "%w") ~= nil

    if not cut_inside_word then
        return truncated
    end

    local i = #truncated
    while i > 0 do
        local ch = string.sub(truncated, i, i)
        if ch == " " or ch == "/" or ch == "-" or ch == "," or ch == ":" then
            truncated = string.sub(truncated, 1, i - 1)
            break
        end
        i = i - 1
    end

    while #truncated > 0 do
        local ch = string.sub(truncated, #truncated, #truncated)
        if ch == " " or ch == "/" or ch == "-" or ch == "," or ch == ":" then
            truncated = string.sub(truncated, 1, #truncated - 1)
        else
            break
        end
    end

    return truncated
end

AutoBand.truncate_note_text = truncate_note_text

local function collect_wb_leader_names(wbdata, leader_info)
    local names = {}
    local function add_name(name_raw)
        local normalized = normalize_name_lowercase(name_raw)
        if not normalized then
            return
        end
        for i = 1, #names do
            if names[i] == normalized then
                return
            end
        end
        table.insert(names, normalized)
    end

    if GameData and GameData.Player and GameData.Player.isGroupLeader == true and GameData.Player.name then
        add_name(GameData.Player.name)
    end

    if type(leader_info) == "table" then
        add_name(leader_info.name)
        add_name(leader_info.leaderName)
    elseif PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
        local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
        if ok_leader and leader then
            add_name(leader.name)
            add_name(leader.leaderName)
        end
    end

    if type(wbdata) ~= "table" and type(GetBattlegroupMemberData) == "function" then
        local ok_wb, wb_data = pcall(GetBattlegroupMemberData)
        if ok_wb and type(wb_data) == "table" then
            wbdata = wb_data
        end
    end

    if type(wbdata) == "table" then
        for _, party in ipairs(wbdata) do
            if type(party) == "table" and type(party.players) == "table" then
                for _, member in ipairs(party.players) do
                    if member and member.isGroupLeader and member.name then
                        add_name(member.name)
                        break
                    end
                end
            end
        end
    end

    return names
end

local function find_open_party_listing_for_leader(names, open_party_list)
    if type(names) ~= "table" or #names == 0 then
        return nil, "no leader names collected"
    end

    local list = open_party_list
    if type(list) ~= "table" then
        if type(GetOpenPartyFullList) ~= "function" then
            return nil, "GetOpenPartyFullList unavailable"
        end

        local ok_list, fetched_list = pcall(GetOpenPartyFullList)
        if not ok_list or type(fetched_list) ~= "table" then
            return nil, "GetOpenPartyFullList invalid"
        end
        list = fetched_list
    end

    for idx, entry in ipairs(list) do
        if type(entry) == "table" then
            local entry_name = normalize_name_lowercase(entry.leaderName or entry.name)
            if entry_name then
                for _, target_name in ipairs(names) do
                    if target_name == entry_name then
                        local label = "OpenPartyList[" .. tostring(idx) .. "]"
                        if entry.isWarband == true then
                            label = label .. ":warband"
                        end
                        return entry, label
                    end
                end
            end
        end
    end

    return nil, "leader not present in OpenPartyList"
end

local function check_open_party_listing_for_leader(names, open_party_list)
    local entry, label = find_open_party_listing_for_leader(names, open_party_list)
    if entry then
        return true, label
    end
    return false, label
end

local function is_open_party_note_source(source)
    return type(source) == "string" and string.find(source, "OpenPartyList", 1, true) == 1
end

local function build_open_party_state_snapshot(opts)
    opts = type(opts) == "table" and opts or {}

    local snapshot = {
        _autoband_open_party_snapshot = true,
        is_open = false,
        open_reason = nil,
        current_note = nil,
        current_note_source = nil,
        listing_note = nil,
        listing_note_source = nil,
        leader_names = nil,
        listing_entry = nil,
        listing_label = nil,
    }

    local leader_info = opts.leader_info
    if leader_info == nil and PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
        local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
        if ok_leader and type(leader) == "table" then
            leader_info = leader
        end
    end

    if GameData and GameData.Player and GameData.Player.Group then
        local group = GameData.Player.Group
        if not note_is_blank(group.partyNote) then
            snapshot.current_note = group.partyNote
            snapshot.current_note_source = "group.partyNote"
        elseif group.Settings and not note_is_blank(group.Settings.partyNote) then
            snapshot.current_note = group.Settings.partyNote
            snapshot.current_note_source = "group.Settings.partyNote"
        end

        if group.Settings and type(group.Settings.isPublic) == "boolean" and group.Settings.isPublic == true then
            snapshot.is_open = true
            snapshot.open_reason = "GameData.Player.Group.Settings.isPublic"
        end
    end

    if type(leader_info) == "table" then
        local leader_flag, leader_key = resolve_open_flag(leader_info)
        if leader_flag == true and not snapshot.is_open then
            snapshot.is_open = true
            snapshot.open_reason = "WarbandLeader." .. tostring(leader_key or "flag")
        end
    end

    if not snapshot.is_open then
        local warband = opts.wbdata
        if type(warband) ~= "table" and PartyUtils and type(PartyUtils.GetWarbandData) == "function" then
            local ok_wb, fetched_warband = pcall(PartyUtils.GetWarbandData)
            if ok_wb and type(fetched_warband) == "table" then
                warband = fetched_warband
            end
        end
        if type(warband) == "table" then
            for p_idx, party in ipairs(warband) do
                if type(party) == "table" then
                    local settings = party.settings or party.Settings
                    if settings and type(settings.isPublic) == "boolean" and settings.isPublic == true then
                        snapshot.is_open = true
                        snapshot.open_reason = "party[" .. tostring(p_idx) .. "].settings.isPublic"
                        break
                    end

                    local party_flag, key = resolve_open_flag(party)
                    if party_flag == true then
                        snapshot.is_open = true
                        snapshot.open_reason = "party[" .. tostring(p_idx) .. "]." .. tostring(key or "flag")
                        break
                    end

                    if type(party.players) == "table" then
                        for m_idx, member in ipairs(party.players) do
                            local member_flag, member_key = resolve_open_flag(member)
                            if member_flag == true then
                                snapshot.is_open = true
                                snapshot.open_reason = "party[" .. tostring(p_idx) .. "].players[" .. tostring(m_idx) .. "]." .. tostring(member_key or "flag")
                                break
                            end
                        end
                    end
                end

                if snapshot.is_open then
                    break
                end
            end
        end
    end

    local need_listing =
        opts.include_listing == true or
        snapshot.current_note == nil or
        snapshot.is_open ~= true

    if not need_listing then
        return snapshot
    end

    snapshot.leader_names = collect_wb_leader_names(opts.wbdata, leader_info)
    local entry, label = find_open_party_listing_for_leader(snapshot.leader_names, opts.open_party_list)
    snapshot.listing_entry = entry
    snapshot.listing_label = label

    if entry then
        if not snapshot.is_open then
            snapshot.is_open = true
            snapshot.open_reason = label or "OpenPartyList"
        end
        if not note_is_blank(entry.partyNote) then
            snapshot.listing_note = entry.partyNote
            if label then
                snapshot.listing_note_source = label .. ".partyNote"
            else
                snapshot.listing_note_source = "OpenPartyList.partyNote"
            end
            if snapshot.current_note == nil then
                snapshot.current_note = snapshot.listing_note
                snapshot.current_note_source = snapshot.listing_note_source
            end
        end
    end

    return snapshot
end

local function get_open_party_request_all_type()
    if not GameData or type(GameData) ~= "table" then
        return nil
    end

    local request_types = GameData.OpenPartyRequestType
    if type(request_types) ~= "table" then
        return nil
    end

    return request_types.ALL
end

function AutoBand.get_current_party_note(snapshot)
    if type(snapshot) ~= "table" or snapshot._autoband_open_party_snapshot ~= true then
        snapshot = build_open_party_state_snapshot(snapshot)
    end
    return snapshot.current_note, snapshot.current_note_source
end

function AutoBand.request_partynote_live_verify()
    if AutoBand.pending_partynote_live_verify == true then
        return false
    end
    if AutoBand.pending_group_leave_broadcast then
        return false
    end
    if type(SendOpenPartySearchRequest) ~= "function" then
        return false
    end

    local request_type = get_open_party_request_all_type()
    if request_type == nil then
        return false
    end

    AutoBand.pending_partynote_live_verify = true
    AutoBand.pending_partynote_live_verify_ticks = PARTYNOTE_OPENPARTY_VERIFY_TIMEOUT_TICKS
    local ok_request = pcall(SendOpenPartySearchRequest, request_type)
    if not ok_request then
        clear_partynote_live_verify_state()
        return false
    end

    return true
end

function AutoBand.verify_partynote_live_listing()
    local saved = AutoBand.saved
    if not saved or not saved.autopartynote_enabled then
        return
    end
    if AutoBand.pending_group_leave_broadcast then
        return
    end
    if AutoBand.debugon then
        return
    end
    if not AutoBand.is_wb_leader() then
        return
    end

    local in_combat = is_player_in_combat()
    local suppress_ticks = PARTYNOTE_SUPPRESS_TICKS
    if in_combat then
        suppress_ticks = PARTYNOTE_IN_COMBAT_TICKS
    end

    local live_wbdata, live_roster_signature, alt_lookup, live_alt_signature = get_partynote_live_context(true)
    local party_state = build_open_party_state_snapshot({
        wbdata = live_wbdata,
        include_listing = true,
    })
    if party_state.is_open ~= true then
        AutoBand.partynote_state_dirty = false
        return
    end

    local roster_changed = live_roster_signature ~= AutoBand.party_note_last_roster_signature
    local alt_changed = live_alt_signature ~= AutoBand.party_note_last_alt_signature
    if roster_changed or alt_changed then
        AutoBand.cache_dirty = true
    end

    local wb = AutoBand.get_wb(live_wbdata, {
        roster_signature = live_roster_signature,
        alt_lookup = alt_lookup,
        alt_spec_signature = live_alt_signature
    })
    if not wb then
        return
    end

    local desired_note = AutoBand.build_party_note_text(wb)
    local desired_norm = normalize_note_text(desired_note)
    if not desired_norm then
        return
    end

    local current_note = party_state.listing_note
    local current_norm = normalize_note_text(current_note)
    if current_norm and current_norm == desired_norm then
        AutoBand.party_note_last_text = desired_norm
        AutoBand.party_note_last_roster_signature = live_roster_signature
        AutoBand.party_note_last_alt_signature = live_alt_signature
        AutoBand.party_note_last_check_ticks = 0
        AutoBand.partynote_state_dirty = false
        return
    end

    if AutoBand.party_note_last_sent_ticks == nil then
        AutoBand.party_note_last_sent_ticks = PARTYNOTE_SUPPRESS_TICKS
    end
    if AutoBand.party_note_last_sent_ticks < suppress_ticks then
        return
    end

    AutoBand.enqueue_command("/partynote " .. desired_norm)
    AutoBand.party_note_last_text = desired_norm
    AutoBand.party_note_last_roster_signature = live_roster_signature
    AutoBand.party_note_last_alt_signature = live_alt_signature
    AutoBand.party_note_last_sent_ticks = 0
    AutoBand.party_note_last_check_ticks = 0
    AutoBand.partynote_state_dirty = false
end

function AutoBand.OnOpenPartyUpdated()
    if not AutoBand.is_warband_enabled() then
        return
    end
    mark_partynote_dirty()
    if AutoBand.pending_partynote_live_verify ~= true then
        return
    end

    clear_partynote_live_verify_state()
    AutoBand.verify_partynote_live_listing()
end

function AutoBand.clear_partynote_if_autoband()
    if AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled() then
        return
    end
    if not (AutoBand.is_wb_leader and AutoBand.is_wb_leader()) then
        return
    end

    local current_note = AutoBand.get_current_party_note()
    if current_note then
        if note_contains_autoband(current_note) then
            AutoBand.enqueue_command("/partynote")
            return
        end
        return
    end

    if AutoBand.party_note_last_text and note_contains_autoband(AutoBand.party_note_last_text) then
        AutoBand.enqueue_command("/partynote")
        return
    end

    AutoBand.enqueue_command("/partynote")
end

function AutoBand.clear_partynote_before_group_leave()
    if AutoBand.is_warband_enabled and not AutoBand.is_warband_enabled() then
        return false
    end
    if not (AutoBand.is_wb_leader and AutoBand.is_wb_leader()) then
        return false
    end
    if not (AutoBand.saved and AutoBand.saved.autopartynote_enabled == true) then
        return false
    end

    local current_note = AutoBand.get_current_party_note()
    if current_note and note_contains_autoband(current_note) then
        AutoBand.enqueue_command("/partynote")
        return true
    end

    if AutoBand.party_note_last_text and note_contains_autoband(AutoBand.party_note_last_text) then
        AutoBand.enqueue_command("/partynote")
        return true
    end

    return false
end

local function get_partynote_prefix(is_short, wb)
    if is_short then
        return "[AB]"
    end

    if AutoBand.should_show_backfill_marker(wb) then
        return "[AB BackFill]"
    end
    return "[AutoBand]"
end

local function build_party_note_roster_summary(wb, saved)
    return build_wb_roster_need_summary(wb, saved)
end

local function build_party_note_text_variant(wb, opts)
    local saved = AutoBand.saved
    if not wb then
        return nil
    end

    opts = opts or {}
    local include_purpose = opts.include_purpose ~= false
    local include_caps = opts.include_caps ~= false
    local rank_style = opts.rank_style or "full"
    local role_sep = opts.role_sep or " / "
    local need_label = opts.need_label or "Need: "
    local role_style = opts.role_style or "full"
    local race_only_suffix = opts.race_only_suffix ~= false

    local summary = opts.summary
    if type(summary) ~= "table" then
        summary = build_party_note_roster_summary(wb, saved)
    end
    if not summary then
        return nil
    end

    local available_spots = summary.available_spots or 0
    local neededTank = summary.neededTank or 0
    local neededHealer = summary.neededHealer or 0
    local neededMdps = summary.neededMdps or 0
    local neededRdps = summary.neededRdps or 0
    local neededDps = summary.neededDps or 0
    local blocked_role_replacements_needed = summary.blocked_role_replacements_needed == true
    local can_show_currently_full = summary.can_show_currently_full == true
    local role_message_gate = summary.role_message_gate or 0
    local use_dps_weighting_for_message = summary.use_dps_weighting_for_message == true

    local note_prefix = opts.note_prefix or get_partynote_prefix(false, wb)
    local note_parts = {}

    if include_purpose and AutoBand.current_purpose then
        local purpose_entry = AB_const.WARBAND_PURPOSES and AB_const.WARBAND_PURPOSES[AutoBand.current_purpose]
        local purpose_label = purpose_entry and purpose_entry.display or AutoBand.current_purpose
        if purpose_label and purpose_label ~= "" then
            local purpose_text = tostring(purpose_label)
            purpose_text = string.gsub(purpose_text, "%s+", " ")
            purpose_text = string.gsub(purpose_text, "^%s*(.-)%s*$", "%1")
            if purpose_text ~= "" then
                local purpose_lower = string.lower(purpose_text)
                if not string.find(purpose_lower, "warband", 1, true) and string.sub(purpose_lower, -2) ~= "wb" then
                    purpose_text = purpose_text .. " WB"
                end
                table.insert(note_parts, purpose_text)
            end
        end
    end

    if include_caps and saved.autokick_enabled then
        table.insert(note_parts, tostring(saved.max_tanks) .. "-" .. tostring(saved.max_healers) .. "-" .. tostring(saved.max_dps))
    end

    local rank_text = nil
    if saved.autokick_low_rank_enabled then
        local rank_show_roles = nil
        local saved_rank_tank = summary.saved_rank_tank
        local saved_rank_healer = summary.saved_rank_healer
        local saved_rank_dps = summary.saved_rank_dps
        if not can_show_currently_full then
            rank_show_roles = {
                [AB_const.TANK] = neededTank > 0,
                [AB_const.HEALER] = neededHealer > 0,
                ["dps"] = use_dps_weighting_for_message and ((neededMdps > 0) or (neededRdps > 0)) or (neededDps > 0),
            }
        end
        rank_text = AutoBand.build_rank_requirement_text(saved_rank_tank, saved_rank_healer, saved_rank_dps, rank_style, {
            show_roles = rank_show_roles
        })
    end

    local restrictions = {}
    local race_restricted = saved.restrict_same_race and AutoBand.raceDetermined and AutoBand.race
    if race_restricted then
        local race_title = AB_const.GetRaceThemeTitle(AutoBand.race)
        if race_title and race_title ~= "" then
            if race_only_suffix then
                table.insert(restrictions, tostring(race_title) .. " only")
            else
                table.insert(restrictions, tostring(race_title))
            end
        end
    end

    local stealth_suffix = ""
    if available_spots > 0 then
        local wants_dps
        if use_dps_weighting_for_message then
            wants_dps = (neededMdps > 0) or (neededRdps > 0)
        else
            wants_dps = neededDps > 0
        end

        if saved.autokick_we_wh_enabled and (wants_dps or not saved.autokick_enabled) then
            if race_restricted then
                if AutoBand.race == AB_const.EMPIRE then
                    stealth_suffix = " (no WH)"
                elseif AutoBand.race == AB_const.DARKELVES then
                    stealth_suffix = " (no WE)"
                end
            else
                if AutoBand.faction == AB_const.ORDER then
                    stealth_suffix = " (no WH)"
                elseif AutoBand.faction == AB_const.DESTRUCTION then
                    stealth_suffix = " (no WE)"
                end
            end
        end

    end

    if #restrictions > 0 then
        table.insert(note_parts, table.concat(restrictions, ", "))
    end

    if available_spots == 0 and not can_show_currently_full and not blocked_role_replacements_needed then
        return nil
    end

    local roles_text
    if role_message_gate > 0 then
        local role_parts = {}
        if role_style == "short" or role_style == "micro" then
            local function add_short_role(needed, label, parts)
                if needed > 0 then
                    table.insert(parts, tostring(needed) .. label)
                end
            end
            local function add_short_fillable(needed, label, parts)
                if needed > 0 then
                    table.insert(parts, label)
                end
            end

            if saved.autokick_enabled then
                add_short_role(neededTank, "t", role_parts)
                add_short_role(neededHealer, "h", role_parts)
                if use_dps_weighting_for_message then
                    local mdps_label = "md"
                    local rdps_label = "rd"
                    if role_style == "micro" then
                        mdps_label = "m"
                        rdps_label = "r"
                    end
                    if stealth_suffix ~= "" then
                        mdps_label = mdps_label .. stealth_suffix
                    end
                    add_short_role(neededMdps, mdps_label, role_parts)
                    add_short_role(neededRdps, rdps_label, role_parts)
                else
                    local dps_label = "d"
                    if stealth_suffix ~= "" then
                        dps_label = dps_label .. stealth_suffix
                    end
                    add_short_role(neededDps, dps_label, role_parts)
                end
            else
                add_short_fillable(neededTank, "t", role_parts)
                add_short_fillable(neededHealer, "h", role_parts)
                local dps_label = "d"
                if stealth_suffix ~= "" then
                    dps_label = dps_label .. stealth_suffix
                end
                add_short_fillable(neededDps, dps_label, role_parts)
            end
        else
            local function label_single_count(label, role_word)
                if not label then
                    return label
                end
                local base = label
                local suffix_text = ""
                local suffix_start = nil
                for i = #label - 1, 1, -1 do
                    if string.sub(label, i, i + 1) == " (" then
                        suffix_start = i
                        break
                    end
                end
                if suffix_start then
                    base = string.sub(label, 1, suffix_start - 1)
                    suffix_text = string.sub(label, suffix_start)
                end

                if base == role_word then
                    return "1 " .. role_word .. suffix_text
                end
                local role_suffix = " " .. role_word
                if string.sub(base, -#role_suffix) == role_suffix then
                    local prefix = string.sub(base, 1, #base - #role_suffix)
                    if prefix == "" then
                        return "1 " .. role_word .. suffix_text
                    end
                    return prefix .. " 1" .. role_suffix .. suffix_text
                end
                return label
            end

            local healer_label = "healer"
            if rank_style ~= "full" then
                healer_label = "heal"
            end

            if saved.autokick_enabled then
                add_role_to_message(neededTank, role_message_gate, "tank", nil, role_parts)
                add_role_to_message(neededHealer, role_message_gate, healer_label, nil, role_parts)
                if use_dps_weighting_for_message then
                    local mdps_label = "mdps"
                    if stealth_suffix ~= "" then
                        mdps_label = mdps_label .. stealth_suffix
                    end
                    if neededMdps == 1 then
                        mdps_label = label_single_count(mdps_label, "mdps")
                    end
                    local rdps_label = "rdps"
                    if neededRdps == 1 then
                        rdps_label = label_single_count(rdps_label, "rdps")
                    end
                    add_role_to_message(neededMdps, role_message_gate, mdps_label, mdps_label, role_parts)
                    add_role_to_message(neededRdps, role_message_gate, rdps_label, rdps_label, role_parts)
                else
                    local dps_label = "dps"
                    if stealth_suffix ~= "" then
                        dps_label = dps_label .. stealth_suffix
                    end
                    if neededDps == 1 then
                        dps_label = label_single_count(dps_label, "dps")
                    end
                    add_role_to_message(neededDps, role_message_gate, dps_label, dps_label, role_parts)
                end
            else
                local function pluralize_label(label, role_word, desired, plural_override)
                    if not label or desired <= 1 then
                        return label
                    end
                    if plural_override then
                        return plural_override
                    end
                    if role_word == "dps" or role_word == "mdps" or role_word == "rdps" then
                        return label
                    end
                    local base = label
                    local suffix_text = ""
                    local suffix_start = nil
                    for i = #label - 1, 1, -1 do
                        if string.sub(label, i, i + 1) == " (" then
                            suffix_start = i
                            break
                        end
                    end
                    if suffix_start then
                        base = string.sub(label, 1, suffix_start - 1)
                        suffix_text = string.sub(label, suffix_start)
                    end
                    if string.sub(base, -#role_word) == role_word then
                        return base .. "s" .. suffix_text
                    end
                    return label
                end
                local function add_fillable_role(needed, label, role_word, parts, plural_override)
                    if needed <= 0 then
                        return
                    end
                    local effective = needed
                    if role_message_gate < effective then
                        effective = role_message_gate
                    end
                    local final_label = pluralize_label(label, role_word, effective, plural_override)
                    table.insert(parts, final_label)
                end
                add_fillable_role(neededTank, "tank", "tank", role_parts)
                add_fillable_role(neededHealer, healer_label, healer_label, role_parts)
                local dps_label = "dps"
                if stealth_suffix ~= "" then
                    dps_label = dps_label .. stealth_suffix
                end
                add_fillable_role(neededDps, dps_label, "dps", role_parts)
            end
        end

        if #role_parts > 0 then
            roles_text = need_label .. table.concat(role_parts, role_sep)
        elseif available_spots == 0 and not can_show_currently_full then
            roles_text = "Need: replacements"
        else
            roles_text = "Need: none"
        end
    else
        roles_text = "Currently full!"
    end

    if roles_text then
        table.insert(note_parts, roles_text)
    end
    if rank_text then
        table.insert(note_parts, rank_text)
    end

    if #note_parts > 0 then
        return note_prefix .. " " .. table.concat(note_parts, " - ")
    end
    return note_prefix
end

local function append_party_note_promote_suffix_if_room(note_text, saved, max_len)
    if not note_text then
        return note_text
    end
    local suffix = build_party_note_promote_suffix(saved)
    if suffix == "" then
        return note_text
    end
    local limit = tonumber(max_len) or PARTYNOTE_MAX_LEN
    if (#note_text + #suffix) <= limit then
        return note_text .. suffix
    end
    return note_text
end

local function build_party_note_text_variant_cached(wb, summary, opts)
    opts = opts or {}
    opts.summary = summary
    return build_party_note_text_variant(wb, opts)
end

function AutoBand.build_party_note_text(wb)
    local summary = build_party_note_roster_summary(wb, AutoBand.saved)
    local note = build_party_note_text_variant_cached(wb, summary, { include_purpose = true, rank_style = "full" })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, { include_purpose = false, rank_style = "full" })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, { include_purpose = false, rank_style = "compact" })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "compact",
        role_sep = "/",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, { include_purpose = false, rank_style = "short" })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_sep = "/",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "compact",
        role_style = "short",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "compact",
        role_style = "short",
        role_sep = "/",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "short",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "short",
        role_sep = "/",
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "short",
        role_sep = "/",
        race_only_suffix = false,
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "short",
        role_sep = "/",
        note_prefix = get_partynote_prefix(true),
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "short",
        role_sep = "/",
        note_prefix = get_partynote_prefix(true),
        race_only_suffix = false,
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    note = build_party_note_text_variant_cached(wb, summary, {
        include_purpose = false,
        rank_style = "short",
        role_style = "micro",
        role_sep = "/",
        note_prefix = get_partynote_prefix(true),
        race_only_suffix = false,
    })
    if note and #note <= PARTYNOTE_MAX_LEN then
        return append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN)
    end
    return truncate_note_text(append_party_note_promote_suffix_if_room(note, AutoBand.saved, PARTYNOTE_MAX_LEN), PARTYNOTE_MAX_LEN)
end

function AutoBand.auto_partynote()
    local saved = AutoBand.saved
    if not saved.autopartynote_enabled then
        return
    end
    if AutoBand.pending_group_leave_broadcast then
        return
    end
    if AutoBand.debugon then
        return
    end
    if not AutoBand.is_wb_leader() then
        return
    end

    local in_combat = is_player_in_combat()
    if AutoBand.party_note_last_sent_ticks == nil then
        AutoBand.party_note_last_sent_ticks = PARTYNOTE_SUPPRESS_TICKS
    end
    if AutoBand.party_note_last_check_ticks == nil then
        AutoBand.party_note_last_check_ticks = PARTYNOTE_VERIFY_TICKS
    end
    AutoBand.party_note_last_sent_ticks = AutoBand.party_note_last_sent_ticks + 1
    AutoBand.party_note_last_check_ticks = AutoBand.party_note_last_check_ticks + 1
    local suppress_ticks = PARTYNOTE_SUPPRESS_TICKS
    if in_combat then
        suppress_ticks = PARTYNOTE_IN_COMBAT_TICKS
    end
    local should_verify = AutoBand.party_note_last_check_ticks >= PARTYNOTE_VERIFY_TICKS
    local note_dirty = AutoBand.partynote_state_dirty == true

    local live_wbdata, live_roster_signature, alt_lookup, live_alt_signature = get_partynote_live_context(false)
    local roster_changed = live_roster_signature ~= AutoBand.party_note_last_roster_signature
    local alt_changed = live_alt_signature ~= AutoBand.party_note_last_alt_signature
    if roster_changed or alt_changed then
        AutoBand.cache_dirty = true
    end

    if AutoBand.party_note_last_text and
       AutoBand.party_note_last_sent_ticks < suppress_ticks and
       not should_verify and
       not note_dirty and
       not roster_changed and
       not alt_changed then
        return
    end

    local party_state = build_open_party_state_snapshot({
        wbdata = live_wbdata,
    })
    if party_state.is_open ~= true then
        AutoBand.partynote_state_dirty = false
        return
    end

    if should_verify and is_open_party_note_source(party_state.current_note_source) then
        AutoBand.request_partynote_live_verify()
    end

    local wb = AutoBand.get_wb(live_wbdata, {
        roster_signature = live_roster_signature,
        alt_lookup = alt_lookup,
        alt_spec_signature = live_alt_signature
    })
    if not wb then
        return
    end

    local desired_note = AutoBand.build_party_note_text(wb)
    local desired_norm = normalize_note_text(desired_note)
    if not desired_norm then
        AutoBand.party_note_last_text = nil
        AutoBand.party_note_last_sent_ticks = PARTYNOTE_IN_COMBAT_TICKS
        AutoBand.party_note_last_check_ticks = PARTYNOTE_VERIFY_TICKS
        return
    end
    local desired_changed = AutoBand.party_note_last_text ~= desired_norm
    if not desired_changed and not should_verify and not roster_changed and not alt_changed then
        return
    end

    local current_note, current_source = AutoBand.get_current_party_note(party_state)

    local current_norm = normalize_note_text(current_note)
    if current_norm and current_norm == desired_norm then
        AutoBand.party_note_last_text = desired_norm
        AutoBand.party_note_last_roster_signature = live_roster_signature
        AutoBand.party_note_last_alt_signature = live_alt_signature
        AutoBand.party_note_last_check_ticks = 0
        AutoBand.partynote_state_dirty = false
        return
    end

    if should_verify and
        AutoBand.pending_partynote_live_verify == true and
        is_open_party_note_source(current_source) and
        not desired_changed and
        not roster_changed and
        not alt_changed then
        return
    end

    if AutoBand.party_note_last_sent_ticks < suppress_ticks and not roster_changed and not alt_changed then
        return
    end

    AutoBand.enqueue_command("/partynote " .. desired_norm)
    AutoBand.party_note_last_text = desired_norm
    AutoBand.party_note_last_roster_signature = live_roster_signature
    AutoBand.party_note_last_alt_signature = live_alt_signature
    AutoBand.party_note_last_sent_ticks = 0
    AutoBand.party_note_last_check_ticks = 0
    AutoBand.partynote_state_dirty = false
end

function AutoBand.cmd_open_party_status(_args)
    local is_open = false
    local open_reason = nil
    local details = {}

    if GameData and GameData.Player and GameData.Player.Group and
       GameData.Player.Group.Settings then
        local is_public = GameData.Player.Group.Settings.isPublic
        table.insert(details, "GameData.Player.Group.Settings.isPublic=" .. tostring(is_public))
        if type(is_public) == "boolean" and is_public == true then
            is_open = true
            open_reason = "GameData.Player.Group.Settings.isPublic"
        end
    else
        table.insert(details, "GameData.Player.Group.Settings.isPublic=unavailable")
    end

    if PartyUtils and type(PartyUtils.GetWarbandLeader) == "function" then
        local ok_leader, leader = pcall(PartyUtils.GetWarbandLeader)
        if ok_leader then
            local leader_flag, leader_key = resolve_open_flag(leader)
            table.insert(details, "WarbandLeader." .. tostring(leader_key or "flag") .. "=" .. tostring(leader_flag))
            if leader_flag == true and not is_open then
                is_open = true
                open_reason = "WarbandLeader." .. tostring(leader_key or "flag")
            end
        else
            table.insert(details, "WarbandLeader lookup failed")
        end
    else
        table.insert(details, "WarbandLeader lookup unavailable")
    end

    local wb_flag = nil
    local wb_source = nil
    if PartyUtils and type(PartyUtils.GetWarbandData) == "function" then
        local ok_wb, warband = pcall(PartyUtils.GetWarbandData)
        if ok_wb and type(warband) == "table" then
            for p_idx, party in ipairs(warband) do
                if type(party) == "table" then
                    local settings = party.settings or party.Settings
                    if settings and type(settings.isPublic) == "boolean" then
                        wb_flag = settings.isPublic
                        wb_source = "party[" .. tostring(p_idx) .. "].settings.isPublic"
                    end

                    if wb_flag == nil then
                        local party_flag, key = resolve_open_flag(party)
                        if party_flag ~= nil then
                            wb_flag = party_flag
                            wb_source = "party[" .. tostring(p_idx) .. "]." .. tostring(key or "flag")
                        end
                    end

                    if wb_flag == nil and type(party.players) == "table" then
                        for m_idx, member in ipairs(party.players) do
                            local member_flag, key = resolve_open_flag(member)
                            if member_flag ~= nil then
                                wb_flag = member_flag
                                wb_source = "party[" .. tostring(p_idx) .. "].players[" .. tostring(m_idx) .. "]." .. tostring(key or "flag")
                                break
                            end
                        end
                    end

                    if wb_flag ~= nil then
                        break
                    end
                end
            end
        else
            table.insert(details, "Warband data lookup failed")
        end
    else
        table.insert(details, "Warband data lookup unavailable")
    end

    if wb_flag ~= nil then
        table.insert(details, tostring(wb_source or "WarbandData flag") .. "=" .. tostring(wb_flag))
        if wb_flag == true and not is_open then
            is_open = true
            open_reason = wb_source or "WarbandData flag"
        end
    end

    local leader_names = collect_wb_leader_names()
    if leader_names and #leader_names > 0 then
        table.insert(details, "Leader names: " .. table.concat(leader_names, ","))
    else
        table.insert(details, "Leader names: none")
    end

    local listing_open, listing_source = check_open_party_listing_for_leader(leader_names)
    table.insert(details, "OpenPartyList check: " .. tostring(listing_source))
    if listing_open and not is_open then
        is_open = true
        open_reason = listing_source or "OpenPartyList"
    end

    local reason_text = open_reason and (" (source: " .. open_reason .. ")") or ""
    AB_util.print("Open party: " .. tostring(is_open) .. reason_text)
    for i = 1, #details do
        AB_util.print(details[i])
    end
end

function AutoBand.is_open_party(snapshot)
    if type(snapshot) ~= "table" or snapshot._autoband_open_party_snapshot ~= true then
        snapshot = build_open_party_state_snapshot(snapshot)
    end
    return snapshot.is_open == true
end

local STARTER_GUILD_NAMES = {
    ["the forces of destruction"] = true,
    ["the forces of order"] = true
}

function AutoBand.is_starter_guild_name(name)
    if not name then return false end
    local name_str = tostring(name)
    local stripped = name_str:match("([^^]+)") or name_str
    local lower = string.lower(stripped)
    return STARTER_GUILD_NAMES[lower] == true
end

function AutoBand.is_starter_guild()
    if not GameData or not GameData.Guild or not GameData.Guild.m_GuildName then return false end
    return AutoBand.is_starter_guild_name(GameData.Guild.m_GuildName)
end

function AutoBand.GetCurrentGuildInfo()
    if GameData and GameData.Guild and GameData.Guild.m_GuildID and GameData.Guild.m_GuildID ~= 0 and GameData.Guild.m_GuildName then
        if AutoBand.is_starter_guild() then return nil end
        local guild_name_str = tostring(GameData.Guild.m_GuildName)
        return { id = tostring(GameData.Guild.m_GuildID), name = guild_name_str }
    end
    return nil -- Not in a guild or data unavailable
end

local function normalize_link_data(link_data)
    if link_data == nil then
        return ""
    end
    if type(link_data) == "string" then
        return link_data
    end
    local ok, cast = pcall(tostring, link_data)
    if ok and cast then
        return cast
    end
    return ""
end

local function normalize_positive_integer(raw)
    if raw == nil then
        return nil
    end

    local t = type(raw)
    if t == "number" then
        if raw ~= raw then
            return nil
        end
        raw = math.floor(raw)
        if raw <= 0 then
            return nil
        end
        return raw
    end

    if t ~= "string" then
        local ok, cast = pcall(tostring, raw)
        if not ok or cast == nil then
            return nil
        end
        raw = cast
    end

    local matched = string.match(raw, "%d+")
    if not matched then
        return nil
    end

    local as_number = tonumber(matched)
    if as_number == nil then
        return nil
    end
    as_number = math.floor(as_number)
    if as_number <= 0 then
        return nil
    end
    return as_number
end

function AutoBand.build_killboard_character_url(character_id)
    local normalized_character_id = normalize_positive_integer(character_id)
    if not normalized_character_id then
        return nil
    end
    return KILLBOARD_CHARACTER_URL_PREFIX .. tostring(normalized_character_id) .. "/"
end

function AutoBand.build_killboard_link_data_for_character_id(character_id)
    local normalized_character_id = normalize_positive_integer(character_id)
    if not normalized_character_id then
        return nil
    end
    return KILLBOARD_LINK_DATA_TAG .. ":" .. tostring(normalized_character_id)
end

function AutoBand.build_stats_graph_link_data()
    return STATS_GRAPH_LINK_DATA_TAG
end

local function resolve_killboard_url_from_link_data(link_data)
    local raw_data = normalize_link_data(link_data)
    if raw_data == "" then
        return nil
    end

    local prefix = KILLBOARD_LINK_DATA_TAG .. ":"
    if string.sub(raw_data, 1, string.len(prefix)) ~= prefix then
        return nil
    end

    local character_id_text = string.sub(raw_data, string.len(prefix) + 1)
    character_id_text = string.gsub(character_id_text, "^%s+", "")
    character_id_text = string.gsub(character_id_text, "%s+$", "")
    if not string.match(character_id_text, "^%d+$") then
        return nil
    end
    local character_id = normalize_positive_integer(character_id_text)
    if not character_id then
        return nil
    end
    return AutoBand.build_killboard_character_url(character_id)
end

local function resolve_stats_graph_url_from_link_data(link_data)
    local raw_data = normalize_link_data(link_data)
    if raw_data == STATS_GRAPH_LINK_DATA_TAG then
        return STATS_GRAPH_URL
    end
    return nil
end

local function does_window_exist(name)
    if type(DoesWindowExist) ~= "function" then
        return false
    end
    local ok, exists = pcall(DoesWindowExist, name)
    return ok and exists == true
end

function AutoBand.OnCopyLinkInitialize()
    if AutoBand.copy_link_window_initialized then
        return
    end
    AutoBand.copy_link_window_initialized = true

    if type(LabelSetText) == "function" then
        LabelSetText(COPY_LINK_WINDOW_NAME .. "TitleBarText", L"Copy URL")
        LabelSetText(COPY_LINK_WINDOW_NAME .. "Instruction", L"Press Ctrl+C to copy this URL.")
    end
    if type(ButtonSetText) == "function" then
        ButtonSetText(COPY_LINK_WINDOW_NAME .. "CloseButton", L"Close")
    end
end

function AutoBand.EnsureCopyLinkWindow()
    if does_window_exist(COPY_LINK_WINDOW_NAME) then
        if not AutoBand.copy_link_window_initialized then
            AutoBand.OnCopyLinkInitialize()
        end
        return true
    end

    if type(CreateWindow) ~= "function" then
        return false
    end

    local ok_create = pcall(CreateWindow, COPY_LINK_WINDOW_NAME, false)
    if not ok_create or not does_window_exist(COPY_LINK_WINDOW_NAME) then
        return false
    end

    if not AutoBand.copy_link_window_initialized then
        AutoBand.OnCopyLinkInitialize()
    end
    return true
end

function AutoBand.ShowCopyLink(url)
    local url_text = normalize_link_data(url)
    if url_text == "" then
        return false
    end
    if not AutoBand.EnsureCopyLinkWindow() then
        return false
    end

    local url_wstring = towstring(url_text)
    if type(TextEditBoxSetText) == "function" then
        TextEditBoxSetText(COPY_LINK_WINDOW_NAME .. "UrlInput", url_wstring)
    end
    if type(TextEditBoxSetMaxChars) == "function" then
        TextEditBoxSetMaxChars(COPY_LINK_WINDOW_NAME .. "UrlInput", 1000)
    end
    if type(WindowSetShowing) == "function" then
        WindowSetShowing(COPY_LINK_WINDOW_NAME, true)
    end
    if type(WindowAssignFocus) == "function" then
        WindowAssignFocus(COPY_LINK_WINDOW_NAME .. "UrlInput", true)
    end
    if type(TextEditBoxSelectAll) == "function" then
        TextEditBoxSelectAll(COPY_LINK_WINDOW_NAME .. "UrlInput")
    end
    return true
end

function AutoBand.HideCopyLink()
    if type(WindowSetShowing) == "function" and does_window_exist(COPY_LINK_WINDOW_NAME) then
        WindowSetShowing(COPY_LINK_WINDOW_NAME, false)
    end
end

local function open_external_url_or_copy(url)
    local url_text = normalize_link_data(url)
    if url_text == "" then
        return false
    end

    if AutoBand.ShowCopyLink(url_text) then
        return true
    end

    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.OnWebLinkLButtonUp) == "function" then
        pcall(EA_ChatWindow.OnWebLinkLButtonUp, towstring(url_text), 0, 0, 0)
        return true
    end

    if type(DialogManager) == "table" and type(DialogManager.MakeTextEntryDialog) == "function" then
        pcall(
            DialogManager.MakeTextEntryDialog,
            L"Copy Link",
            L" Highlight text and ctrl+c to copy link",
            towstring(url_text),
            nil,
            nil,
            1000,
            true,
            nil,
            true
        )
        return true
    end

    return false
end

function AutoBand.OnHyperLinkLButtonUp(linkData, flags, x, y)
    local original = AutoBand.chat_hyperlink_original_lbutton_up
    if type(original) == "function" and original ~= AutoBand.OnHyperLinkLButtonUp then
        pcall(original, linkData, flags, x, y)
    end

    local raw_data = normalize_link_data(linkData)
    if raw_data == PREFIX_LINK_DATA_OPEN_GUI then
        if AutoBandWindow and type(AutoBandWindow.Show) == "function" then
            AutoBandWindow.Show()
        end
        return
    end

    local killboard_url = resolve_killboard_url_from_link_data(raw_data)
    if killboard_url ~= nil then
        open_external_url_or_copy(killboard_url)
        return
    end

    local stats_graph_url = resolve_stats_graph_url_from_link_data(raw_data)
    if stats_graph_url ~= nil then
        open_external_url_or_copy(stats_graph_url)
    end
end

function AutoBand.TryRegisterPrefixLinkHandler()
    if AutoBand.chat_hyperlink_handler_installed == true then
        return true
    end
    if type(EA_ChatWindow) ~= "table" then
        return false
    end

    local current = EA_ChatWindow.OnHyperLinkLButtonUp
    if current == AutoBand.OnHyperLinkLButtonUp then
        AutoBand.chat_hyperlink_handler_installed = true
        return true
    end

    if type(current) == "function" then
        AutoBand.chat_hyperlink_original_lbutton_up = current
    else
        AutoBand.chat_hyperlink_original_lbutton_up = nil
    end

    EA_ChatWindow.OnHyperLinkLButtonUp = AutoBand.OnHyperLinkLButtonUp
    AutoBand.chat_hyperlink_handler_installed = true
    return true
end

function AutoBand.GenerateGuildLinkRaw(guild_id_str, guild_name_str)
    local prefix_color_name = AutoBand.saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME
    local color_rgb = AB_const.AVAILABLE_COLORS[prefix_color_name] or AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_PREFIX_COLOR_NAME]
    if not color_rgb then -- Safety check
        color_rgb = AB_const.COLOR_WHITE -- Fallback white
    end
    local r, g, b = color_rgb[1], color_rgb[2], color_rgb[3]
    local link_color_str = string.format("%d,%d,%d", r, g, b)
    -- Use the guild *name* for the link text, wrapped in brackets
    local link_raw = string.format("[<LINK data=\"GUILD:%s\" text=\"%s\" color=\"%s\">]",
                                    guild_id_str,
                                    guild_name_str, -- Use actual guild name
                                    link_color_str)
    return link_raw
end

-- RGB of the prefix text (the brackets around it keep the line's own colour).
function AutoBand.get_prefix_color_rgb()
    local color_name = AutoBand.saved.prefix_color_name or AB_const.DEFAULT_PREFIX_COLOR_NAME
    return AB_const.AVAILABLE_COLORS[color_name] or AB_const.AVAILABLE_COLORS[AB_const.DEFAULT_PREFIX_COLOR_NAME] or
        AB_const.COLOR_WHITE
end

function AutoBand.GetFormattedPrefixRaw(includeSpace, opts)
    opts = opts or {}
    local use_guild_prefix = false
    if AutoBand.saved.prefix_use_guild and AutoBand.allow_guild_prefix_override then
        local guildInfo = AutoBand.GetCurrentGuildInfo()
        if guildInfo then
            use_guild_prefix = true
        end
    end
    AutoBand.allow_guild_prefix_override = false
    if use_guild_prefix then
        local guildInfo = AutoBand.GetCurrentGuildInfo()
        local link_raw = AutoBand.GenerateGuildLinkRaw(guildInfo.id, guildInfo.name)
        if includeSpace then return link_raw .. " " else return link_raw end
    else
        local prefix_text = AutoBand.saved.prefix_text or AB_const.DEFAULT_PREFIX_TEXT
        local color_rgb = AutoBand.get_prefix_color_rgb()
        local r, g, b = color_rgb[1], color_rgb[2], color_rgb[3]
        local link_data = "0"
        if opts.open_gui_on_click == true then
            link_data = PREFIX_LINK_DATA_OPEN_GUI
        end
        local coloredPart = string.format("<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">", link_data, r, g, b, prefix_text)
        local prefix = "[" .. coloredPart .. "]"
        if includeSpace then prefix = prefix .. " " end
        return prefix
    end
end

function AutoBand.GetFormattedPrefixWString(includeSpace, opts)
    opts = opts or {}
    local use_guild_prefix = false
    if AutoBand.saved.prefix_use_guild and AutoBand.allow_guild_prefix_override then
        local guildInfo = AutoBand.GetCurrentGuildInfo()
        if guildInfo then
            use_guild_prefix = true
        end
    end
    AutoBand.allow_guild_prefix_override = false
    if use_guild_prefix then
         local guildInfo = AutoBand.GetCurrentGuildInfo()
         local link_raw = AutoBand.GenerateGuildLinkRaw(guildInfo.id, guildInfo.name)
         local link_wstring = towstring(link_raw)
         if includeSpace then return link_wstring .. L" " else return link_wstring end
    else
        local prefix_text = AutoBand.saved.prefix_text or AB_const.DEFAULT_PREFIX_TEXT
        local color_rgb = AutoBand.get_prefix_color_rgb()
        local r, g, b = color_rgb[1], color_rgb[2], color_rgb[3]
        local link_data = "0"
        if opts.open_gui_on_click == true then
            link_data = PREFIX_LINK_DATA_OPEN_GUI
        end
        local coloredPartRaw = string.format("<LINK data=\"%s\" color=\"%d,%d,%d\" text=\"%s\">", link_data, r, g, b, prefix_text)
        local prefix = L"[" .. towstring(coloredPartRaw) .. L"]"
        if includeSpace then prefix = prefix .. L" " end
        return prefix
    end
end

--------------------------------------------------------------------------
-- Player Menu Integration Functions
--------------------------------------------------------------------------

-- Keep normal hook chains intact. The only special case is AutoBand's own
-- wrapper from the previous load; wrapping that again causes reload recursion.
function AutoBand.HookMenuCallback(owner, callback_name, original_field_name, wrapper, previous_wrapper)
    if type(owner) ~= "table" then
        return
    end

    local current = owner[callback_name]
    if current == wrapper then
        return
    end
    if type(current) ~= "function" then
        return
    end

    if current == previous_wrapper then
        if type(AutoBand[original_field_name]) ~= "function" then
            return
        end
    else
        AutoBand[original_field_name] = current
    end
    if AutoBand[original_field_name] == wrapper then
        return
    end

    owner[callback_name] = wrapper
end

local function AutoBand_L_IsActiveMenuItemDisabled()
    if type(ButtonGetDisabledFlag) ~= "function" then
        return false
    end

    local active_window = SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name
    if not active_window or active_window == "" then
        return false
    end

    local ok_disabled, disabled = pcall(ButtonGetDisabledFlag, active_window)
    return ok_disabled and disabled == true
end

local function AutoBand_L_RunLeavePartyMenuAction(original_callback, ...)
    if type(original_callback) ~= "function" then
        return
    end

    if not AutoBand.is_warband_enabled() then
        return original_callback(...)
    end

    if AutoBand_L_IsActiveMenuItemDisabled() then
        return
    end

    if AutoBand.clear_partynote_before_group_leave and AutoBand.clear_partynote_before_group_leave() then
        AutoBand.queue_group_leave_broadcast()
        return
    end

    return original_callback(...)
end

local function AutoBand_L_HookLeavePartyMenuCallback(owner, callback_name, original_field_name, wrapper)
    local previous_wrapper = AutoBand.previous_playerwindow_leave_group
    if callback_name == "OnLeaveGroup" then
        previous_wrapper = AutoBand.previous_groupwindow_leave_group
    elseif original_field_name == "original_battlegrouphud_leave_group" then
        previous_wrapper = AutoBand.previous_battlegrouphud_leave_group
    end

    AutoBand.HookMenuCallback(owner, callback_name, original_field_name, wrapper, previous_wrapper)
end

function AutoBand.HookLeavePartyMenuCallbacks()
    AutoBand_L_HookLeavePartyMenuCallback(
        PlayerWindow,
        "OnMenuClickLeaveGroup",
        "original_playerwindow_leave_group",
        AutoBand.OnPlayerWindowLeaveGroup
    )
    AutoBand_L_HookLeavePartyMenuCallback(
        GroupWindow,
        "OnLeaveGroup",
        "original_groupwindow_leave_group",
        AutoBand.OnGroupWindowLeaveGroup
    )
    AutoBand_L_HookLeavePartyMenuCallback(
        BattlegroupHUD,
        "OnMenuClickLeaveGroup",
        "original_battlegrouphud_leave_group",
        AutoBand.OnBattlegroupHUDLeaveGroup
    )
end

function AutoBand.RestoreLeavePartyMenuCallbacks()
    if AutoBand.original_playerwindow_leave_group and type(PlayerWindow) == "table" and PlayerWindow.OnMenuClickLeaveGroup == AutoBand.OnPlayerWindowLeaveGroup then
        PlayerWindow.OnMenuClickLeaveGroup = AutoBand.original_playerwindow_leave_group
    end
    if AutoBand.original_groupwindow_leave_group and type(GroupWindow) == "table" and GroupWindow.OnLeaveGroup == AutoBand.OnGroupWindowLeaveGroup then
        GroupWindow.OnLeaveGroup = AutoBand.original_groupwindow_leave_group
    end
    if AutoBand.original_battlegrouphud_leave_group and type(BattlegroupHUD) == "table" and BattlegroupHUD.OnMenuClickLeaveGroup == AutoBand.OnBattlegroupHUDLeaveGroup then
        BattlegroupHUD.OnMenuClickLeaveGroup = AutoBand.original_battlegrouphud_leave_group
    end
end

function AutoBand.OnPlayerWindowLeaveGroup(...)
    return AutoBand_L_RunLeavePartyMenuAction(AutoBand.original_playerwindow_leave_group, ...)
end

function AutoBand.OnGroupWindowLeaveGroup(...)
    return AutoBand_L_RunLeavePartyMenuAction(AutoBand.original_groupwindow_leave_group, ...)
end

function AutoBand.OnBattlegroupHUDLeaveGroup(...)
    return AutoBand_L_RunLeavePartyMenuAction(AutoBand.original_battlegrouphud_leave_group, ...)
end

function AutoBand.ModifiedShowMenu(playerName, playerObjNum, customItems)
    if not AutoBand.is_warband_enabled() then
        AutoBand.right_clicked_player_name = nil
        if AutoBand.original_show_menu then
            AutoBand.original_show_menu(playerName, playerObjNum, customItems)
        end
        return
    end
    AutoBand.right_clicked_player_name = playerName
    if AutoBand.original_show_menu then
        AutoBand.original_show_menu(playerName, playerObjNum, customItems)
    end
end

function AutoBand.ModifiedAddGroupMenuItems(targetSelf)
    if AutoBand.original_add_group_menu_items then
        AutoBand.original_add_group_menu_items(targetSelf)
    end

    if not AutoBand.is_warband_enabled() then
        return
    end

    if targetSelf then
        return
    end

    local playerName = AutoBand.right_clicked_player_name
    if not playerName or playerName == L"" then
        return
    end

    local playerNameStr = tostring(playerName)
    local playerNameLower = playerNameStr:lower()
    local currentCustomRole = AutoBand.saved.custom_roles[playerNameLower]

    EA_Window_ContextMenu.AddMenuDivider(EA_Window_ContextMenu.CONTEXT_MENU_1)

    EA_Window_ContextMenu.AddMenuItem(L"AutoBand - Set Role", nil, true, true, EA_Window_ContextMenu.CONTEXT_MENU_1)

    local roles = {
        { label = "Tank",   value = AB_const.TANK,   callback = AutoBand.OnSetRoleTank },
        { label = "Healer", value = AB_const.HEALER, callback = AutoBand.OnSetRoleHealer },
        { label = "mDPS",   value = AB_const.MDPS,   callback = AutoBand.OnSetRoleMDPS },
        { label = "rDPS",   value = AB_const.RDPS,   callback = AutoBand.OnSetRoleRDPS }
    }

    for _, roleInfo in ipairs(roles) do
        local label = L"  Set as " .. towstring(roleInfo.label)
        if currentCustomRole == roleInfo.value then
            label = label .. L" (*)"
        end
        EA_Window_ContextMenu.AddMenuItem(label, roleInfo.callback, false, true, EA_Window_ContextMenu.CONTEXT_MENU_1)
    end

    local isRemoveDisabled = (currentCustomRole == nil)
    EA_Window_ContextMenu.AddMenuItem(L"  Remove Set Role", AutoBand.OnRemoveRole, isRemoveDisabled, true, EA_Window_ContextMenu.CONTEXT_MENU_1)
end

function AutoBand.HookWarbandMenuCallbacks()
    if type(PlayerMenuWindow) == "table" then
        AutoBand.HookMenuCallback(
            PlayerMenuWindow,
            "ShowMenu",
            "original_show_menu",
            AutoBand.ModifiedShowMenu,
            AutoBand.previous_modified_show_menu
        )
        AutoBand.HookMenuCallback(
            PlayerMenuWindow,
            "AddGroupMenuItems",
            "original_add_group_menu_items",
            AutoBand.ModifiedAddGroupMenuItems,
            AutoBand.previous_modified_add_group_menu_items
        )
    end
    AutoBand.HookLeavePartyMenuCallbacks()
end

function AutoBand.RestoreWarbandMenuCallbacks()
    if AutoBand.original_show_menu and type(PlayerMenuWindow) == "table" and PlayerMenuWindow.ShowMenu == AutoBand.ModifiedShowMenu then
        PlayerMenuWindow.ShowMenu = AutoBand.original_show_menu
    end
    if AutoBand.original_add_group_menu_items and type(PlayerMenuWindow) == "table" and PlayerMenuWindow.AddGroupMenuItems == AutoBand.ModifiedAddGroupMenuItems then
        PlayerMenuWindow.AddGroupMenuItems = AutoBand.original_add_group_menu_items
    end
    AutoBand.RestoreLeavePartyMenuCallbacks()
end

function AutoBand.HandleSetOrToggleRole(roleToSet)
    local playerName = AutoBand.right_clicked_player_name
    if not (playerName and playerName ~= L"") then
        return
    end

    local playerNameStr = tostring(playerName)
    local playerNameLower = playerNameStr:lower()
    local currentCustomRole = AutoBand.saved.custom_roles[playerNameLower]

    local args

    if currentCustomRole == roleToSet then
        args = {"remove", playerNameStr}
        if AutoBand.debugon then AB_util.print("Toggling OFF role for: " .. playerNameStr) end
    else
        args = {"add", playerNameStr, roleToSet}
        if AutoBand.debugon then AB_util.print("Setting role '" .. roleToSet .. "' for: " .. playerNameStr) end
    end

    AutoBand.cmd_custom_role(args)
end

function AutoBand.OnSetRoleTank()
    AutoBand.HandleSetOrToggleRole(AB_const.TANK)
end

function AutoBand.OnSetRoleHealer()
    AutoBand.HandleSetOrToggleRole(AB_const.HEALER)
end

function AutoBand.OnSetRoleMDPS()
    AutoBand.HandleSetOrToggleRole(AB_const.MDPS)
end

function AutoBand.OnSetRoleRDPS()
    AutoBand.HandleSetOrToggleRole(AB_const.RDPS)
end

function AutoBand.OnRemoveRole()
    local playerName = AutoBand.right_clicked_player_name
    if playerName and playerName ~= L"" then
        local args = {"remove", tostring(playerName)}
        AutoBand.cmd_custom_role(args)
    end
end

function AutoBand.Shutdown()
    if AutoBand.WBLeaders and type(AutoBand.WBLeaders.CancelRefresh) == "function" then
        AutoBand.WBLeaders.CancelRefresh()
    end
    if type(AutoBand.zonevote_set_sor_tracking) == "function" then
        AutoBand.zonevote_set_sor_tracking(false)
    end
    if AB_util and AB_util._chat_channels_event_registered == true then
        ab_unregister_optional_event_handler("CHANNEL_NAMES_UPDATED", "AutoBand.OnChatChannelNamesUpdated")
        AB_util._chat_channels_event_registered = false
        AB_util.invalidate_chat_channels()
    end
    if AutoBand.wbleader_tell_event_registered == true then
        ab_unregister_optional_event_handler(
            AB_WBLEADER_TELL_EVENT_HANDLER.event,
            AB_WBLEADER_TELL_EVENT_HANDLER.handler
        )
        AutoBand.wbleader_tell_event_registered = false
    end
    AutoBand.StopWBLeaderTellHighlight()
    AutoBand.unregister_warband_event_handlers()
    AutoBand.RestoreWarbandMenuCallbacks()
    if type(EA_ChatWindow) == "table" and EA_ChatWindow.OnHyperLinkLButtonUp == AutoBand.OnHyperLinkLButtonUp then
        EA_ChatWindow.OnHyperLinkLButtonUp = AutoBand.chat_hyperlink_original_lbutton_up
    end
    AutoBand.HideCopyLink()
    AutoBand.chat_hyperlink_handler_installed = false
    AutoBand.chat_hyperlink_original_lbutton_up = nil
    AutoBand.copy_link_window_initialized = false
end
