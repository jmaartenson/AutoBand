-- AB_org.lua

AB_org = {}
AB_org.is_distance_sort_active = false
local shuffle_role_bin_by_career

-- Organizer phases overview (planning on wb_dist, then planning moves/swaps):
-- 1) Build role bins, shuffle, and run AB_template.match (Spread/Aggregate) with caps
--    and reservation rules (Spread redirects limited to primary target groups).
-- 2) Post-layout soft-cap balancing across used groups:
--    - Tanks, Healers, and combined DPS balanced to ceil(total/used_groups).
--    - Use moves if destination has space; otherwise swap with a non-target role.
--    - Compaction step moves players out of trailing partial groups into earlier groups
--      when overall capacity allows, avoiding orphan singletons.
--    - Skipped in strict template mode.
-- 3) Post-diversity swap pass reduces same-career duplicates within each role
--    and, as a secondary tiebreak, can spread healer-base careers across roles
--    when doing so does not worsen role-local diversity.
-- 4) Re-assert soft caps with a second balancing pass (after swaps) to handle
--    changes introduced by the diversity pass (skipped in strict template mode).
--    Then, under real tank shortage, prefer tank+mdps pairing by swapping mdps
--    into tanked groups and rdps back out without changing broad role totals.
-- 5) Final guild-grouping swap pass toward the most guild-heavy compatible group
--    (skipped in strict template mode).
-- 6) Build move/swap plan (cycles resolved) and enqueue.

-- edge colors
AB_org.EC_CLEAR = 0
AB_org.EC_VISITED = 1
AB_org.EC_DEADEND = -1
AB_org.EC_CYCLE = 2

-- Helper function for logging cycle paths
local function cycle_debug_str(path_table)
    local temp_path_str = {}
    if path_table then
        for _, p_edge in ipairs(path_table) do
            if p_edge and p_edge.name and p_edge.fromgid and p_edge.togid then
                table.insert(temp_path_str, string.format("%s(G%d->G%d)", tostring(p_edge.name), p_edge.fromgid, p_edge.togid))
            else
                table.insert(temp_path_str, "[Invalid Edge In Path]")
            end
        end
    end
    return temp_path_str
end

