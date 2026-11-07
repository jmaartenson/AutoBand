# Changelog

## [0.9.83] - 2026-11-07 - Wholdar

### Added
- Added Block AutoBand PMs for players affected by mutes.
- Shift-click rank buttons to change requirements by 10.

### Changed
- Reworked the settings UI with a Realm tab and more options previously limited to slash commands.
- Monitored Enemy groups appear first in the dropdown, marked `[M]`.
- Too-far warnings now go to warband chat.
- Adverts and party notes show BackFill only when the role or rank rules use it.
- Download the optional RR poller separately from GitHub. Setup is in the README.

### Fixed
- Region/LFG adverts for RoR's restored channel numbering.
- WB leader locations. Lists refresh without opening the warband window.
- Restored ZoneVote support for SoR 2.0.
- Purpose clears when you leave or lose leadership. Its list supports read-only browsing.
- A bogus "0" entry in rank data.
- Reduced client load from automatic checks and Enemy monitoring.

## [0.9.82] - 2026-06-13 - Wholdar

### Added
- Added WB leader discovery with `/ab wbleads`, combining open-warband data, map-pin leads, location labels, manual add/remove/clear controls, and optional passive change notifications.
- Added optional WB-Leader tell alerts, off by default, for highlighting and reprinting tells from tracked warband leaders.
- Added ZoneVote support for active RvR zones, including a Tools-tab action, vote previews, ram-aware/faction-aware options, start/reminder/result warband announcements, local vote handling safeguards, and cleanup after leaving the warband.
- Added a Tools-tab `AB Scoreboard` action and hover preview for the existing `/ab scoreboard` output.

### Changed
- Warband automation disable mode is clearer and less disruptive: passive player race/role detection, rank/stat lookups, online monitors, and realmstats startup can continue while mutating WB automation is off.
- `/ab form` now re-enables WB automation before forming/converting a warband, so the form command is still usable after manually disabling WB automation.
- `/ab online monitor` now supports multiple watched Enemy mark groups and add/remove/list/clear management.
- Templates now save and restore prefix settings, prefix color, lead color, selected template state, and related template/icon-menu preferences.
- Tools and configuration UI text/tooltips were tightened for search preview, scoreboard preview, ZoneVote, WB-leader alerts, RR data availability, backfill, too-far radius, and bottom-bar version display.

### Fixed
- Guarded automated kicking so AutoBand does not kick the addon user or the warband leader.
- Fixed early warband UI refresh errors during startup.
- Fixed startup behavior for online monitor and realmstats while WB automation is disabled.

## [0.9.81] - 2026-04-26 - Wholdar

- Added `/ab enable`, `/ab disable`, `/ab enabled`, and `/ab disabled` for pausing mutating warband automation while leaving the addon loaded.
- The warband automation enabled/disabled state is remembered between sessions.
- Continued RR, stats, and related non-mutating features while warband automation is disabled.
- Improved organize reruns around tank/mDPS pairing and realmstats delta reporting.

## [0.9.80] - 2026-04-24 - Wholdar

- Added the BackFill no-heads-up setting so most warning tells can be suppressed while removal reasons still send.
- Improved organizer tank/mDPS pairing when the roster is short on tanks.
- Improved realmstats elapsed/delta reporting.

## [0.9.79] - 2026-04-17 - Wholdar

- Fixed rank backfill so players below the CR16 floor are removed immediately instead of entering the normal reserve-trim pool.
- Added explicit career-rank floor checks and the T2+ removal reason for that case.

## [0.9.78] - 2026-04-15 - Wholdar

- Fixed `/ab scoreboard` argument parsing so `wb`, `warband`, and `popup` routes use the intended preview/send behavior.
- Restricted scoreboard warband-chat sends to the WB leader or assistants, with local output fallback for other users.

## [0.9.77] - 2026-04-14 - Wholdar

- Added `/ab scoreboard`, `/ab wbscore`, and a scoreboard preview popup.
- Added scoreboard output that joins current WB members to RoRGroupScoreboard rows and can preview or post top performers.
- Fixed a party-note issue around scoreboard output.

## [0.9.76] - 2026-04-13 - Wholdar

- Made BackFill default on.
- Improved `/ab org` healer-career spreading and allowed organize to continue when it improves healer-base spread despite an apparent no-op.
- AutoBand party notes are now cleared when leaving through party/warband menus.
- Tightened assistant/rank checks and rank command help text.

## [0.9.75] - 2026-04-11 - Wholdar

- Added `/ab rrcache` and `/ab rrc` to inspect the realm-rank fallback cache.
- Added realm-rank fallback cache summary and list output.
- Fixed social `Promote` and `Protect` interaction in enforcement ordering.
- Capped BackFill reserved slots at 2.