function AB_org.auto_organize(template_to_apply)
    local wb_obj = AutoBand.get_wb()

    if (wb_obj == nil or type(wb_obj.group) ~= "table") then
        AB_util.print("[error] AB_org.auto_organize: Invalid warband data from get_wb().")
        return
    end

    local bins_role = {}
    local roles_not_taken = {} -- This will be populated by AB_template.match
    for cat_key, cat_id in pairs(AB_const.ROLE_CATEGORIES) do
        bins_role[cat_id] = {}
        roles_not_taken[cat_key] = {}
    end

    local wb_dist = {}
    local players_not_placed = {}
    local grp_out = {} -- Graph of planned moves: grp_out[from_gid] = {edge1, edge2, ...}

    local current_max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
    for i = 1, current_max_groups do
        wb_dist[i] = {}
        grp_out[i] = {}
        players_not_placed[i] = {}
    end

    -- Determine current warband leader name if available (prefers isGroupLeader flag)
    local leader_name = nil
    wb_obj:foreach_player(function(_gid, player)
        if not leader_name and player and player.isGroupLeader and player.name then
            leader_name = tostring(player.name)
        end
    end)
    -- Expose to template picker for leader bias (reset at function end)
    AutoBand.organizer_leader_name = leader_name

    -- When an explicit template is provided (and distance sort is not in use),
    -- preserve the template shape by skipping post-balance passes.
    local template_slot_count = 0
    if type(template_to_apply) == "table" then
        template_slot_count = AB_util.size_wb(template_to_apply)
    end
    local strict_template_mode = (template_slot_count > 0) and (not AB_org.is_distance_sort_active)
    local run_post_balance_passes = not strict_template_mode

    wb_obj:foreach_player(
        function(gid, player, pid)
            if player.role and AB_const.ROLE_CATEGORIES[player.role] then
                local player_entry_for_bin = {
                    ["name"] = player.name,
                    ["role"] = player.role,
                    ["career"] = player.careerLine,
                    ["level"] = player.level,
                    ["original_gid"] = gid
                }
                if AB_org.is_distance_sort_active and player.distance_to_leader ~= nil then
                    player_entry_for_bin["distance_to_leader"] = player.distance_to_leader
                end
                table.insert(bins_role[AB_const.ROLE_CATEGORIES[player.role]], player_entry_for_bin)
            else
                if AutoBand.debugon then
                    AB_util.print("[Debug AB_org] Player " .. tostring(player.name) .. " in G" .. gid .. " has invalid/missing role: " .. tostring(player.role))
                end
            end
            if not players_not_placed[gid] then players_not_placed[gid] = {} end
            players_not_placed[gid][pid] = player -- Store the actual player object
        end
    )

    -- Shuffle bins_role (already does shuffle_role_bin_by_career and reverse)
    for i_role_cat = 1, #AB_const.LABEL_ROLE_CATEGORIES_REV do
        if bins_role[i_role_cat] and #bins_role[i_role_cat] > 0 then
            if (AutoBand.debugon or AutoBand.live_org_verbose) then
                AB_util.print("Bin " .. i_role_cat .. " (" .. (AB_const.LABEL_ROLE_CATEGORIES_REV[i_role_cat] or "Unknown") .. ") count before shuffle: " .. #bins_role[i_role_cat])
            end
            local shuffled_bin = shuffle_role_bin_by_career(bins_role[i_role_cat]) -- Uses AB_org.is_distance_sort_active
            local temp_reversed_list = {}
            for i_rev = #shuffled_bin, 1, -1 do
                table.insert(temp_reversed_list, shuffled_bin[i_rev])
            end
            bins_role[i_role_cat] = temp_reversed_list

            if (AutoBand.debugon or AutoBand.live_org_verbose) then
                local roleNameForDebug = (AB_const.LABEL_ROLE_CATEGORIES_REV[i_role_cat] or "UnknownRole")
                AB_util.print("Bin for role key " .. tostring(i_role_cat) .. " (" .. roleNameForDebug .. ") after shuffle and REVERSE (" .. #bins_role[i_role_cat] .. " players):")
                if #bins_role[i_role_cat] > 0 then
                    for _, p_entry_bin in ipairs(bins_role[i_role_cat]) do
                        local dist_str_bin = ""
                        if p_entry_bin.distance_to_leader ~= nil then dist_str_bin = "-D:"..math.floor(p_entry_bin.distance_to_leader) end
                        local careerName = (AutoBand.GetCareerName and p_entry_bin.career and AutoBand.GetCareerName(p_entry_bin.career)) or tostring(p_entry_bin.career or "?")
                        AB_util.print("  - Name:" .. tostring(p_entry_bin.name or "N/A") ..
                                      " Lvl:" .. tostring(p_entry_bin.level or "?") ..
                                      " Career:" .. careerName ..
                                      " OrigG:" .. tostring(p_entry_bin.original_gid or "?") .. dist_str_bin)
                    end
                else
                    AB_util.print("  (Bin is empty for role " .. roleNameForDebug .. ")")
                end
            end
        end
    end

    -- Build final warband layout. When distance sort is active, split players
    -- into close and distant groups and organize in two phases. Also, when
    -- possible, reserve separate group(s) for distant players and keep them
    -- from being compacted back into the close groups in later passes.
    local reserved_far_groups = {}
    if AB_org.is_distance_sort_active then
        local bins_close = {}
        local bins_far = {}
        local close_count = 0
        local far_count = 0
        for rid = 1, #AB_const.LABEL_ROLE_CATEGORIES_REV do
            bins_close[rid] = {}
            bins_far[rid] = {}
            local src_bin = bins_role[rid]
            if src_bin then
                for _, p in ipairs(src_bin) do
                    local dist = p.distance_to_leader
                    local eff = 99999
                    if dist ~= nil then
                        eff = dist
                        if dist <= AutoBand.saved.range_sort_distance_threshold then
                            eff = 0
                        end
                    end
                    if eff == 0 then
                        table.insert(bins_close[rid], p)
                        close_count = close_count + 1
                    else
                        table.insert(bins_far[rid], p)
                        far_count = far_count + 1
                    end
                end
            end
        end

        local groups_for_close = math.max(1, math.ceil(close_count / AB_const.GROUP_SIZE))
        groups_for_close = math.min(groups_for_close, current_max_groups)

        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            local thr = AutoBand.saved.range_sort_distance_threshold or AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
            AB_util.print(string.format("[distance] close=%d, far=%d, threshold=%d", close_count, far_count, thr))
            local start_gid_dbg = groups_for_close + 1
            if start_gid_dbg <= current_max_groups then
                AB_util.print(string.format("[distance] plan: close → G1..G%d; far → G%d..G%d", groups_for_close, start_gid_dbg, current_max_groups))
            else
                AB_util.print(string.format("[distance] plan: close → G1..G%d; far → <none>", groups_for_close))
            end
        end

        if close_count > 0 then
            AB_org._distance_phase = 'close'
            AB_template.match(wb_obj, wb_dist, roles_not_taken, bins_close, template_to_apply, groups_for_close)
        end

        if far_count > 0 then
            local start_gid = groups_for_close + 1
            if start_gid <= current_max_groups then
                AB_org._distance_phase = 'far'
                AB_template.left_over(wb_obj, wb_dist, roles_not_taken, bins_far, start_gid, current_max_groups)
                -- If distant players overflow available far-only group capacity, pack the remainder into
                -- the emptiest close group(s), preferring a single sink to minimize scattering.
                local function bins_size(bins)
                    local n = 0
                    for i=1,#AB_const.LABEL_ROLE_CATEGORIES_REV do if bins[i] then n = n + #bins[i] end end
                    return n
                end
                local remaining_far = bins_size(bins_far)
                if remaining_far > 0 then
                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
                        AB_util.print(string.format("[distance] overflow far players=%d; packing into close groups", remaining_far))
                    end
                    local function find_highest_close_with_space()
                        -- Prefer the highest close group id (groups_for_close .. 1) that has space
                        for gid = groups_for_close, 1, -1 do
                            local g = wb_dist[gid] or {}
                            if #g < AB_const.GROUP_SIZE then return gid end
                        end
                        return -1
                    end
                    local guard = 0
                    while bins_size(bins_far) > 0 and guard < 8 do
                        guard = guard + 1
                        local sink = find_highest_close_with_space()
                        if sink == -1 then break end
                        if (AutoBand.debugon or AutoBand.live_org_verbose) then
                            local free = AB_const.GROUP_SIZE - #(wb_dist[sink] or {})
                            AB_util.print(string.format("[distance] packing far overflow into G%d (free=%d)", sink, free))
                        end
                        -- Restrict placement to this sink only for this pass
                        AB_template.left_over(wb_obj, wb_dist, roles_not_taken, bins_far, sink, sink)
                    end
                end
            else
                AB_util.print("[warn] No available groups for distant players.")
            end
        end

        -- Mark any groups that contain only "far" players so later phases
        -- (balancing, compaction, diversity swaps) avoid mixing them back
        -- into the close groups when there is group-space for separation.
        do
            local threshold = AutoBand.saved.range_sort_distance_threshold or AB_const.DEFAULT_RANGE_SORT_DISTANCE_THRESHOLD
            for gid = 1, current_max_groups do
                local g = wb_dist[gid]
                if g and #g > 0 then
                    local all_far = true
                    for i = 1, #g do
                        local p = g[i]
                        local dist = p and p.distance_to_leader
                        -- Treat unknown distance as far (defensive; organizer computed distances earlier)
                        if dist ~= nil and dist <= threshold then
                            all_far = false; break
                        end
                    end
                    if all_far then reserved_far_groups[gid] = true end
                end
            end
            if (AutoBand.debugon or AutoBand.live_org_verbose) then
                local reserved_list = {}
                for gid = 1, current_max_groups do if reserved_far_groups[gid] then reserved_list[#reserved_list+1] = gid end end
                if #reserved_list > 0 then
                    AB_util.print("[distance] reserved FAR-ONLY groups: G" .. table.concat(reserved_list, ", G"))
                else
                    AB_util.print("[distance] no far-only groups reserved")
                end
            end
        end
        AB_org._distance_phase = nil
    else
        -- Default organization without distance segregation
        AB_template.match(wb_obj, wb_dist, roles_not_taken, bins_role, template_to_apply)
    end

    -- Post planning: role soft-cap balancing across used groups and orphan collapse
    local function list_used_groups()
        local used = {}
        local count = 0
        local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        for gid = 1, max_groups do
            local g = wb_dist[gid]
            if g and #g > 0 then used[gid] = true; count = count + 1 end
        end
        return used, count
    end

    local function count_role_in_group(gid, role_name)
        local c = 0
        local g = wb_dist[gid]
        if g then
            for i = 1, #g do if g[i] and g[i].role == role_name then c = c + 1 end end
        end
        return c
    end

    local function count_role_in_groups_obj(groups_obj, gid, role_name)
        local c = 0
        local g = groups_obj and groups_obj[gid] or nil
        if g then
            for i = 1, #g do
                local p = g[i]
                if p and p.role == role_name then c = c + 1 end
            end
        end
        return c
    end

    local function get_tank_mdps_pairing_score(groups_obj)
        local score = 0
        local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        for gid = 1, max_groups do
            local tanks = count_role_in_groups_obj(groups_obj, gid, AB_const.TANK)
            local mdps = count_role_in_groups_obj(groups_obj, gid, AB_const.MDPS)
            if tanks > 0 and mdps > 0 then
                score = score + 1
            end
        end
        return score
    end

    -- Helpers for combined-role operations (e.g., DPS = MDPS+RDPS)
    local function role_set_contains(role_set, role)
        return role_set and role and role_set[role] == true
    end
    local function count_role_in_group_multi(gid, role_set)
        local c = 0
        local g = wb_dist[gid]
        if g then
            for i = 1, #g do
                local p = g[i]
                if p and role_set_contains(role_set, p.role) then c = c + 1 end
            end
        end
        return c
    end
    local function pick_move_candidate(from_gid, to_gid, role_name)
        local src = wb_dist[from_gid]; if not src then return nil end
        local dst = wb_dist[to_gid] or {}
        local best_idx, best_dst_dup, best_src_dup = nil, nil, nil
        local best_is_sticky = true -- prefer non-sticky movers when possible
        local function career_count_in_group(g_players, role, career)
            local cnt = 0
            if g_players then
                for i = 1, #g_players do
                    local p = g_players[i]
                    if p and p.role == role and (p.career or p.careerLine) == career then cnt = cnt + 1 end
                end
            end
            return cnt
        end
        for i = 1, #src do
            local p = src[i]
            if p and p.role == role_name then
                local skip_leader = (leader_name and tostring(p.name) == leader_name and from_gid == 1)
                if not skip_leader then
                    local career_id = p.career or p.careerLine
                    local dst_dup = career_count_in_group(dst, role_name, career_id)
                    local src_dup = career_count_in_group(src, role_name, career_id)
                    local is_sticky_here = (p.original_gid == from_gid)
                    if best_idx == nil
                        or (not is_sticky_here and best_is_sticky)
                        or dst_dup < best_dst_dup
                        or (dst_dup == best_dst_dup and src_dup > best_src_dup) then
                        best_idx, best_dst_dup, best_src_dup = i, dst_dup, src_dup
                        best_is_sticky = is_sticky_here
                    end
                end
            end
        end
        return best_idx
    end

    local function move_one(from_gid, to_gid, role_name)
        if not wb_dist[from_gid] or not wb_dist[to_gid] then return false end
        if #wb_dist[to_gid] >= AB_const.GROUP_SIZE then return false end
        local idx = pick_move_candidate(from_gid, to_gid, role_name)
        if not idx then return false end
        local p = table.remove(wb_dist[from_gid], idx)
        table.insert(wb_dist[to_gid], p)
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print(string.format("Cap balance: moved %s (%s) from G%d to G%d",
                tostring(p.name or '?'), tostring(role_name), from_gid, to_gid))
        end
        return true
    end

    -- Multi-role variants (for combined DPS balancing)
    local function pick_move_candidate_multi(from_gid, to_gid, role_set)
        local src = wb_dist[from_gid]; if not src then return nil end
        local dst = wb_dist[to_gid] or {}
        local best_idx, best_dst_dup, best_src_dup = nil, nil, nil
        local best_is_sticky = true
        local function career_dup_in_group(g_players, role, career)
            local cnt = 0
            if g_players then
                for i = 1, #g_players do
                    local p = g_players[i]
                    if p and p.role == role and (p.career or p.careerLine) == career then cnt = cnt + 1 end
                end
            end
            return cnt
        end
        for i = 1, #src do
            local p = src[i]
            if p and role_set_contains(role_set, p.role) then
                local skip_leader = (leader_name and tostring(p.name) == leader_name and from_gid == 1)
                if not skip_leader then
                    local career_id = p.career or p.careerLine
                    local dst_dup = career_dup_in_group(dst, p.role, career_id)
                    local src_dup = career_dup_in_group(src, p.role, career_id)
                    local is_sticky_here = (p.original_gid == from_gid)
                    if best_idx == nil
                        or (not is_sticky_here and best_is_sticky)
                        or dst_dup < best_dst_dup
                        or (dst_dup == best_dst_dup and src_dup > best_src_dup) then
                        best_idx, best_dst_dup, best_src_dup = i, dst_dup, src_dup
                        best_is_sticky = is_sticky_here
                    end
                end
            end
        end
        return best_idx
    end

    local function move_one_multi(from_gid, to_gid, role_set, label)
        if not wb_dist[from_gid] or not wb_dist[to_gid] then return false end
        if #wb_dist[to_gid] >= AB_const.GROUP_SIZE then return false end
        local idx = pick_move_candidate_multi(from_gid, to_gid, role_set)
        if not idx then return false end
        local p = table.remove(wb_dist[from_gid], idx)
        table.insert(wb_dist[to_gid], p)
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print(string.format("Cap balance: moved %s (%s) from G%d to G%d",
                tostring(p.name or '?'), tostring(label or p.role), from_gid, to_gid))
        end
        return true
    end

    local function swap_one_multi(from_gid, to_gid, role_set, label)
        local src = wb_dist[from_gid]; local dst = wb_dist[to_gid]
        if not src or not dst or #dst == 0 then return false end
        local idx_src = pick_move_candidate_multi(from_gid, to_gid, role_set)
        if not idx_src then return false end
        -- pick first non-role_set from dst
        local idx_dst = nil
        local best_dup, best_size
        for j = 1, #dst do
            local q = dst[j]
            if q and (not role_set_contains(role_set, q.role)) then
                local skip_leader = (leader_name and tostring(q.name) == leader_name and to_gid == 1)
                if not skip_leader then
                    local dup = 0
                    for i = 1, #src do
                        local s = src[i]
                        if s and s.role == q.role and (s.career or s.careerLine) == (q.career or q.careerLine) then dup = dup + 1 end
                    end
                    local q_is_sticky = (q.original_gid == to_gid)
                    if not q_is_sticky then
                        if not idx_dst or dup < best_dup or (dup == best_dup and (#src < (best_size or 99))) then
                            idx_dst, best_dup, best_size = j, dup, #src
                        end
                    end
                end
            end
        end
        if not idx_dst then return false end
        local p_out = src[idx_src]
        local q_in = dst[idx_dst]
        src[idx_src], dst[idx_dst] = q_in, p_out
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print(string.format("Cap balance swap: %s (%s) G%d -> G%d, %s (%s) G%d -> G%d",
                tostring(p_out.name or '?'), tostring(label or p_out.role), from_gid, to_gid,
                tostring(q_in.name or '?'), tostring(q_in.role or '?'), to_gid, from_gid))
        end
        return true
    end

    local function swap_one(from_gid, to_gid, role_name)
        -- move one 'role_name' from 'from_gid' to 'to_gid', and bring back a non-role_name from 'to_gid' to 'from_gid'
        local src = wb_dist[from_gid]; local dst = wb_dist[to_gid]
        if not src or not dst or #dst == 0 then return false end
        local idx_src = pick_move_candidate(from_gid, to_gid, role_name)
        if not idx_src then return false end
        -- pick first non-role in dst that keeps diversity decent
        local idx_dst = nil
        local best_dup, best_size
        for j = 1, #dst do
            local q = dst[j]
            if q and q.role ~= role_name then
                local skip_leader = (leader_name and tostring(q.name) == leader_name and to_gid == 1)
                if not skip_leader then
                    local dup = 0
                    for i = 1, #src do
                        local s = src[i]
                        if s and s.role == q.role and (s.career or s.careerLine) == (q.career or q.careerLine) then dup = dup + 1 end
                    end
                    local q_is_sticky = (q.original_gid == to_gid)
                    if (not q_is_sticky) and (not idx_dst or dup < best_dup or (dup == best_dup and (#src < (best_size or 99)))) then
                        idx_dst, best_dup, best_size = j, dup, #src
                    end
                end
            end
        end
        if not idx_dst then return false end
        local p_out = src[idx_src]
        local q_in = dst[idx_dst]
        src[idx_src], dst[idx_dst] = q_in, p_out
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print(string.format("Cap balance swap: %s (%s) G%d -> G%d, %s (%s) G%d -> G%d",
                tostring(p_out.name or '?'), tostring(role_name), from_gid, to_gid,
                tostring(q_in.name or '?'), tostring(q_in.role or '?'), to_gid, from_gid))
        end
        return true
    end

    if run_post_balance_passes then
    -- Balance tanks (and optionally healers) across used groups to avoid 3+ stacking when avoidable
    do
        local used_map_all, used_count_all = list_used_groups()
        if used_count_all and used_count_all > 0 then
            local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
            -- Split used groups into close/far-only sets when distance mode is active
            local used_map_close, used_map_far = {}, {}
            local used_count_close, used_count_far = 0, 0
            if AB_org.is_distance_sort_active then
                for gid = 1, max_groups do
                    if used_map_all[gid] then
                        if reserved_far_groups[gid] then used_map_far[gid] = true; used_count_far = used_count_far + 1
                        else used_map_close[gid] = true; used_count_close = used_count_close + 1 end
                    end
                end
            else
                used_map_close = used_map_all; used_count_close = used_count_all
            end

            local function rebalance_role_in(role_name, used_map, used_count)
                if not used_map or not used_count or used_count <= 0 then return end
                -- Total only across the provided used_map
                local total = 0
                for gid = 1, max_groups do if used_map[gid] then total = total + count_role_in_group(gid, role_name) end end
                if total <= 0 then return end
                local cap = math.floor(total / used_count)
                if (total % used_count) ~= 0 then cap = cap + 1 end -- ceil(avg)
                local changed = true
                local guard = 0
                while changed and guard < 64 do
                    guard = guard + 1
                    changed = false
                    local over = {}
                    local under = {}
                    for gid = 1, max_groups do
                        if used_map[gid] then
                            local cnt = count_role_in_group(gid, role_name)
                            if cnt > cap then table.insert(over, gid)
                            elseif cnt < cap then table.insert(under, gid) end
                        end
                    end
                    for _, og in ipairs(over) do
                        local progressed = false
                        for _, ug in ipairs(under) do
                            -- prefer move when dest has space
                            if wb_dist[ug] and #wb_dist[ug] < AB_const.GROUP_SIZE then
                                if move_one(og, ug, role_name) then changed = true; progressed = true; break end
                            else
                                -- attempt swap if dest full but under cap
                                if swap_one(og, ug, role_name) then changed = true; progressed = true; break end
                            end
                        end
                        if progressed then break end
                    end
                end
            end
            -- Tanks and Healers
            rebalance_role_in(AB_const.TANK,   used_map_close, used_count_close)
            rebalance_role_in(AB_const.HEALER, used_map_close, used_count_close)
            -- Also rebalance within far-only groups if there are multiple far groups
            rebalance_role_in(AB_const.TANK,   used_map_far, used_count_far)
            rebalance_role_in(AB_const.HEALER, used_map_far, used_count_far)
            -- Combined DPS (mdps+rdps) within each subset independently
            local function rebalance_dps_in(used_map, used_count)
                if not used_map or not used_count or used_count <= 0 then return end
                local dps_set = {}; dps_set[AB_const.MDPS]=true; dps_set[AB_const.RDPS]=true
                -- Total only across used_map
                local total = 0
                for gid = 1, max_groups do if used_map[gid] then total = total + count_role_in_group_multi(gid, dps_set) end end
                if total <= 0 then return end
                local cap = math.floor(total / used_count)
                if (total % used_count) ~= 0 then cap = cap + 1 end
                local changed = true
                local guard = 0
                while changed and guard < 64 do
                    changed = false; guard = guard + 1
                    local over, under = {}, {}
                    for gid = 1, max_groups do if used_map[gid] then
                        local cnt = count_role_in_group_multi(gid, dps_set)
                        if cnt > cap then table.insert(over, gid) elseif cnt < cap then table.insert(under, gid) end
                    end end
                    for _, og in ipairs(over) do
                        local progressed = false
                        for _, ug in ipairs(under) do
                            if wb_dist[ug] and #wb_dist[ug] < AB_const.GROUP_SIZE then
                                if move_one_multi(og, ug, dps_set, 'dps') then changed = true; progressed = true; break end
                            else
                                if swap_one_multi(og, ug, dps_set, 'dps') then changed = true; progressed = true; break end
                            end
                        end
                        if progressed then break end
                    end
                end
            end
            rebalance_dps_in(used_map_close, used_count_close)
            rebalance_dps_in(used_map_far,   used_count_far)
        end
    end

    -- Collapse trailing tiny groups into earlier groups when space exists (avoid orphans like single RDPS in G4)
    do
        local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        -- Compute total free slots in earlier groups helper
        local function free_slots_upto(limit_gid)
            local free = 0
            for g = 1, limit_gid do
                if wb_dist[g] then free = free + math.max(0, AB_const.GROUP_SIZE - #wb_dist[g]) end
            end
            return free
        end
        for gid = max_groups, 2, -1 do
            local g = wb_dist[gid]
            if g and #g > 0 then
                -- Skip compaction for far-only groups in distance mode
                local skip_compact = (AB_org.is_distance_sort_active and reserved_far_groups[gid] == true)
                local needed = #g
                local free = free_slots_upto(gid - 1)
                if (not skip_compact) and free >= needed then
                    -- Move everyone into earlier groups, best-fit by minimal duplicates
                    local i = 1
                    while wb_dist[gid] and #wb_dist[gid] > 0 and i <= 64 do
                        i = i + 1
                        local p = wb_dist[gid][1]
                        if not p then break end
                        -- find best earlier group with space for this role
                        local best_dest, best_dup, best_size = -1, nil, nil
                        for g2 = 1, gid - 1 do
                            local dst = wb_dist[g2]
                            if dst and #dst < AB_const.GROUP_SIZE then
                                local dup = 0
                                for j = 1, #dst do
                                    local q = dst[j]
                                    if q and q.role == p.role and (q.career or q.careerLine) == (p.career or p.careerLine) then dup = dup + 1 end
                                end
                                if best_dest == -1 or dup < best_dup or (dup == best_dup and #dst < best_size) then
                                    best_dest, best_dup, best_size = g2, dup, #dst
                                end
                            end
                        end
                        if best_dest ~= -1 then
                            table.remove(wb_dist[gid], 1)
                            table.insert(wb_dist[best_dest], p)
                            if (AutoBand.debugon or AutoBand.live_org_verbose) then
                                AB_util.print(string.format("Compact: moved %s from G%d to G%d to avoid orphan",
                                    tostring(p.name or '?'), gid, best_dest))
                            end
                        else
                            break
                        end
                    end
                else
                    if skip_compact and (AutoBand.debugon or AutoBand.live_org_verbose) then
                        AB_util.print(string.format("[distance] skip compaction for reserved far group G%d", gid))
                    end
                end
            end
        end
    end
    end

    -- Post-pass: reduce same-career duplicates within a role by swapping across groups.
    -- Same-role diversity stays primary; healer-base cross-role spread is only a
    -- secondary tie-break when evaluating equally good role-local swaps.
    -- This operates purely on wb_dist (the target layout) before planning actual moves/swaps.
    local function get_role_dup_score_for_group(g_players, role_name)
        if not g_players then return 0 end
        local counts = {}
        local dups = 0
        for i = 1, #g_players do
            local p = g_players[i]
            if p and p.role == role_name then
                local c = p.career or p.careerLine
                counts[c] = (counts[c] or 0) + 1
            end
        end
        for _, cnt in pairs(counts) do if cnt and cnt > 1 then dups = dups + (cnt - 1) end end
        return dups
    end

    local function build_role_index(g_players, role_name)
        local by_career = {}
        for idx = 1, #g_players do
            local p = g_players[idx]
            if p and p.role == role_name then
                local c = p.career or p.careerLine
                if not by_career[c] then by_career[c] = {} end
                table.insert(by_career[c], idx)
            end
        end
        return by_career
    end

    local function get_healer_base_dup_score_for_group(g_players)
        if not g_players then return 0 end
        local counts = {}
        local dups = 0
        for i = 1, #g_players do
            local p = g_players[i]
            local c = p and (p.career or p.careerLine) or nil
            if c and AB_util.is_healer_base_career(c) then
                counts[c] = (counts[c] or 0) + 1
            end
        end
        for _, cnt in pairs(counts) do if cnt and cnt > 1 then dups = dups + (cnt - 1) end end
        return dups
    end

    local function try_reduce_duplicates_once()
        local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        -- Scan each group and role for duplicates
        for gid = 1, max_groups do
            local g_players = wb_dist[gid]
            if g_players and #g_players > 0 then
                for _, role_name in ipairs({AB_const.HEALER, AB_const.TANK, AB_const.MDPS, AB_const.RDPS}) do
                    local dup_score = get_role_dup_score_for_group(g_players, role_name)
                    if dup_score > 0 then
                        local by_career_src = build_role_index(g_players, role_name)
                        -- For each career with count>1, try to swap one out
                        for career_src, idx_list in pairs(by_career_src) do
                            if #idx_list > 1 then
                                -- Prefer to swap out a non-sticky player if available
                                local idx_to_swap_out = nil
                                for _, cand_idx in ipairs(idx_list) do
                                    local cand = g_players[cand_idx]
                                    if cand and cand.original_gid ~= gid then idx_to_swap_out = cand_idx; break end
                                end
                                if not idx_to_swap_out then idx_to_swap_out = idx_list[1] end
                                local p_out = g_players[idx_to_swap_out]
                                -- Search partner group
                                local best_swap = nil
                                local best_role_delta = 0
                                local best_healer_base_delta = 0
                                for gid2 = 1, max_groups do
                                    if gid2 ~= gid and wb_dist[gid2] and #wb_dist[gid2] > 0 then
                                        -- In distance mode, do not swap across the close/far boundary
                                        local boundary_ok = true
                                        if AB_org.is_distance_sort_active then
                                            local a_far = reserved_far_groups[gid] == true
                                            local b_far = reserved_far_groups[gid2] == true
                                            if a_far ~= b_far then boundary_ok = false end
                                        end
                                        if boundary_ok then
                                        local g2_players = wb_dist[gid2]
                                            -- Build indices for partner role
                                            local by_career_dst = build_role_index(g2_players, role_name)
                                            -- Only consider if partner has no player of p_out's career (to avoid creating dup there)
                                            if (by_career_dst[career_src] == nil) then
                                                for career_dst, idx_list2 in pairs(by_career_dst) do
                                                if career_dst ~= career_src and #idx_list2 > 0 then
                                                    -- Prefer a non-sticky partner from gid2 as well
                                                    local idx_in_g2 = nil
                                                    for _, cand2 in ipairs(idx_list2) do
                                                        local cand_idx2 = cand2
                                                        local cand_p2 = g2_players[cand_idx2]
                                                        if cand_p2 and cand_p2.original_gid ~= gid2 then idx_in_g2 = cand_idx2; break end
                                                    end
                                                    if not idx_in_g2 then idx_in_g2 = idx_list2[1] end
                                                    local p_in = g2_players[idx_in_g2]
                                                    -- Compute duplicate delta if swapping p_out (gid) with p_in (gid2)
                                                    -- Pre scores (consider only these two groups for this role)
                                                    local pre_dup_gid = get_role_dup_score_for_group(g_players, role_name)
                                                    local pre_dup_gid2 = get_role_dup_score_for_group(g2_players, role_name)
                                                    local pre_healer_base_gid = get_healer_base_dup_score_for_group(g_players)
                                                    local pre_healer_base_gid2 = get_healer_base_dup_score_for_group(g2_players)
                                                    -- Simulate swap: temporarily adjust
                                                    g_players[idx_to_swap_out], g2_players[idx_in_g2] = p_in, p_out
                                                    local post_dup_gid = get_role_dup_score_for_group(g_players, role_name)
                                                    local post_dup_gid2 = get_role_dup_score_for_group(g2_players, role_name)
                                                    local post_healer_base_gid = get_healer_base_dup_score_for_group(g_players)
                                                    local post_healer_base_gid2 = get_healer_base_dup_score_for_group(g2_players)
                                                    -- Revert simulation
                                                    g_players[idx_to_swap_out], g2_players[idx_in_g2] = p_out, p_in
                                                    local role_delta = (pre_dup_gid + pre_dup_gid2) - (post_dup_gid + post_dup_gid2)
                                                    local healer_base_delta = (pre_healer_base_gid + pre_healer_base_gid2) - (post_healer_base_gid + post_healer_base_gid2)
                                                    if role_delta > best_role_delta or
                                                        (role_delta == best_role_delta and healer_base_delta > best_healer_base_delta) then
                                                        best_role_delta = role_delta
                                                        best_healer_base_delta = healer_base_delta
                                                        best_swap = {
                                                            gid = gid,
                                                            idx1 = idx_to_swap_out,
                                                            p1 = p_out,
                                                            gid2 = gid2,
                                                            idx2 = idx_in_g2,
                                                            p2 = p_in,
                                                            role = role_name,
                                                            role_delta = role_delta,
                                                            healer_base_delta = healer_base_delta
                                                        }
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    end
                                end
                                if best_swap and (best_role_delta > 0 or (best_role_delta == 0 and best_healer_base_delta > 0)) then
                                    -- Perform the beneficial swap in wb_dist
                                    wb_dist[best_swap.gid][best_swap.idx1], wb_dist[best_swap.gid2][best_swap.idx2] = best_swap.p2, best_swap.p1
                                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
                                        local c1n = AutoBand.GetCareerName and AutoBand.GetCareerName(best_swap.p1.career or best_swap.p1.careerLine) or tostring(best_swap.p1.career or best_swap.p1.careerLine)
                                        local c2n = AutoBand.GetCareerName and AutoBand.GetCareerName(best_swap.p2.career or best_swap.p2.careerLine) or tostring(best_swap.p2.career or best_swap.p2.careerLine)
                                        local reason = "to reduce duplicates."
                                        if best_swap.role_delta == 0 and best_swap.healer_base_delta > 0 then
                                            reason = "to spread healer-base careers."
                                        elseif best_swap.healer_base_delta > 0 then
                                            reason = "to reduce duplicates and spread healer-base careers."
                                        end
                                        AB_util.print(string.format("Post-diversity plan: Swapped %s (%s,G%d) with %s (%s,G%d) for role %s %s",
                                            tostring(best_swap.p1.name), c1n, best_swap.gid,
                                            tostring(best_swap.p2.name), c2n, best_swap.gid2,
                                            tostring(best_swap.role), reason))
                                    end
                                    return true -- made progress; rescan
                                end
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    do
        local passes = 0
        local max_passes = 10
        local changed
        repeat
            passes = passes + 1
            changed = try_reduce_duplicates_once()
        until not changed or passes >= max_passes
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print("Post-diversity planning pass complete after " .. tostring(passes) .. " iteration(s).")
        end
    end

    if run_post_balance_passes then
    -- Second-phase balancing to reassert caps after duplicate swaps (aggregate could re-skew careers)
    do
        local used_map_all2, used_count_all2 = list_used_groups()
        if used_count_all2 and used_count_all2 > 0 then
            local max_groups2 = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
            local used_map_close2, used_map_far2 = {}, {}
            local used_count_close2, used_count_far2 = 0, 0
            if AB_org.is_distance_sort_active then
                for gid = 1, max_groups2 do
                    if used_map_all2[gid] then
                        if reserved_far_groups[gid] then used_map_far2[gid] = true; used_count_far2 = used_count_far2 + 1
                        else used_map_close2[gid] = true; used_count_close2 = used_count_close2 + 1 end
                    end
                end
            else
                used_map_close2 = used_map_all2; used_count_close2 = used_count_all2
            end

            local function rebalance_role_again_in(role_name, used_map2, used_count2)
                if not used_map2 or not used_count2 or used_count2 <= 0 then return end
                -- Total only across the provided used_map2
                local total = 0
                for gid = 1, max_groups2 do if used_map2[gid] then total = total + count_role_in_group(gid, role_name) end end
                if total <= 0 then return end
                local cap = math.floor(total / used_count2)
                if (total % used_count2) ~= 0 then cap = cap + 1 end
                local changed = true
                local guard = 0
                while changed and guard < 64 do
                    changed = false; guard = guard + 1
                    local over, under = {}, {}
                    for gid = 1, max_groups2 do if used_map2[gid] then
                        local cnt = count_role_in_group(gid, role_name)
                        if cnt > cap then table.insert(over, gid) elseif cnt < cap then table.insert(under, gid) end
                    end end
                    for _, og in ipairs(over) do
                        local progressed = false
                        for _, ug in ipairs(under) do
                            if wb_dist[ug] and #wb_dist[ug] < AB_const.GROUP_SIZE then
                                if move_one(og, ug, role_name) then changed = true; progressed = true; break end
                            else
                                if swap_one(og, ug, role_name) then changed = true; progressed = true; break end
                            end
                        end
                        if progressed then break end
                    end
                end
            end
            rebalance_role_again_in(AB_const.TANK,   used_map_close2, used_count_close2)
            rebalance_role_again_in(AB_const.HEALER, used_map_close2, used_count_close2)
            rebalance_role_again_in(AB_const.TANK,   used_map_far2,   used_count_far2)
            rebalance_role_again_in(AB_const.HEALER, used_map_far2,   used_count_far2)
            -- DPS combined within each subset
            local function rebalance_dps_again_in(used_map2, used_count2)
                if not used_map2 or not used_count2 or used_count2 <= 0 then return end
                local dps_set = {}; dps_set[AB_const.MDPS]=true; dps_set[AB_const.RDPS]=true
                local total = 0
                for gid = 1, max_groups2 do if used_map2[gid] then total = total + count_role_in_group_multi(gid, dps_set) end end
                if total <= 0 then return end
                local cap = math.floor(total / used_count2)
                if (total % used_count2) ~= 0 then cap = cap + 1 end
                local changed = true; local guard = 0
                while changed and guard < 64 do
                    changed = false; guard = guard + 1
                    local over, under = {}, {}
                    for gid = 1, max_groups2 do if used_map2[gid] then
                        local cnt = count_role_in_group_multi(gid, dps_set)
                        if cnt > cap then table.insert(over, gid) elseif cnt < cap then table.insert(under, gid) end
                    end end
                    for _, og in ipairs(over) do
                        local progressed = false
                        for _, ug in ipairs(under) do
                            if wb_dist[ug] and #wb_dist[ug] < AB_const.GROUP_SIZE then
                                if move_one_multi(og, ug, dps_set, 'dps') then changed = true; progressed = true; break end
                            else
                                if swap_one_multi(og, ug, dps_set, 'dps') then changed = true; progressed = true; break end
                            end
                        end
                        if progressed then break end
                    end
                end
            end
            rebalance_dps_again_in(used_map_close2, used_count_close2)
            rebalance_dps_again_in(used_map_far2,   used_count_far2)

            local function bias_tank_groups_toward_mdps_in(used_map2, used_count2)
                if not used_map2 or not used_count2 or used_count2 <= 1 then return end

                local total_tanks, total_mdps, total_rdps = 0, 0, 0
                for gid = 1, max_groups2 do
                    if used_map2[gid] then
                        total_tanks = total_tanks + count_role_in_group(gid, AB_const.TANK)
                        total_mdps = total_mdps + count_role_in_group(gid, AB_const.MDPS)
                        total_rdps = total_rdps + count_role_in_group(gid, AB_const.RDPS)
                    end
                end

                -- Only bias when at least one used group must go without a tank.
                if total_tanks <= 0 or total_tanks >= used_count2 or total_mdps <= 0 or total_rdps <= 0 then
                    return
                end

                local changed = true
                local guard = 0
                while changed and guard < 24 do
                    changed = false
                    guard = guard + 1

                    local best_swap = nil
                    local best_dup_delta = nil
                    local best_dest_tanks = -1

                    for dest_gid = 1, max_groups2 do
                        if used_map2[dest_gid] then
                            local dest_tanks = count_role_in_group(dest_gid, AB_const.TANK)
                            local dest_mdps = count_role_in_group(dest_gid, AB_const.MDPS)
                            local dest_rdps = count_role_in_group(dest_gid, AB_const.RDPS)

                            if dest_tanks > 0 and dest_mdps == 0 and dest_rdps > 0 then
                                for source_gid = 1, max_groups2 do
                                    if source_gid ~= dest_gid and used_map2[source_gid] then
                                        local source_tanks = count_role_in_group(source_gid, AB_const.TANK)
                                        local source_mdps = count_role_in_group(source_gid, AB_const.MDPS)
                                        if source_tanks == 0 and source_mdps > 0 then
                                            local idx_mdps = pick_move_candidate(source_gid, dest_gid, AB_const.MDPS)
                                            local idx_rdps = pick_move_candidate(dest_gid, source_gid, AB_const.RDPS)
                                            if idx_mdps and idx_rdps then
                                                local src = wb_dist[source_gid]
                                                local dst = wb_dist[dest_gid]
                                                local p_mdps = src[idx_mdps]
                                                local p_rdps = dst[idx_rdps]

                                                local pre_dup = get_role_dup_score_for_group(src, AB_const.MDPS)
                                                    + get_role_dup_score_for_group(dst, AB_const.MDPS)
                                                    + get_role_dup_score_for_group(src, AB_const.RDPS)
                                                    + get_role_dup_score_for_group(dst, AB_const.RDPS)

                                                src[idx_mdps], dst[idx_rdps] = p_rdps, p_mdps

                                                local post_dup = get_role_dup_score_for_group(src, AB_const.MDPS)
                                                    + get_role_dup_score_for_group(dst, AB_const.MDPS)
                                                    + get_role_dup_score_for_group(src, AB_const.RDPS)
                                                    + get_role_dup_score_for_group(dst, AB_const.RDPS)

                                                src[idx_mdps], dst[idx_rdps] = p_mdps, p_rdps

                                                local dup_delta = pre_dup - post_dup
                                                if not best_swap
                                                    or dup_delta > best_dup_delta
                                                    or (dup_delta == best_dup_delta and dest_tanks > best_dest_tanks)
                                                    or (dup_delta == best_dup_delta and dest_tanks == best_dest_tanks and dest_gid < best_swap.dest_gid)
                                                    or (dup_delta == best_dup_delta and dest_tanks == best_dest_tanks and dest_gid == best_swap.dest_gid and source_gid < best_swap.source_gid) then
                                                    best_swap = {
                                                        source_gid = source_gid,
                                                        dest_gid = dest_gid,
                                                        idx_mdps = idx_mdps,
                                                        idx_rdps = idx_rdps,
                                                        p_mdps = p_mdps,
                                                        p_rdps = p_rdps
                                                    }
                                                    best_dup_delta = dup_delta
                                                    best_dest_tanks = dest_tanks
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if best_swap then
                        local src = wb_dist[best_swap.source_gid]
                        local dst = wb_dist[best_swap.dest_gid]
                        src[best_swap.idx_mdps], dst[best_swap.idx_rdps] = best_swap.p_rdps, best_swap.p_mdps
                        changed = true
                        if (AutoBand.debugon or AutoBand.live_org_verbose) then
                            AB_util.print(string.format(
                                "Tank shortage bias: swapped %s (mdps) G%d -> G%d with %s (rdps) G%d -> G%d",
                                tostring(best_swap.p_mdps and best_swap.p_mdps.name or '?'),
                                best_swap.source_gid,
                                best_swap.dest_gid,
                                tostring(best_swap.p_rdps and best_swap.p_rdps.name or '?'),
                                best_swap.dest_gid,
                                best_swap.source_gid))
                        end
                    end
                end
            end

            bias_tank_groups_toward_mdps_in(used_map_close2, used_count_close2)
            bias_tank_groups_toward_mdps_in(used_map_far2,   used_count_far2)
        end
    end

    -- Final guild-grouping pass: prefer legal same-role swaps toward the most guild-heavy
    -- compatible group without crossing distance buckets.
    do
        local function build_guild_lookup()
            if type(AutoBand.get_guild_membership_set_ref) == "function" then
                local lookup = AutoBand.get_guild_membership_set_ref()
                if lookup and next(lookup) ~= nil then
                    return lookup
                end
            elseif type(AutoBand.get_guild_membership_set) == "function" then
                local lookup = AutoBand.get_guild_membership_set()
                if lookup and next(lookup) ~= nil then
                    return lookup
                end
            end
            if not AutoBand.GetCurrentGuildInfo or not GetGuildMemberData then return nil end
            if not AutoBand.GetCurrentGuildInfo() then return nil end
            local ok, data = pcall(GetGuildMemberData)
            if not ok or not data then return nil end
            local lookup = {}
            for _, entry in pairs(data) do
                if entry and entry.name then
                    local name_str = tostring(entry.name)
                    local stripped = name_str:match("([^^]+)") or name_str
                    lookup[string.lower(stripped)] = true
                end
            end
            if AB_util.size_table(lookup) == 0 then return nil end
            return lookup
        end

        local function role_dup_score(group, role_name)
            if not group or not role_name then return 0 end
            local counts = {}
            for i = 1, #group do
                local p = group[i]
                if p and p.role == role_name then
                    local c = p.career or p.careerLine
                    counts[c] = (counts[c] or 0) + 1
                end
            end
            local dup = 0
            for _, cnt in pairs(counts) do
                if cnt and cnt > 1 then dup = dup + (cnt - 1) end
            end
            return dup
        end

        if AutoBand.saved and AutoBand.saved.guild_grouping_enabled == true then
            local guild_lookup = build_guild_lookup()
            if guild_lookup then
                local function is_guildie(name)
                    if not name then return false end
                    if type(AutoBand.normalize_wb_player_name) == "function" then
                        local key = AutoBand.normalize_wb_player_name(name)
                        if key then
                            return guild_lookup[key] == true
                        end
                    end
                    local name_str = tostring(name)
                    local stripped = name_str:match("([^^]+)") or name_str
                    return guild_lookup[string.lower(stripped)] == true
                end

                local max_groups = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
                local preferred_gid, preferred_count, preferred_size = -1, 0, nil
                for gid = 1, max_groups do
                    local g = wb_dist[gid]
                    if g and #g > 0 then
                        local guildies_here = 0
                        for i = 1, #g do
                            if g[i] and is_guildie(g[i].name) then
                                guildies_here = guildies_here + 1
                            end
                        end
                        if guildies_here > 0 then
                            if guildies_here > preferred_count
                                or (guildies_here == preferred_count and (preferred_size == nil or #g < preferred_size))
                                or (guildies_here == preferred_count and preferred_size == #g and gid < preferred_gid) then
                                preferred_gid = gid
                                preferred_count = guildies_here
                                preferred_size = #g
                            end
                        end
                    end
                end

                local function same_distance_bucket(g1, g2)
                    if not AB_org.is_distance_sort_active then return true end
                    local a_far = reserved_far_groups[g1] == true
                    local b_far = reserved_far_groups[g2] == true
                    return a_far == b_far
                end

                if preferred_gid ~= -1 and preferred_count > 0 then
                    local guard = 0
                    local swaps_made = 0
                    while guard < 24 do
                        guard = guard + 1
                        local progressed = false
                        for gid = 1, max_groups do
                            if gid ~= preferred_gid and wb_dist[gid] and #wb_dist[gid] > 0 and same_distance_bucket(gid, preferred_gid) then
                                local source_group = wb_dist[gid]
                                for idx = 1, #source_group do
                                    local p = source_group[idx]
                                    if p and is_guildie(p.name) then
                                        local is_leader_here = (leader_name and tostring(p.name) == leader_name)
                                        if not is_leader_here then
                                            local dest_group = wb_dist[preferred_gid] or {}
                                            local swap_idx = nil
                                            for j = 1, #dest_group do
                                                local q = dest_group[j]
                                                if q and q.role == p.role and not is_guildie(q.name) then
                                                    local skip_leader = (leader_name and tostring(q.name) == leader_name)
                                                    if not skip_leader then
                                                        -- Avoid downgrading brackets: require equal level-range score
                                                        local p_score = AB_util.get_level_range_score(p.level or 0)
                                                        local q_score = AB_util.get_level_range_score(q.level or 0)
                                                        if p_score >= q_score then
                                                            -- Avoid worsening same-career duplicates in either group
                                                            local pre_dup_dest = role_dup_score(dest_group, p.role)
                                                            local pre_dup_src = role_dup_score(source_group, p.role)
                                                            -- simulate swap
                                                            dest_group[j], source_group[idx] = p, q
                                                            local post_dup_dest = role_dup_score(dest_group, p.role)
                                                            local post_dup_src = role_dup_score(source_group, p.role)
                                                            -- revert simulation
                                                            dest_group[j], source_group[idx] = q, p
                                                            if post_dup_dest <= pre_dup_dest and post_dup_src <= pre_dup_src then
                                                                swap_idx = j
                                                                if q.original_gid ~= preferred_gid then break end -- prefer moving non-sticky out
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                            if swap_idx then
                                                local outgoing = wb_dist[preferred_gid][swap_idx]
                                                wb_dist[preferred_gid][swap_idx] = p
                                                source_group[idx] = outgoing
                                                swaps_made = swaps_made + 1
                                                progressed = true
                                                if (AutoBand.debugon or AutoBand.live_org_verbose) then
                                                    AB_util.print(string.format("Guild grouping: swapped %s (G%d) with %s (G%d) into G%d",
                                                        tostring(p.name or '?'), gid,
                                                        tostring(outgoing and outgoing.name or '?'), preferred_gid,
                                                        preferred_gid))
                                                end
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            if progressed then break end
                        end
                        if not progressed then
                            if (AutoBand.debugon or AutoBand.live_org_verbose) and swaps_made > 0 then
                                AB_util.print(string.format("Guild grouping: completed with %d swap(s) toward G%d", swaps_made, preferred_gid))
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    else
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print("Template strict mode: preserving template role shape (post-balance passes skipped).")
        end
    end

    -- Rebuild roles_not_taken to be consistent with the possibly modified wb_dist
    do
        local rebuilt = {}
        for cat_key, _ in pairs(AB_const.ROLE_CATEGORIES) do rebuilt[cat_key] = {} end
        for tg = 1, (wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS) do
            if wb_dist[tg] then
                for _, p in ipairs(wb_dist[tg]) do
                    if p and p.role then table.insert(rebuilt[p.role], tg) end
                end
            end
        end
        roles_not_taken = rebuilt
    end

    -- Idempotency guard based on per-group role counts: if wb_dist role counts match
    -- the current live warband's role counts for every group, skip planning unless
    -- the plan relocates the leader, improves tank+mdps pairing under shortage, or
    -- strictly improves healer-base cross-role spread.
	    do
	        local function find_leader_gid_in(groups)
	            if not leader_name then
	                return nil
	            end
            for gid = 1, current_max_groups do
                local g = groups[gid] or {}
                for i = 1, #g do
                    local p = g[i]
                    if p and tostring(p.name) == leader_name then
                        return gid
                    end
                end
            end
            return nil
        end

        local function counts_by_role(groups)
            local out = {}
            for gid = 1, current_max_groups do
                local t,h,m,r = 0,0,0,0
                local g = groups[gid] or {}
                for i = 1, #g do
                    local p = g[i]
                    if p and p.role == AB_const.TANK then t = t + 1
                    elseif p and p.role == AB_const.HEALER then h = h + 1
                    elseif p and p.role == AB_const.MDPS then m = m + 1
                    elseif p and p.role == AB_const.RDPS then r = r + 1 end
                end
                out[gid] = {t=t,h=h,m=m,r=r}
            end
            return out
        end
	        local live_counts = counts_by_role(AutoBand.get_wb().group)
	        local plan_counts = counts_by_role(wb_dist)
	        local function healer_base_dup_total(groups)
	            local total = 0
	            for gid = 1, current_max_groups do
	                local counts = {}
	                local g = groups[gid] or {}
	                for i = 1, #g do
	                    local p = g[i]
	                    local c = p and (p.career or p.careerLine) or nil
	                    if c and AB_util.is_healer_base_career(c) then
	                        counts[c] = (counts[c] or 0) + 1
	                    end
	                end
	                for _, cnt in pairs(counts) do
	                    if cnt and cnt > 1 then
	                        total = total + (cnt - 1)
	                    end
	                end
	            end
	            return total
	        end
	        local live_healer_base_dups = healer_base_dup_total(AutoBand.get_wb().group)
	        local plan_healer_base_dups = healer_base_dup_total(wb_dist)
	        local healer_base_improves = plan_healer_base_dups < live_healer_base_dups
	        local live_tank_mdps_pairing = get_tank_mdps_pairing_score(AutoBand.get_wb().group)
	        local plan_tank_mdps_pairing = get_tank_mdps_pairing_score(wb_dist)
	        local tank_mdps_pairing_improves = plan_tank_mdps_pairing > live_tank_mdps_pairing
	        local same = true
	        for gid = 1, current_max_groups do
	            local a = live_counts[gid]; local b = plan_counts[gid]
	            if a and b then
	                if a.t~=b.t or a.h~=b.h or a.m~=b.m or a.r~=b.r then same=false; break end
            end
        end
	        if same and (not AB_org.is_distance_sort_active) then
	            -- Exception: if leader exists and planned wb_dist places the leader in a different group than live, allow organizing
	            local live_gid_leader = find_leader_gid_in(AutoBand.get_wb().group)
	            local planned_gid_leader = find_leader_gid_in(wb_dist)
	            local leader_relocation_needed = live_gid_leader and planned_gid_leader and live_gid_leader ~= planned_gid_leader
	            if not leader_relocation_needed then
	                if tank_mdps_pairing_improves then
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print(string.format(
	                            "No-op override: tank/mdps pairing improves %d->%d. Continuing organize.",
	                            live_tank_mdps_pairing,
	                            plan_tank_mdps_pairing))
	                    end
	                elseif healer_base_improves then
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print(string.format(
	                            "No-op override: healer-base spread improves %d->%d duplicate score. Continuing organize.",
	                            live_healer_base_dups,
	                            plan_healer_base_dups))
	                    end
	                else
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print("No-op: live per-group role counts already match planned counts. Skipping organize.")
	                    end
	                    return
	                end
            end
        end

        -- If current layout already satisfies soft caps for Tanks, Healers, and combined DPS
        -- across used groups, consider it acceptable and skip re-organization.
        local function satisfies_soft_caps()
            -- Compute used groups from the LIVE warband, not wb_dist
            local used_map, used_count = {}, 0
            local live = AutoBand.get_wb().group
            for gid = 1, current_max_groups do
                local g = live[gid]
                if g and #g > 0 then used_map[gid] = true; used_count = used_count + 1 end
            end
            if not used_count or used_count == 0 then return true end
            local function within_cap_for_role(role_name)
                -- total across live
                local total = 0
                for gid = 1, current_max_groups do
                    local g = live[gid] or {}
                    for i=1,#g do local p=g[i]; if p and p.role==role_name then total=total+1 end end
                end
                if total <= 0 then return true end
                local cap = math.floor(total / used_count); if (total % used_count) ~= 0 then cap = cap + 1 end
                for gid = 1, current_max_groups do
                    if used_map[gid] then
                        local g = live[gid] or {}
                        local cnt = 0; for i=1,#g do local p=g[i]; if p and p.role==role_name then cnt=cnt+1 end end
                        if cnt > cap then return false end
                    end
                end
                return true
            end
            if not within_cap_for_role(AB_const.TANK) then return false end
            if not within_cap_for_role(AB_const.HEALER) then return false end
            do
                -- combined DPS over live
                local total_dps = 0
                for gid = 1, current_max_groups do
                    local g = live[gid] or {}
                    for i=1,#g do local p=g[i]; if p and (p.role==AB_const.MDPS or p.role==AB_const.RDPS) then total_dps=total_dps+1 end end
                end
                if total_dps > 0 then
                    local cap = math.floor(total_dps / used_count); if (total_dps % used_count) ~= 0 then cap = cap + 1 end
                    for gid = 1, current_max_groups do
                        if used_map[gid] then
                            local g = live[gid] or {}
                            local cnt = 0; for i=1,#g do local p=g[i]; if p and (p.role==AB_const.MDPS or p.role==AB_const.RDPS) then cnt=cnt+1 end end
                            if cnt > cap then return false end
                        end
                    end
                end
            end
            return true
        end
	        if run_post_balance_passes and (not AB_org.is_distance_sort_active) and satisfies_soft_caps() then
	            -- If leader placement differs between live and plan, do not short-circuit
	            local live_gid_leader = find_leader_gid_in(AutoBand.get_wb().group)
	            local planned_gid_leader = find_leader_gid_in(wb_dist)
	            local leader_relocation_needed = live_gid_leader and planned_gid_leader and live_gid_leader ~= planned_gid_leader
	            if not leader_relocation_needed then
	                if tank_mdps_pairing_improves then
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print(string.format(
	                            "Soft-cap no-op override: tank/mdps pairing improves %d->%d. Continuing organize.",
	                            live_tank_mdps_pairing,
	                            plan_tank_mdps_pairing))
	                    end
	                elseif healer_base_improves then
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print(string.format(
	                            "Soft-cap no-op override: healer-base spread improves %d->%d duplicate score. Continuing organize.",
	                            live_healer_base_dups,
	                            plan_healer_base_dups))
	                    end
	                else
	                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
	                        AB_util.print("No-op: live layout already satisfies soft caps. Skipping organize.")
	                    end
	                    return
	                end
            end
        end
    end

    -- "Don't Move" Logic:
    -- Iterate through wb_dist (the target layout with specific players assigned by AB_template.match).
    -- If a player in wb_dist[target_gid] has their original_gid == target_gid,
    -- it means AB_template.match decided they should stay. Remove them from players_not_placed.
    if AutoBand.debugon then AB_util.print("Starting 'Don't Move' analysis (comparing wb_dist to players_not_placed):") end
    for target_gid_loop1 = 1, current_max_groups do
        if wb_dist[target_gid_loop1] then -- wb_dist is the target layout from AB_template.match
            for _, placed_player_obj in ipairs(wb_dist[target_gid_loop1]) do
                if placed_player_obj and placed_player_obj.name and placed_player_obj.original_gid then
                    local original_gid_of_placed_player = placed_player_obj.original_gid

                    -- Check if this placed player was originally in this target_gid (i.e., they "stayed")
                    if original_gid_of_placed_player == target_gid_loop1 then
                        -- Now, find and remove this player from players_not_placed
                        if players_not_placed[original_gid_of_placed_player] then
                            for pid_original = #players_not_placed[original_gid_of_placed_player], 1, -1 do
                                if players_not_placed[original_gid_of_placed_player][pid_original] and
                                   players_not_placed[original_gid_of_placed_player][pid_original].name == placed_player_obj.name then

                                    if AutoBand.debugon then
                                        AB_util.print("Player " .. tostring(placed_player_obj.name) ..
                                                      " (Role: " .. (placed_player_obj.role or "N/A") ..
                                                      ") STAYS in G" .. target_gid_loop1 ..
                                                      " (original_gid matches target_gid in wb_dist). Removing from players_not_placed.")
                                    end
                                    table.remove(players_not_placed[original_gid_of_placed_player], pid_original)

                                    -- Also, effectively "consume" this slot from roles_not_taken.
                                    -- This assumes roles_not_taken was correctly initialized with all template demands
                                    -- and items are removed as they are filled by pick_player_for_slot.
                                    -- If pick_player_for_slot now *adds* to roles_not_taken (as per your earlier code),
                                    -- then this part needs careful review of roles_not_taken's meaning.
                                    -- For now, let's assume roles_not_taken needs to be consistent.
                                    -- If roles_not_taken lists GIDs where a role *was successfully placed*:
                                    local rnt_list = roles_not_taken[placed_player_obj.role]
                                    if rnt_list then
                                        for rnt_idx = #rnt_list, 1, -1 do
                                            local rnt_entry_gid = rnt_list[rnt_idx]
                                            if type(rnt_entry_gid) == "table" then rnt_entry_gid = rnt_entry_gid.gid end

                                            if rnt_entry_gid == target_gid_loop1 then
                                                -- Found the record of this player's role being placed in this group.
                                                -- Remove it to signify this specific player filled it.
                                                -- This helps Loop 2 correctly identify remaining needs.
                                                table.remove(rnt_list, rnt_idx)
                                                break -- consumed one entry for this player
                                            end
                                        end
                                    end
                                    break -- Found and removed from players_not_placed
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Loop 2: Plan moves based on comparing players_not_placed with their target position in wb_dist.
    -- players_not_placed now contains only players who truly need to move from their original group
    -- OR players who couldn't be placed in wb_dist at all by AB_template.match (should be rare).
    if AutoBand.debugon then AB_util.print("Processing Loop 2 (Revised Move Planning - comparing players_not_placed to their target in wb_dist):") end

    local players_actually_needing_a_move_for_grp_out = {} -- Temp store for building grp_out edges

    for fromgid_loop2 = 1, current_max_groups do
        if players_not_placed[fromgid_loop2] then
            for pid_loop2 = 1, #players_not_placed[fromgid_loop2] do -- Iterate forward, not removing directly from this list yet
                local player_to_evaluate = players_not_placed[fromgid_loop2][pid_loop2]
                if player_to_evaluate and player_to_evaluate.name then
                    local final_target_gid_for_player = -1
                    local player_is_in_wb_dist = false

                    -- Find this player in the wb_dist to determine their intended final group
                    for target_search_gid = 1, current_max_groups do
                        if wb_dist[target_search_gid] then
                            for _, p_obj_in_wb_dist_slot in ipairs(wb_dist[target_search_gid]) do
                                if p_obj_in_wb_dist_slot and p_obj_in_wb_dist_slot.name == player_to_evaluate.name then
                                    final_target_gid_for_player = target_search_gid
                                    player_is_in_wb_dist = true
                                    break
                                end
                            end
                        end
                        if player_is_in_wb_dist then break end
                    end

                    if player_is_in_wb_dist then
                        if final_target_gid_for_player ~= fromgid_loop2 then
                            -- This player is in wb_dist but in a *different* group than their original one.
                            -- This is a genuine move.
                            if AutoBand.debugon then
                                AB_util.print("Loop2 Plan Move: Player " .. tostring(player_to_evaluate.name) ..
                                              " (OrigG" .. fromgid_loop2 .. ") target in wb_dist is G" .. final_target_gid_for_player .. ". Adding to move graph.")
                            end
                            table.insert(players_actually_needing_a_move_for_grp_out, {
                                name = player_to_evaluate.name,
                                fromgid = fromgid_loop2,
                                togid = final_target_gid_for_player
                            })
                        elseif AutoBand.debugon then
                            -- This case should have been handled by Loop 1 (player is in their original group AND target group is the same).
                            -- If they are still in players_not_placed here, it's unexpected but not an error for move planning itself.
                            AB_util.print("Loop2 Player Already Correct: Player " .. tostring(player_to_evaluate.name) ..
                                          " (OrigG" .. fromgid_loop2 .. ") target in wb_dist is also G" .. final_target_gid_for_player ..
                                          ". No move edge needed from Loop2 (should have been cleared by Loop1).")
                        end
                    elseif AutoBand.debugon then
                        -- Player was in players_not_placed (so not caught by Loop1 "stay" logic) but NOT found in wb_dist.
                        -- This implies AB_template.match did not place this player from the original warband into the target wb_dist.
                        -- This could happen if wb_dist is smaller than the original warband (e.g. due to max_players limits not yet implemented here).
                        AB_util.print("Loop2 Warning: Player " .. tostring(player_to_evaluate.name) ..
                                      " from players_not_placed[G" .. fromgid_loop2 .. "] was NOT FOUND in the final wb_dist layout. Cannot determine target GID.")
                    end
                end
            end
        end
    end

    -- Now build grp_out from players_actually_needing_a_move_for_grp_out
    for _, move_info in ipairs(players_actually_needing_a_move_for_grp_out) do
        if not grp_out[move_info.fromgid] then grp_out[move_info.fromgid] = {} end
        if not grp_out[move_info.togid] then grp_out[move_info.togid] = {} end

        table.insert(grp_out[move_info.fromgid], {
            ["name"] = move_info.name,
            ["to"] = grp_out[move_info.togid], -- Points to the target group's edge list
            ["togid"] = move_info.togid,
            ["fromgid"] = move_info.fromgid,
            ["color"] = AB_org.EC_CLEAR
        })
    end
    -- End of Loop 2

    -- Early idempotency guard: if no player needs to move per the planned wb_dist,
    -- skip building a move/swap plan altogether.
    if #players_actually_needing_a_move_for_grp_out == 0 then
        if (AutoBand.debugon or AutoBand.live_org_verbose) then
            AB_util.print("No-op: current layout matches planned distribution. Skipping moves/swaps.")
        end
        return
    end

    if (AutoBand.debugon or AutoBand.live_org_verbose) then
        AB_org.verify_org(roles_not_taken, players_not_placed)
    end

    local move_list = {}
    local swap_list = {} -- This will contain paths (tables of edges)
    for i = 1, current_max_groups do
        repeat
            local path_from_search = {}
            local ret_search = AB_org.search(path_from_search, move_list, grp_out[i])
            if (ret_search >= 2) then -- ret_search == 2 (cycle detected) or ret_search == 3 (cycle closed and identified in path_from_search)
                if AutoBand.debugon then
                    AB_util.debug(string.format("AutoBand.auto_organize: Cycle returned from search (ret=%d) starting exploration from G%d. Path: { %s }. Adding to swap_list.",
                                    ret_search, i, table.concat(cycle_debug_str(path_from_search), " -> ")))
                end
                table.insert(swap_list, path_from_search)
            end
        until (ret_search == 0)
    end

    if (AutoBand.debugon or AutoBand.live_org_verbose) then
        AB_util.print("move list (" .. #move_list .. "):")
        for _, mv_edge in ipairs(move_list) do
            AB_util.print(string.format("  Move: %s from G%d to G%d", tostring(mv_edge.name), mv_edge.fromgid, mv_edge.togid))
        end
        -- This detailed print of swap_list is now less useful if the execution logic is changed,
        -- but keeping it for transition. The new logging in the swap execution loop will be more accurate.
        AB_util.print("swap list (raw paths) (" .. #swap_list .. "):")
        for j_debug_raw, cycle_path_raw in ipairs(swap_list) do
            AB_util.print(string.format("  Raw Cycle %d: { %s }", j_debug_raw, table.concat(cycle_debug_str(cycle_path_raw), " -> ")))
        end
    end

    -- Get the current simulated group state ONCE before processing all swaps in this batch
    -- This is for the debug simulation part of AB_org.swap_players / AB_org.move_player
    -- Table used to simulate moves/swaps while processing.  When debug mode is
    -- enabled it is printed and verified, but even outside of debug we need an
    -- internal representation of the current group sizes so the move loop can
    -- work correctly.  Always obtain the current group table, but only output
    -- verbose information when debugging.
    local live_wb_group_for_simulation = AutoBand.get_wb().group

    -- *** NEW Swap Execution Logic ***
    if (AutoBand.debugon or AutoBand.live_org_verbose) then
        AB_util.print("Processing swap_list (" .. #swap_list .. " cycle paths found):")
    end

    for _, cycle_path in ipairs(swap_list) do
        if cycle_path and #cycle_path >= 2 then -- A cycle involves at least 2 players/edges
            if (AutoBand.debugon or AutoBand.live_org_verbose) then
                AB_util.print(string.format("Resolving Cycle Path (%d edges): { %s }", #cycle_path, table.concat(cycle_debug_str(cycle_path), " -> ")))
            end

            if #cycle_path == 2 then
                -- This is a 2-cycle (P1 <-> P2)
                local edge1 = cycle_path[1]
                local edge2 = cycle_path[2]
                if edge1 and edge2 and edge1.name and edge2.name then
                     if (AutoBand.debugon or AutoBand.live_org_verbose) then
                        AB_util.print(string.format("  Executing 2-cycle swap for path: %s <-> %s",
                                        cycle_debug_str({edge1})[1], cycle_debug_str({edge2})[1]))
                    end
                    AB_org.swap_players(live_wb_group_for_simulation, edge1, edge2)
                else
                    if AutoBand.debugon then AB_util.debug("  Malformed 2-cycle path found in swap_list.") end
                end
            elseif #cycle_path > 2 then
                -- This is an N-cycle (P1 -> P2 -> ... -> PN -> P1), N > 2
                -- Resolve by (N-1) sequential 2-player swaps: Swap(P1,P2), then Swap(P2,P3), ..., Swap(P(N-1),PN)
                if (AutoBand.debugon or AutoBand.live_org_verbose) then
                    AB_util.print(string.format("  Resolving N-cycle (%d-players) with %d sequential 2-player swaps.", #cycle_path, #cycle_path - 1))
                end
                for i = 1, #cycle_path - 1 do
                    local edge_for_player_A = cycle_path[i]     -- Represents Player P_i
                    local edge_for_player_B = cycle_path[i+1]   -- Represents Player P_{i+1}

                    if edge_for_player_A and edge_for_player_B and edge_for_player_A.name and edge_for_player_B.name then
                    if (AutoBand.debugon or AutoBand.live_org_verbose) then
                        AB_util.print(string.format("    N-Cycle Step %d: Swapping Player '%s' (from edge info: G%d->G%d) with Player '%s' (from edge info: G%d->G%d)",
                                        i, tostring(edge_for_player_A.name), edge_for_player_A.fromgid, edge_for_player_A.togid,
                                        tostring(edge_for_player_B.name), edge_for_player_B.fromgid, edge_for_player_B.togid))
                    end
                        AB_org.swap_players(live_wb_group_for_simulation, edge_for_player_A, edge_for_player_B)
                    else
                        if AutoBand.debugon then
                            AB_util.print(string.format("    N-Cycle Step %d: Malformed edge pair in cycle path. EdgeA: %s, EdgeB: %s",
                                            i, tostring(edge_for_player_A), tostring(edge_for_player_B)))
                        end
                    end
                end
            end
        else
            if AutoBand.debugon and cycle_path then
                 AB_util.print("Skipping cycle_path with < 2 edges. Length: " .. #cycle_path)
            elseif AutoBand.debugon then
                 AB_util.print("Skipping nil cycle_path.")
            end
        end
    end
    -- *** END OF NEW Swap Execution Logic ***

    -- process moves: brute force mode, loop until all moves are done
    local moves_processed_in_iteration
    local iterations = 0
    local MAX_MOVE_ITERATIONS = AB_const.LOOP_MAX
    repeat
        moves_processed_in_iteration = 0
        iterations = iterations + 1
        local i_move = #move_list
        -- live_wb_group_for_simulation should also be used/updated by move_player's debug part
        while (i_move > 0) do
            local v_move_edge = move_list[i_move]
            if v_move_edge and live_wb_group_for_simulation[v_move_edge.togid] and #live_wb_group_for_simulation[v_move_edge.togid] < AB_const.GROUP_SIZE then
                AB_org.move_player(live_wb_group_for_simulation, v_move_edge)
                table.remove(move_list, i_move)
                moves_processed_in_iteration = moves_processed_in_iteration + 1
            end
            i_move = i_move - 1
        end
    until moves_processed_in_iteration == 0 or iterations > MAX_MOVE_ITERATIONS

    if iterations > MAX_MOVE_ITERATIONS and AutoBand.debugon then
        AB_util.print("[Warning] Move processing loop reached max iterations. " .. #move_list .. " moves remaining.")
    end

    -- Diversity was improved in a post-pass above; now proceed to execute plan.

    if (AutoBand.debugon) then
        -- wb_dist here is the target role list per group, not player assignments.
        if (AB_org.verify_result(AutoBand.get_wb(), wb_dist)) then
            AB_util.print("The warband is perfectly organized (according to wb_dist).")
        else
            AB_util.print("The warband organization might not match expected wb_dist.")
        end
        -- Compact one-line post summary
        local post_line = AB_util.roles_summary_line(AutoBand.get_wb())
        if post_line and post_line ~= "" then AB_util.print("Roles (post): " .. post_line) end

        -- Residual diversity report: check same-career duplicates within each role
        -- and suggest if likely avoidable. This report is intentionally role-local;
        -- healer-base cross-role spread is handled during planning, not here.
        local function group_role_career_counts(g_players)
            local by_role = {}
            if not g_players then return by_role end
            for i = 1, #g_players do
                local p = g_players[i]
                if p and p.role and (p.career or p.careerLine) then
                    local role = p.role
                    local c = p.career or p.careerLine
                    if not by_role[role] then by_role[role] = {} end
                    by_role[role][c] = (by_role[role][c] or 0) + 1
                end
            end
            return by_role
        end

        local function roles_list()
            return {AB_const.TANK, AB_const.HEALER, AB_const.MDPS, AB_const.RDPS}
        end

        local function career_name(cid)
            if AutoBand and AutoBand.GetCareerName and cid then return AutoBand.GetCareerName(cid) end
            return tostring(cid)
        end

        local max_groups_dbg = wb_obj.MAX_GROUPS or AB_const.MAX_WB_GROUPS
        local duplicates_found = false
        for gid_dbg = 1, max_groups_dbg do
            local g = wb_dist[gid_dbg]
            if g and #g > 0 then
                local counts = group_role_career_counts(g)
                for _, role_name in ipairs(roles_list()) do
                    local m = counts[role_name]
                    if m then
                        for cid, cnt in pairs(m) do
                            if cnt and cnt > 1 then
                                -- Heuristic: avoidable if another group has the same role but zero of this career
                                local avoidable = false
                                for gid2 = 1, max_groups_dbg do
                                    if gid2 ~= gid_dbg and wb_dist[gid2] and #wb_dist[gid2] > 0 then
                                        local counts2 = group_role_career_counts(wb_dist[gid2])
                                        local m2 = counts2[role_name]
                                        if m2 then
                                            local total_role_in_g2 = 0
                                            for _, v in pairs(m2) do total_role_in_g2 = total_role_in_g2 + (v or 0) end
                                            if (m2[cid] or 0) == 0 and total_role_in_g2 > 0 then
                                                avoidable = true; break
                                            end
                                        end
                                    end
                                end
                                duplicates_found = true
                                AB_util.print(string.format("Diversity: G%d has %d× %s in role %s%s",
                                    gid_dbg, cnt, career_name(cid), tostring(role_name), (avoidable and " [avoidably duplicated?]" or "")))
                            end
                        end
                    end
                end
            end
        end
        if not duplicates_found then
            AB_util.print("Diversity: No same-career duplicates per role detected.")
        end
    else
        if AutoBand.saved.notify_buffs_enabled then
            AutoBand.enqueue_command("/wb " .. AutoBand.GetFormattedPrefixRaw(true) .. "Auto organize done! Please check your guards, buffs and such!")
        end
        AB_util.print("Auto organize done!")
    end
end

shuffle_role_bin_by_career = function(role_bin)
  if not role_bin or #role_bin < 2 then
    return role_bin
  end
  local careers = {}
  local careerOrder = {}
  local maxLen = 0
  for _, entry in ipairs(role_bin) do
    if entry and entry.career then
      local c = entry.career
      if not careers[c] then
        careers[c] = {}
        table.insert(careerOrder, c)
      end
      table.insert(careers[c], entry)
      if #careers[c] > maxLen then
        maxLen = #careers[c]
      end
    end
  end
  if maxLen == 0 or #careerOrder == 0 then return role_bin end
  table.sort(careerOrder)
  for _, c_val in ipairs(careerOrder) do
    if careers[c_val] and #careers[c_val] > 0 then
      table.sort(careers[c_val], function(a, b)
        if AB_org.is_distance_sort_active then
            local dist_a_raw = a.distance_to_leader
            local dist_b_raw = b.distance_to_leader
            local threshold = AutoBand.saved.range_sort_distance_threshold

            local a_is_close = (dist_a_raw ~= nil and dist_a_raw <= threshold)
            local b_is_close = (dist_b_raw ~= nil and dist_b_raw <= threshold)

            if a_is_close ~= b_is_close then
                return a_is_close
            end

            if dist_a_raw ~= nil and dist_b_raw ~= nil then
                if dist_a_raw ~= dist_b_raw then
                    return dist_a_raw < dist_b_raw
                end
            elseif dist_a_raw ~= nil then
                return true
            elseif dist_b_raw ~= nil then
                return false
            end
        end

        local score_a = AB_util.get_level_range_score(a.level or 0)
        local score_b = AB_util.get_level_range_score(b.level or 0)

        if score_a ~= score_b then
            return score_a > score_b
        end

        if a.level ~= b.level then
            return a.level > b.level
        end

        if a.name and b.name then
            local name_a_str = tostring(a.name)
            local name_b_str = tostring(b.name)
            if name_a_str ~= name_b_str then
                return name_a_str < name_b_str
            end
        elseif a.name then
            return true
        elseif b.name then
            return false
        end

        return false
      end)
    end
  end
  local shuffled = {}
  for i = 1, maxLen do
    for _, c_val in ipairs(careerOrder) do
      if careers[c_val] and careers[c_val][i] then
        table.insert(shuffled, careers[c_val][i])
      end
    end
  end
  return shuffled
end

--------------------------------------------------------------------
-- verify the organization (debug)
--------------------------------------------------------------------
function AB_org.verify_org(roles_not_taken, players_not_placed)
        AB_util.debug(" Roles not taken (target spots in wb_dist unfilled by players_not_placed): " .. AB_util.size_wb(roles_not_taken))
        if (AB_util.size_wb(roles_not_taken) > 0) then
                AB_util.debug("There are roles in wb_dist that were not filled by a player from players_not_placed:")
                for role_name, groups_with_role in pairs(roles_not_taken) do
                        if #groups_with_role > 0 then
                                AB_util.debug("  Role '" .. role_name .. "' has " .. #groups_with_role .. " unfilled spot(s) in wb_dist (groups: " .. table.concat(groups_with_role, ",") .. ")")
                        end
                end
        end

        AB_util.debug(" Players not placed (original players needing a move): " .. AB_util.size_wb(players_not_placed))
        if (AB_util.size_wb(players_not_placed) > 0) then
                AB_util.debug("There are players who were identified as needing a move but weren't assigned a target slot in grp_out:")
                AB_util.foreach_player(players_not_placed, function(gid, player, _pid)
                        if player and player.name then
                                AB_util.debug("  Player " .. tostring(player.name) ..  " (Role: " .. (player.role or "N/A") .. ") from original G" .. gid .. " is still in players_not_placed.")
                        end
                end)
        end
end

--------------------------------------------------------------------
-- verify the result (debug)
--------------------------------------------------------------------
function AB_org.verify_result(wb_obj_after_moves, wb_dist_expected_roles)
        AB_util.print("Verifying organization result...")
        local mismatches = 0

        -- Create a count of expected roles per group from wb_dist_expected_roles
        local expected_counts = {}
        for gid = 1, wb_obj_after_moves.MAX_GROUPS do
            expected_counts[gid] = {}
            if wb_dist_expected_roles[gid] then -- Ensure the group exists in the expected layout
                for _, player_object_in_expected_group in ipairs(wb_dist_expected_roles[gid]) do
                    if player_object_in_expected_group and player_object_in_expected_group.role then
                        expected_counts[gid][player_object_in_expected_group.role] = (expected_counts[gid][player_object_in_expected_group.role] or 0) + 1
                    elseif AutoBand.debugon then
                        AB_util.print("[Debug verify_result] G" .. gid .. ": Invalid/incomplete player object in expected layout: " .. tostring(player_object_in_expected_group))
                    end
                end
            end
        end

        -- Create a count of actual roles per group from wb_obj_after_moves
        local actual_counts = {}
        for gid = 1, wb_obj_after_moves.MAX_GROUPS do
                actual_counts[gid] = {}
                for _, player in ipairs(wb_obj_after_moves.group[gid] or {}) do
                        if player and player.role then
                                actual_counts[gid][player.role] = (actual_counts[gid][player.role] or 0) + 1
                        end
                end
        end

        -- Compare counts
        local all_roles = {}
        for _, role_cat_id in pairs(AB_const.ROLE_CATEGORIES) do
                for role_name, _ in pairs(AB_const.CAREERLINE_MAP) do -- Hacky way to get all role names like "tank", "healer"
                        if AB_const.CAREERLINE_MAP[role_name] == AB_const.LABEL_ROLE_CATEGORIES_REV[role_cat_id] then
                                all_roles[AB_const.LABEL_ROLE_CATEGORIES_REV[role_cat_id]] = true; break
                        end
                end
                -- Ensure base roles are there
                all_roles[AB_const.TANK] = true; all_roles[AB_const.HEALER] = true; all_roles[AB_const.MDPS] = true; all_roles[AB_const.RDPS] = true;
        end


        for gid = 1, wb_obj_after_moves.MAX_GROUPS do
                for role_name, _ in pairs(all_roles) do
                        local expected = expected_counts[gid][role_name] or 0
                        local actual = actual_counts[gid][role_name] or 0
                        if expected ~= actual then
                                AB_util.print(string.format("  Group %d: Role '%s' - Expected %d, Actual %d [MISMATCH]", gid, role_name, expected, actual))
                                mismatches = mismatches + 1
                        elseif AutoBand.debugon and expected > 0 then
                 AB_util.print(string.format("  Group %d: Role '%s' - Expected %d, Actual %d [OK]", gid, role_name, expected, actual))
            end
                end
                local expected_size = #(wb_dist_expected_roles[gid] or {})
                local actual_size = #(wb_obj_after_moves.group[gid] or {})
                if expected_size ~= actual_size then
                        AB_util.print(string.format("  Group %d: Size - Expected %d, Actual %d [SIZE MISMATCH]", gid, expected_size, actual_size))
                        mismatches = mismatches + 1
        elseif AutoBand.debugon then
            AB_util.print(string.format("  Group %d: Size - Expected %d, Actual %d [OK]", gid, expected_size, actual_size))
        end
        end

        if mismatches == 0 then
                AB_util.print("Verification: Organization matches expected distribution.")
                return true
        else
                AB_util.print("Verification: " .. mismatches .. " mismatch(es) found.")
                return false
        end
end

--------------------------------------------------------------------
-- enqueues a swap player command
--------------------------------------------------------------------
function AB_org.swap_players(wb_current_groups_sim_param, p1_edge_orig, p2_edge_orig)
    if not (p1_edge_orig and p1_edge_orig.name and p2_edge_orig and p2_edge_orig.name) then
        if AutoBand.debugon then AB_util.print("AB_org.swap_players: Invalid edge data received.") end
        return
    end

    local p1_name_to_swap = p1_edge_orig.name
    local p2_name_to_swap = p2_edge_orig.name

    local p1_current_gid_sim, p1_idx_sim, p1_obj_sim_ref = nil, nil, nil
    local p2_current_gid_sim, p2_idx_sim, p2_obj_sim_ref = nil, nil, nil

    if wb_current_groups_sim_param then
        for gid_s = 1, #wb_current_groups_sim_param do
            if wb_current_groups_sim_param[gid_s] then
                for idx_s, player_in_sim_group in ipairs(wb_current_groups_sim_param[gid_s]) do
                    if player_in_sim_group and player_in_sim_group.name then
                        if player_in_sim_group.name == p1_name_to_swap then
                            p1_obj_sim_ref = player_in_sim_group
                            p1_current_gid_sim = gid_s
                            p1_idx_sim = idx_s
                        end
                        if player_in_sim_group.name == p2_name_to_swap then
                            p2_obj_sim_ref = player_in_sim_group
                            p2_current_gid_sim = gid_s
                            p2_idx_sim = idx_s
                        end
                    end
                end
            end
        end
    elseif AutoBand.debugon then
        AB_util.print("AB_org.swap_players (Debug): wb_current_groups_sim_param is nil!")
    end

    if p1_obj_sim_ref and p2_obj_sim_ref and p1_current_gid_sim and p2_current_gid_sim and p1_idx_sim and p2_idx_sim then
        if p1_current_gid_sim == p2_current_gid_sim and p1_idx_sim == p2_idx_sim then
            if AutoBand.debugon then
                AB_util.print(string.format("Debug Swap (Sim): Attempt to swap player %s with themself. Skipping simulation.", tostring(p1_name_to_swap)))
            end
        else
            if AutoBand.debugon then
                AB_util.print(string.format("Debug Swap (Sim): Swapping %s (found in G%d[%d]) with %s (found in G%d[%d])",
                                tostring(p1_name_to_swap), p1_current_gid_sim, p1_idx_sim,
                                tostring(p2_name_to_swap), p2_current_gid_sim, p2_idx_sim))
            end
            -- Perform swap in wb_current_groups_sim_param by swapping the actual player objects/references
            local temp_obj_for_swap = wb_current_groups_sim_param[p1_current_gid_sim][p1_idx_sim]
            wb_current_groups_sim_param[p1_current_gid_sim][p1_idx_sim] = wb_current_groups_sim_param[p2_current_gid_sim][p2_idx_sim]
            wb_current_groups_sim_param[p2_current_gid_sim][p2_idx_sim] = temp_obj_for_swap
        end
    else
        if AutoBand.debugon then
            AB_util.print(string.format("Debug Swap Failed (Sim): Could not find one/both players for swap by name within simulation table. P1 '%s' (found in G%s[%s]). P2 '%s' (found in G%s[%s])",
                            tostring(p1_name_to_swap), tostring(p1_current_gid_sim), tostring(p1_idx_sim),
                            tostring(p2_name_to_swap), tostring(p2_current_gid_sim), tostring(p2_idx_sim)))
        end
    end
    -- Always enqueue the actual game command based on player names
    -- Skip enqueue during simulation-only runs
    if AutoBand and AutoBand.simulate_only then return end
    if (AutoBand.live_org_verbose and not AutoBand.debugon) then
        AB_util.print(string.format("LiveOrg: Enqueue Swap - %s with %s", tostring(p1_name_to_swap), tostring(p2_name_to_swap)))
    end
    AutoBand.enqueue_command(L"/warbandswap " .. towstring(p1_name_to_swap) .. L" " .. towstring(p2_name_to_swap))
    -- Clear leader hint
    AutoBand.organizer_leader_name = nil
end

--------------------------------------------------------------------
-- enqueues a move player command
--------------------------------------------------------------------
function AB_org.move_player(wb_current_groups_sim_param, p_edge)
    if not p_edge or not p_edge.name or not p_edge.fromgid or not p_edge.togid then
        if AutoBand.debugon then AB_util.debug("AB_org.move_player: Invalid edge data for move.") end
        return
    end

    local p_found_idx_sim = nil
    local p_current_gid_sim = nil -- Find current GID in simulation
    local player_obj_to_move_sim = nil

    if wb_current_groups_sim_param then
        for gid_s = 1, #wb_current_groups_sim_param do
            if wb_current_groups_sim_param[gid_s] then
                for idx_s, player_in_sim_group in ipairs(wb_current_groups_sim_param[gid_s]) do
                    if player_in_sim_group and player_in_sim_group.name == p_edge.name then
                        player_obj_to_move_sim = player_in_sim_group
                        p_current_gid_sim = gid_s
                        p_found_idx_sim = idx_s
                        break
                    end
                end
            end
            if player_obj_to_move_sim then break end
        end
    elseif AutoBand.debugon then
        AB_util.print("AB_org.move_player (Debug): wb_current_groups_sim_param is nil!")
    end

    if player_obj_to_move_sim and p_current_gid_sim and p_found_idx_sim then
        if AutoBand.debugon then
            AB_util.print(string.format("Debug Move (Sim): %s from G%d[%d] -> G%d",
                            tostring(p_edge.name), p_current_gid_sim, p_found_idx_sim, p_edge.togid))
        end
        if wb_current_groups_sim_param[p_edge.togid] then
            local moved_player_obj_actual = table.remove(wb_current_groups_sim_param[p_current_gid_sim], p_found_idx_sim)
            if moved_player_obj_actual then
                table.insert(wb_current_groups_sim_param[p_edge.togid], moved_player_obj_actual)
            elseif AutoBand.debugon then
                AB_util.print(string.format("Debug Move Failed (Sim): Could not remove %s from G%d for simulation.", tostring(p_edge.name), p_current_gid_sim))
            end
        elseif AutoBand.debugon then
            AB_util.print(string.format("Debug Move Failed (Sim): Target group G%d does not exist in wb_current_groups_sim_param.", p_edge.togid))
        end
    elseif AutoBand.debugon then
        AB_util.print(string.format("Debug Move Failed (Sim): Could not find player %s (original G%d) in current simulation state.",
                            tostring(p_edge.name), p_edge.fromgid ))
    end
    -- Always enqueue the actual game command
    -- Skip enqueue during simulation-only runs
    if AutoBand and AutoBand.simulate_only then return end
    if (AutoBand.live_org_verbose and not AutoBand.debugon) then
        AB_util.print(string.format("LiveOrg: Enqueue Move - %s from G%d to G%d", tostring(p_edge.name), p_edge.fromgid, p_edge.togid))
    end
    AutoBand.enqueue_command(L"/warbandmove " .. towstring(p_edge.name) .. L" " .. towstring(p_edge.togid), 3)
end

--------------------------------------------------------------------
-- close your eyes
-- return 2 or 3 if a cycle was found, param "cycle" contains the edges
-- return 0 if all edges were visited
--------------------------------------------------------------------
function AB_org.search(cycle, moves, node_edges)
    if not node_edges then return 0 end

    -- Check for a visited edge (that means a cycle detected deeper in recursion)
    for _, edge in pairs(node_edges) do
        if edge and edge.color == AB_org.EC_VISITED then -- This edge is part of the current path being explored from an ancestor
            edge.color = AB_org.EC_CYCLE      -- Mark this specific edge as completing the cycle
            if AutoBand.debugon then
                -- 'cycle' (the function argument) is the path BUILT SO FAR by the CALLER.
                -- This 'edge' is what CLOSES it from the perspective of the current node_edges.
                AB_util.debug(string.format("Search: Cycle Trigger! Edge %s(G%d->G%d) in current node's edges was already EC_VISITED (part of current exploration path). Marking it EC_CYCLE.",
                                tostring(edge.name), edge.fromgid, edge.togid))
            end
            return 2 -- Signal that a cycle has been detected and this edge is the one that closed it
        end
    end

    -- For every outgoing edge from the current conceptual 'node'
    for _, edge in pairs(node_edges) do
        if edge and edge.color == AB_org.EC_CLEAR then  -- if edge is not yet processed
            edge.color = AB_org.EC_VISITED  -- Mark as visited for THIS path exploration
            if AutoBand.debugon then
                AB_util.debug(string.format("Search: Traversing %s(G%d->G%d), marked EC_VISITED. Current path to here (cycle var): { %s }",
                                tostring(edge.name), edge.fromgid, edge.togid, table.concat(cycle_debug_str(cycle), ", ")))
            end

            local target_node_edges = edge.to -- This should be grp_out[edge.togid]
            local ret = AB_org.search(cycle, moves, target_node_edges) -- Recursive call

            if (ret == 2) then -- Cycle detected and being unwound
                table.insert(cycle, 1, edge) -- Prepend this edge to the path constructing the cycle
                if (edge.color == AB_org.EC_VISITED) then -- This edge is on the path that led to the cycle detection point
                    edge.color = AB_org.EC_CYCLE
                    if AutoBand.debugon then
                        AB_util.debug(string.format("Search: Edge %s(G%d->G%d) is part of cycle path, marked EC_CYCLE. Propagating cycle detection. Cycle so far: { %s }",
                                        tostring(edge.name), edge.fromgid, edge.togid, table.concat(cycle_debug_str(cycle), " -> ")))
                    end
                    return 2 -- Still unwinding the cycle path
                else -- edge.color was already EC_CYCLE (set by the first 'for' loop if 'edge' itself was the cycle trigger for a child path)
                     -- This typically means the cycle is now fully identified by the 'cycle' table.
                    if AutoBand.debugon then
                        AB_util.debug(string.format("Search: Edge %s(G%d->G%d) completes the cycle. Cycle identified: { %s }",
                                        tostring(edge.name), edge.fromgid, edge.togid, table.concat(cycle_debug_str(cycle), " -> ")))
                    end
                    return 3 -- Cycle found and identified, path is in 'cycle'
                end
            elseif (ret == 3) then -- A cycle was found, closed, and this edge is part of the path leading to it but not *in* it.
                edge.color = AB_org.EC_CLEAR -- Clear this edge, it's not part of the cycle itself, just led to one.
                if AutoBand.debugon then
                    AB_util.debug(string.format("Search: Edge %s(G%d->G%d) was on path to a completed cycle, reset to EC_CLEAR.",
                                    tostring(edge.name), edge.fromgid, edge.togid))
                end
                return 3 -- Propagate "cycle closed" signal
            elseif (ret == 0) then -- DFS on this branch (edge) completed without finding a cycle
                edge.color = AB_org.EC_DEADEND -- Mark this edge as leading to a dead end
                table.insert(moves, edge)   -- This edge represents a direct move operation
                if AutoBand.debugon then
                    AB_util.debug(string.format("Search: Edge %s(G%d->G%d) is DEAD_END, added to move_list.",
                                    tostring(edge.name), edge.fromgid, edge.togid))
                end
                -- Continue to check other clear edges from the current node_edges
            end
        end
    end
    return 0 -- All clear edges from this node have been processed
end