## [0.9.74] - 2026-04-08 - Wholdar

- Reduced client load in rank/social-priority enforcement.
- Added short grace pauses after rank and social-priority setting changes.
- Clarified BackFill advertisements and protected-member handling in output.
- Added smaller fixes in realm-rank, backfill, organize, and settings behavior.

## [0.9.73] - 2026-04-07 - Wholdar

- Added the leader-promotion popup when AutoBand disables autokick after you become warband leader.
- Improved guild, friend, and ignore list refresh reliability.
- The last selected template is now restored.

## [0.9.72] - 2026-04-05 - Wholdar

- Extended guild/friend priority protection into too-far kick handling.
- Cleaned up search and color output text in the UI.

## [0.9.71] - 2026-04-04 - Wholdar

- Fixed additional addon-list warnings from the config/template screens.

## [0.9.70] - 2026-04-04 - Wholdar

- Fixed an addon-list warning from the configuration screen.

## [0.9.69] - 2026-04-03 - Wholdar

- Changed guild/friend priority behavior so protected or preferred players can actually displace non-protected players occupying needed spots.

## [0.9.68] - 2026-04-03 - Wholdar

- Added guild/friend priority modes and guild grouping for organization/enforcement.
- Added `/ab guildpriority`, `/ab friendpriority`, `/ab guildgrouping`, and aliases.
- Refreshed related settings labels and tooltips.

## [0.9.67] - 2026-04-03 - Wholdar

- Added separate tank and DPS minimum-rank requirements alongside the existing healer/general rank settings.
- Added `/ab minranktank`, `/ab minrankdps`, and aliases.

## [0.9.66] - 2026-03-27 - Wholdar

- Improved race-restricted role advertisements so DPS icons and text better respect healer alt-spec exclusions.

## [0.9.65] - 2026-03-27 - Wholdar

- Added template setting snapshots so templates can preserve more than role layout.
- Added the template delete-confirm window.
- Cleaned up template, message, and UI behavior around settings.

## [0.9.64] - 2026-03-19 - Wholdar

- Added the no-mic-needed search option.
- Search messages can now output either `Discord req.` or `Discord req (no mic needed).`
- Added Tools-tab checkbox/tooltip support for the no-mic option.

## [0.9.63] - 2026-03-18 - Wholdar

- Refined BackFill warning and risk tells, including RR-unconfirmed and role-overfilled cases.
- Improved handling of old realm-rank fallback data.
- Added the right-click organize template-menu preference.
- Improved BackFill and partynote integration around active BackFill state.

## [0.9.62] - 2026-03-09 - Wholdar

- Improved party-note rank and role formatting, including compact/micro variants.
- Improved RR/CR display text in online output.
- Cleaned up settings/tooltips and made realmstats refresh more reliably when current stats are missing.

## [0.9.61] - 2026-03-05 - Wholdar

- Added common race-name display for race-restricted warbands.
- Added self rank-cap checks so rank requirements cannot be set beyond what the current character can enforce.
- Improved role-specific rank requirement handling.

## [0.9.60] - 2026-03-05 - Wholdar

- Added the realm-rank CSV poller and Windows launcher.
- Added `/ab rrlookup`, `/ab csvrefresh`, `/ab online`, `/ab friends`, `/ab stats`, and related aliases.
- Added RR-aware rank requirements, rank-data freshness checks, fallback rank data, startup rank safety behavior, and killboard/stat links.
- Added realmstats monitoring and online markgroup support.

## [0.9.50] - 2026-02-19 - Wholdar

- Added the optional `Discord req` suffix for search messages.
- Added the Tools-tab checkbox for the Discord requirement option.

## [0.9.49] - 2026-02-12 - Wholdar

- Added BackFill, including `/ab backfill`, `/ab bfill`, `/ab bf`, and BackFill tells.
- Added `/ab form`, `/ab formwb`, and `/ab wbform` to create/open a party and convert it to a warband.
- Added the RP/Zealot alt-spec exclusion option and Tools/config UI for the new settings.

## [0.9.48] - 2026-02-02 - Wholdar

- Added arrival-order tracking for warband members.
- Added `/ab arrival`, `/ab arrivals`, `/ab joinorder`, and `/ab jo` for listing/reordering/resetting arrival order.
- Added arrival labels for role notifications and BackFill trim context.

## [0.9.47] - 2026-01-24 - Wholdar

- Reworked `/partynote` length handling so notes shorten deliberately instead of being cut off.
- Added shorter rank and role labels for compact party-note variants.

## [0.9.46] - 2026-01-23 - Wholdar

- Fixed leader-promotion safety so autokick toggles are not incorrectly disabled by zone/group-state churn.
- Tightened the re-enable guidance printed when safety disables enforcement toggles.

## [0.9.45] - 2026-01-10 - Wholdar

- Added leader-promotion safety that disables autokick toggles when the player becomes leader of an existing warband.
- Improved AutoBand partynote detection/clearing and stale-note avoidance.

## [0.9.44] - 2025-12-27 - Wholdar

- Reworked `/partynote` generation to avoid icons and fit inside the live note length cap.
- Added periodic partynote verification/refresh so AutoBand notes are refreshed more reliably.
- Updated Tools-tab wording for automatic partynote updates.

## [0.9.43] - 2025-12-21 - Wholdar

- Changed `/partynote` wording for warbands that are not enforcing role counts.

## [0.9.42] - 2025-12-19 - Wholdar

- Added automatic `/partynote` updates for caps, rank, and needed roles.
- Added auto-form-before-search behavior and `/ab autoform`.
- Added `/ab partynote`, `/ab pn`, and `/ab status`.
- Polished role notification text and related UI.

## [0.9.41] - 2025-09-19 - Wholdar

- Fixed advertising message bugs.
- Improved `/ab org` to prioritize the WB leader in group 1.
- Improved distant-player handling for `/ab org distance`.

## [0.9.40] - 2025-09-11 - Wholdar

- Improved non-8-8-8 organization with additional cap-balance moves, swaps, and compacting logic.
- Added clearer organize summaries for post-balance role counts.

## [0.9.39] - 2025-09-10 - Wholdar

- Improved organization soft caps and diversity handling so per-group role caps are respected without starving roles.
- Improved same-career duplicate reduction during organization.
- Added UI shortcuts and clearer output for too-far/offline listing.

## [0.9.38] - 2025-09-02 - Wholdar

- Added zone-name overrides and sanitization for output.

## [0.9.37] - 2025-08-09 - Wholdar

- Fixed guild-priority handling when role-cap enforcement is also enabled.
- Tightened guild member name normalization and role cleanup output.

## [0.9.36] - 2025-07-01 - Wholdar

- Added ignored-player autokick with `/ab akignore`.
- Added ignore-list commands.
- Added player-menu custom role assignment.
- Added Template-tab role-cap editing for warband composition.

## [0.9.35] - 2025-05-29 - Wholdar

- Added distance-based organization with `/ab org distance`, range threshold settings, and GUI/icon shortcuts.
- Added `/ab setdistancethreshold` and `/ab openparty`.
- Improved organizer role caps, diversity, distance placement, and no-op checks.

## [0.9.34] - 2025-05-16 - Wholdar

- Added `/ab listaltspecs` plus aliases to show players whose effective role differs from their default career role.
- Added clearer career-name and role-icon output.
- Improved race-restricted search messages.

## [0.9.33] - 2025-05-12 - Wholdar

- Added configurable too-far kick radius settings.
- Added `/ab settoofardistance`, `/ab setdistance`, `/ab setdist`, `/ab settoofardist`, and `/ab toofardist`.
- Added validation and display for the configured too-far radius.

## [0.9.32] - 2025-05-04 - Wholdar

- Changed guild prefix use so the guild prefix is only applied in search/advertising output.
- Added aliases for guild prefix and prefix color listing.
- Prevented guild-prefix side effects outside search/advertising output.

## [0.9.31] - 2025-05-03 - Wholdar

- Added guild-name prefix support with clickable guild links.
- Added `/ab prefixguild` and guild/prefix output commands.

## [0.9.30] - 2025-05-01 - Wholdar

- Fixed auto-note DPS cap handling.

## [0.9.29] - 2025-05-01 - Wholdar

- Added configurable role caps with `/ab setroles` and `/ab resetroles`.
- Made auto-note and search-role text clearer when role-cap enforcement is active.

## [0.9.28] - 2025-04-30 - Wholdar

- Restored/reworked role-cap autokick after the 0.9.27 formation regression.
- Fixed settings loading around autokick, DPS weighting, race restriction, and prefix state.

## [0.9.27] - 2025-04-25 - Wholdar

- Added BW/Sorc-as-mDPS handling with `/ab bwsmdps` and aliases.
- Added same-race warband restriction with `/ab restrictrace` and aliases.
- Expanded non-RvR/city zone data used by zone enforcement.

## [0.9.26] - 2025-04-18 - Wholdar

- Fixed startup loading for settings and prefix/color validation.
- Tightened defaults for autokick, rank, prefix, DPS weighting, and race-related settings.

## [0.9.25] - 2025-04-18 - Wholdar

- Expanded zone/purpose data used by zone checks and zone-related output.

## [0.9.24] - 2025-04-17 - Wholdar

- Fixed formatted prefix use in warband messages after prefix and lead-color changes.
- Updated organize and too-far announcements to use the configured prefix consistently.

## [0.9.23] - 2025-04-17 - Wholdar

- Added RvR-zone autokick with `/ab akz` and `/ab zk`.
- Added custom prefix text, prefix color, lead color, color listing, and reset commands.
- Added warband purpose labels with `/ab purpose` and `/ab purposelist`.
- Added player race/faction detection and assistant checks used by zone/purpose behavior.

## [0.9.22] - 2025-04-13 - Wholdar

- No user-visible addon changes found; this appears to be a release-page typo correction only.

## [0.9.21] - 2025-04-13 - Wholdar

- Added WE/WH autokick with `/ab wewhk`, `/ab wek`, and `/ab whk`.
- Updated the Tools-tab visibility for role-printing.

## [0.9.20] - 2025-04-12 - Wholdar

- Fixed search/advertise role text around DPS weighting and singular role counts.

## [0.9.19] - 2025-04-11 - Wholdar

- Added colored WB leader links in search/advertising output.

## [0.9.18] - 2025-04-11 - Wholdar

- Allowed non-leaders to run search-role advertising for the current warband.
- Added short aliases for search roles, DPS weighting, buff notify, and custom roles.
- Refined search-role output for leader/non-leader cases.

## [0.9.17] - 2025-04-09 - Wholdar

- Fixed addon loading issues and command ordering.

## [0.9.16] - 2025-04-09 - Wholdar

- Added right-click minimap-icon organize with `/ab rco`.
- Added colored/icon output for AutoBand prefix, role search, kick warnings, and WB messages.
- Updated too-far and search text formatting.

## [0.9.15] - 2025-04-08 - Wholdar

- Reworked `/ab searchroles` text and channel handling.
- Added WB leader location to `/t4` and `/5` search messages.
- Fixed Tools/config GUI toggle state for search/autonote controls.
- Improved min-rank text in search messages.

## [0.9.14] - 2025-04-07 - Wholdar

- Added Tools-tab manual search controls for `/1`, `/t4`, and `/5`.
- Added the Tools-tab Search button for the same manual search output.

## [0.9.13] - 2025-04-07 - Wholdar

- Added low-rank autokick with `/ab akl`.
- Added `searchrole` and `role` aliases.
- Reworked auto-note and search-role output to omit roles with no need.

## [0.9.12] - 2025-04-07 - Wholdar

- Fixed auto-note behavior when the warband is full.
- Adjusted DPS-weighted role count output.

## [0.9.11] - 2025-04-06 - Wholdar

- Added DPS weighting for separate mDPS/rDPS targets.
- Added `/ab dpsweight` and `/ab setdps`.
- Added UI support for mDPS/rDPS target counts.

## [0.9.10] - 2025-04-05 - Wholdar

- Updated organization to spread tank and healer careers more evenly across groups.
- Tightened role/customrole validation and role-list output.

## [0.9.9] - 2025-03-30 - Wholdar

- Added `/ab searchroles` for manual missing-role advertising in selected channels.

## [0.9.8] - 2025-03-30 - Wholdar

- Added `/ab buffnotify` to toggle warband notification after organize.

## [0.9.7] - 2025-03-29 - Wholdar

- Improved slash-command help ordering and settings output.

## [0.9.6] - 2025-03-28 - Wholdar

- Fixed `/1` auto-note DPS need counting.

## [0.9.5] - 2025-03-28 - Wholdar

- Added alt-spec role detection.
- Added persistent custom role overrides with add/remove/list commands.
- Added `/ab roles` and role assignment notifications.
- Updated organization and UI behavior for effective role overrides.

## [0.9.4] - 2025-01-26 - Ninjas

- Updated addon information shown by the client for current game compatibility.

## [0.9.3] - 2025-01-18 - Wholdar

- Fixed guild-priority role trimming in 8-8-8 enforcement.
- Fixed config checkbox state for guild priority and autokick settings.

## [0.9.2] - 2025-01-18 - Wholdar

- Added guild-priority autokick behavior and toggle.
- Added separate healer minimum-rank requirement.

## [0.9.0] - 2020-12-12 - Yun

- Added 8-8-8 warband automation updates, auto-note recruiting, and too-far autokick.
- Added guild member loading, command queueing, `/ab akf`, `/ab an`, `/ab kf`, `/ab kicktimeout`, and `/ab end`.

## [0.8.8] - 2020-05-27 - Talladego

- Declared LibSlash dependency and `/autoband`/`/ab` command support.

## [0.8.7] - 2009-12-10 - Talladego

- Fixed command sending and role detection for Return of Reckoning.

## [0.8.6] - 2009-12-10 - Idrinth Thalui

- Initial public AutoBand release in the downloaded Idrinth release history.
