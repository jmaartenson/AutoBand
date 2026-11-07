-- AB_template.lua

AB_template = {}

-- Helper function to pick a player for a slot
function AB_template.pick_player_for_slot(bin, target_gid, current_target_group_players_list, wb_dist_so_far)
    if not bin or #bin == 0 then
        if AutoBand.debugon then AB_util.debug("pick_player_for_slot: Bin is empty for G" .. target_gid) end
        return nil
    end

    local role_of_this_bin = bin[1].role

    local function count_career_globally(career)
        local count = 0
        if wb_dist_so_far then
            for _, grp in ipairs(wb_dist_so_far) do
                if grp then
                    for _, placed in ipairs(grp) do
                        if placed.role == role_of_this_bin and placed.career == career then
                            count = count + 1
                        end
                    end
                end
            end
        end
        return count
    end

    local function count_career_in_group(career)
        local count = 0
        if current_target_group_players_list then
            for _, p in ipairs(current_target_group_players_list) do
                if p.role == role_of_this_bin and p.career == career then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function count_healer_base_cross_role_in_group(career)
        local count = 0
        if not career or not AB_util.is_healer_base_career(career) then
            return 0
        end
        if current_target_group_players_list then
            for _, p in ipairs(current_target_group_players_list) do
                local p_career = p and (p.career or p.careerLine) or nil
                if p_career == career and p.role ~= role_of_this_bin then
                    count = count + 1
                end
            end
        end
        return count
    end

    local candidates = {}
    local live_names = {}
    if current_target_group_players_list then
        for _, lp in ipairs(current_target_group_players_list) do
            if lp and lp.name then live_names[tostring(lp.name)] = true end
        end
    end
    local leader_name_pref = AutoBand and AutoBand.organizer_leader_name and tostring(AutoBand.organizer_leader_name) or nil
    for i = #bin, 1, -1 do
        local p_entry = bin[i]
        local nm = p_entry and p_entry.name and tostring(p_entry.name) or nil
        table.insert(candidates, {
            player_data = p_entry,
            bin_index_original = i,
            global_diversity_score = count_career_globally(p_entry.career),
            intra_diversity_score = count_career_in_group(p_entry.career),
            healer_base_cross_role_score = count_healer_base_cross_role_in_group(p_entry.career),
            is_sticky_flag = (p_entry.original_gid == target_gid),
            is_sticky_live = (nm ~= nil and live_names[nm] == true),
            is_leader = (leader_name_pref ~= nil and nm == leader_name_pref) or false,
            level_raw = p_entry.level or 0,
            level_range_score = AB_util.get_level_range_score(p_entry.level or 0)
        })
    end

    if #candidates == 0 then
        if AutoBand.debugon then AB_util.debug("pick_player_for_slot: No candidates found for G" .. target_gid .. ", Role: " .. role_of_this_bin) end
        return nil
    end

    -- Stronger diversity planning: restrict to minimal intra- and global- diversity where possible
    local min_intra = nil
    local pre_count = #candidates
    for i = 1, #candidates do
        local v = candidates[i]
        if v then
            if min_intra == nil or v.intra_diversity_score < min_intra then
                min_intra = v.intra_diversity_score
            end
        end
    end
    if min_intra ~= nil then
        local filtered = {}
        for i = 1, #candidates do
            local v = candidates[i]
            if v and v.intra_diversity_score == min_intra then table.insert(filtered, v) end
        end
        if #filtered > 0 then
            if (AutoBand and AutoBand.live_org_verbose) and (#filtered < pre_count) then
                AB_util.print(string.format("Diversity (intra) pruned %d->%d for %s in G%d", pre_count, #filtered, tostring(role_of_this_bin), target_gid))
            end
            candidates = filtered
            pre_count = #candidates
        end
    end

    local min_global = nil
    for i = 1, #candidates do
        local v = candidates[i]
        if v then
            if min_global == nil or v.global_diversity_score < min_global then
                min_global = v.global_diversity_score
            end
        end
    end
    if min_global ~= nil then
        local filtered2 = {}
        for i = 1, #candidates do
            local v = candidates[i]
            if v and v.global_diversity_score == min_global then table.insert(filtered2, v) end
        end
        if #filtered2 > 0 then
            if (AutoBand and AutoBand.live_org_verbose) and (#filtered2 < pre_count) then
                AB_util.print(string.format("Diversity (global) pruned %d->%d for %s in G%d", pre_count, #filtered2, tostring(role_of_this_bin), target_gid))
            end
            candidates = filtered2
        end
    end
    pre_count = #candidates

    local min_cross_role = nil
    for i = 1, #candidates do
        local v = candidates[i]
        if v then
            if min_cross_role == nil or v.healer_base_cross_role_score < min_cross_role then
                min_cross_role = v.healer_base_cross_role_score
            end
        end
    end
    if min_cross_role ~= nil then
        local filtered3 = {}
        for i = 1, #candidates do
            local v = candidates[i]
            if v and v.healer_base_cross_role_score == min_cross_role then table.insert(filtered3, v) end
        end
        if #filtered3 > 0 then
            if (AutoBand and AutoBand.live_org_verbose) and (#filtered3 < pre_count) then
                AB_util.print(string.format("Diversity (healer-base) pruned %d->%d for %s in G%d", pre_count, #filtered3, tostring(role_of_this_bin), target_gid))
            end
            candidates = filtered3
        end
    end

    -- Leader bias: prefer to keep/move the WB leader into G1 when possible,
    -- and avoid picking the leader for non-G1 groups when other choices exist.
    if leader_name_pref then
        if target_gid == 1 then
            local has_leader = false
            for i=1,#candidates do if candidates[i].is_leader then has_leader = true; break end end
            if has_leader then
                local only_leader = {}
                for i=1,#candidates do if candidates[i].is_leader then only_leader[#only_leader+1] = candidates[i] end end
                if #only_leader > 0 then candidates = only_leader end
            end
        else
            local has_leader = false
            local filtered = {}
            for i=1,#candidates do if candidates[i].is_leader then has_leader = true else filtered[#filtered+1] = candidates[i] end end
            if has_leader and #filtered > 0 then candidates = filtered end
        end
    end

    -- If any candidates are already in the target group, restrict to those to
    -- reduce churn on repeated runs.
    do
        local any_live = false
        for i = 1, #candidates do if candidates[i].is_sticky_live then any_live = true; break end end
        if any_live then
            local filtered_live = {}
            for i = 1, #candidates do if candidates[i].is_sticky_live then table.insert(filtered_live, candidates[i]) end end
            if #filtered_live > 0 then candidates = filtered_live end
        end
    end

    table.sort(candidates, function(a, b)
        -- Prefer keeping existing members in place on re-runs
        if a.is_sticky_live ~= b.is_sticky_live then return a.is_sticky_live end

        if a.global_diversity_score ~= b.global_diversity_score then
            return a.global_diversity_score < b.global_diversity_score
        end

        if a.intra_diversity_score ~= b.intra_diversity_score then
            return a.intra_diversity_score < b.intra_diversity_score
        end

        -- Higher-level ranges take precedence (40 > 36-39 > ...)
        if a.level_range_score ~= b.level_range_score then
            return a.level_range_score > b.level_range_score
        end

        -- Then prefer stickiness by original_gid as a mild tie-breaker
        if a.is_sticky_flag ~= b.is_sticky_flag then
            return a.is_sticky_flag
        end

        if a.level_raw ~= b.level_raw then
            return a.level_raw > b.level_raw
        end

        return a.bin_index_original > b.bin_index_original
    end)

    local best = candidates[1]
    local picked_player = table.remove(bin, best.bin_index_original)

    if (AutoBand.debugon or AutoBand.live_org_verbose) and picked_player then
        local name_str = picked_player.name and tostring(picked_player.name) or "UnknownName"
        local role_str = picked_player.role or "UnknownRole"
        local career_str = picked_player.career and (AutoBand.GetCareerName and AutoBand.GetCareerName(picked_player.career) or picked_player.career) or "UnkCareer"
        local lvl_str = picked_player.level or "??"
        local orig_g_str = picked_player.original_gid or "?"
        local sticky_tag_log = best.is_sticky_flag and " [STICKY]" or ""
        local dist_tag = nil
        if AB_org and AB_org.is_distance_sort_active and AB_org._distance_phase then
            if AB_org._distance_phase == 'far' then dist_tag = '[dist:far] '
            elseif AB_org._distance_phase == 'close' then dist_tag = '[dist:close] ' end
        end
        AB_util.print(string.format("%sPicked for G%d: %s (Role:%s, Career:%s, Lvl:%s, OrigG:%s) DivG:%d DivL:%d%s",
            dist_tag or '', target_gid, name_str, role_str, career_str, lvl_str, orig_g_str,
            best.global_diversity_score, best.intra_diversity_score, sticky_tag_log))
    end

    return picked_player
end

function AB_template.from_wb(wb_obj, valid_groups)
  if (valid_groups == nil) then
    valid_groups = {}
    for i = 1, wb_obj.MAX_GROUPS do
      valid_groups[i] = true
    end
  end
  local newwb = {}
  for i = 1, wb_obj.MAX_GROUPS do newwb[i] = {} end
  wb_obj:foreach_player(
    function(gid, player)
      if (valid_groups[gid] ~= nil) then
        table.insert(newwb[gid], {["role"] = player.role})
      end
    end
  )
  return newwb
end

function AB_template.find_min_groupid_strict(role_id_to_place, num_groups_to_consider, sorted_group_list, current_wb_dist, role_counts_per_group)
    local opt_role_ratio = AB_const.GROUP_SIZE + 1
    local opt_overall_size = AB_const.GROUP_SIZE + 1
    local opt_gid = -1

    -- Only consider the top 'num_groups_to_consider' from the sorted list (sorted by overall emptiness)
    for i = 1, math.min(num_groups_to_consider, #sorted_group_list) do
        local current_gid_struct = sorted_group_list[i]
        local gid = current_gid_struct.id
        if not current_wb_dist[gid] then current_wb_dist[gid] = {} end -- Ensure group exists for size check

        if #current_wb_dist[gid] < AB_const.GROUP_SIZE then -- Only consider groups with space
            local current_role_count_in_group = role_counts_per_group[role_id_to_place][gid]
            local current_total_players_in_group = #current_wb_dist[gid]

            if (current_role_count_in_group < opt_role_ratio) then
                opt_role_ratio = current_role_count_in_group
                opt_gid = gid
                opt_overall_size = current_total_players_in_group
            elseif (current_role_count_in_group == opt_role_ratio) then
                -- Tie on role count, prefer group with fewer total players
                if (current_total_players_in_group < opt_overall_size) then
                    opt_gid = gid
                    opt_overall_size = current_total_players_in_group
                elseif (current_total_players_in_group == opt_overall_size and gid < opt_gid) then
                    -- Tie on role count and total size, prefer lower group ID
                    opt_gid = gid
                end
            end
        end
    end

    if opt_gid == -1 and AutoBand.debugon then
        AB_util.debug("find_min_groupid_strict: Could not find suitable group for role " .. role_id_to_place .. " within the " .. num_groups_to_consider .. " target groups that have space.")
    end
    return opt_gid
end

function AB_template.find_max_groupid_strict(role_id_to_place, num_groups_to_consider, sorted_group_list, current_wb_dist, role_counts_per_group)
    local opt_role_ratio = -1
    local opt_overall_size = -1
    local opt_gid = -1

    for i = 1, math.min(num_groups_to_consider, #sorted_group_list) do
        local current_gid_struct = sorted_group_list[i]
        local gid = current_gid_struct.id
        if not current_wb_dist[gid] then current_wb_dist[gid] = {} end

        if #current_wb_dist[gid] < AB_const.GROUP_SIZE then -- Only consider groups with space
            local current_role_count_in_group = role_counts_per_group[role_id_to_place][gid]
            local current_total_players_in_group = #current_wb_dist[gid]

            if (current_role_count_in_group > opt_role_ratio) then
                opt_role_ratio = current_role_count_in_group
                opt_gid = gid
                opt_overall_size = current_total_players_in_group
            elseif (current_role_count_in_group == opt_role_ratio) then
                -- Tie on role count
                if (opt_role_ratio == 0 and current_total_players_in_group < opt_overall_size) then
                    -- If no group has this role yet, prefer emptier group overall
                    opt_gid = gid
                    opt_overall_size = current_total_players_in_group
                elseif (opt_role_ratio > 0 and current_total_players_in_group > opt_overall_size) then
                    -- If groups already have this role, prefer fuller group overall (to stack more)
                     opt_gid = gid
                     opt_overall_size = current_total_players_in_group
                elseif (current_total_players_in_group == opt_overall_size and gid > opt_gid) then
                    -- Tie on role count and effective total size consideration, prefer higher group ID
                    opt_gid = gid
                end
            end
        end
    end
    if opt_gid == -1 and AutoBand.debugon then
         AB_util.debug("find_max_groupid_strict: Could not find suitable group for role " .. role_id_to_place .. " within the " .. num_groups_to_consider .. " target groups that have space.")
    end
    return opt_gid
end

function AB_template.match(wb_obj, wb_dist, roles_not_taken, bins, temp_definition, max_target_groups_override)
  AB_util.debug("AB_template.match: init. WB player count: " .. wb_obj.player_count .. ", max_target_groups_override=" .. tostring(max_target_groups_override))

  local effective_max_groups = max_target_groups_override or AB_const.MAX_WB_GROUPS

  local role_per_group = {}
  for _, rid in pairs(AB_const.ROLE_CATEGORIES) do
    role_per_group[rid] = {}
    for i = 1, effective_max_groups do role_per_group[rid][i] = 0 end
  end

  local group_ids_sorted_by_fullness = {}
  for i = 1, effective_max_groups do
        if not wb_dist[i] then wb_dist[i] = {} end
    table.insert(group_ids_sorted_by_fullness, {id = i, current_size_in_wb_dist = #wb_dist[i]})
  end
  table.sort(group_ids_sorted_by_fullness, function(a,b)
    return a.current_size_in_wb_dist < b.current_size_in_wb_dist or
       (a.current_size_in_wb_dist == b.current_size_in_wb_dist and a.id < b.id)
  end)

  local template_size = AB_util.size_wb(temp_definition)
  local players_placed_by_template = 0
  local watchdog_triggered_in_template = false

  if (template_size > 0 and temp_definition) then
    AB_util.debug("AB_template.match: Applying template. Template total slots: " .. template_size)
    local loop_watchdog = 0

    for tgid = 1, #temp_definition do
      if watchdog_triggered_in_template then break end
            if not wb_dist[tgid] then wb_dist[tgid] = {} end

      local template_group_roles = temp_definition[tgid]
      if template_group_roles then
        for _, role_entry_in_template in ipairs(template_group_roles) do
          loop_watchdog = loop_watchdog + 1
          if (loop_watchdog > template_size + AB_const.LOOP_MAX + AB_const.GROUP_SIZE * effective_max_groups) then
            AB_util.debug("****[ERROR] AB_template.match (template loop): Watchdog. Placed by template: " .. players_placed_by_template)
            watchdog_triggered_in_template = true
            break
          end

          local role_to_fill = role_entry_in_template.role
          local role_id_for_bin = AB_const.ROLE_CATEGORIES[role_to_fill]

          if role_id_for_bin and bins[role_id_for_bin] and #bins[role_id_for_bin] > 0 then
            if #wb_dist[tgid] < AB_const.GROUP_SIZE then
              -- Pass current state of wb_dist[tgid] (list of player objects)
              local picked_player_obj = AB_template.pick_player_for_slot(bins[role_id_for_bin], tgid, wb_dist[tgid], wb_dist)
              if picked_player_obj then
                table.insert(wb_dist[tgid], picked_player_obj) -- Store the full player object
                table.insert(roles_not_taken[picked_player_obj.role], tgid) -- This stores the GID where the role is now filled
                role_per_group[role_id_for_bin][tgid] = role_per_group[role_id_for_bin][tgid] + 1
                players_placed_by_template = players_placed_by_template + 1
                for _, g_entry in ipairs(group_ids_sorted_by_fullness) do
                  if g_entry.id == tgid then
                    g_entry.current_size_in_wb_dist = #wb_dist[tgid]
                    break
                  end
                end
              else
                AB_util.debug("AB_template.match (template): Could not pick player for role " .. role_to_fill .. " in G" .. tgid)
              end
            else
              AB_util.debug("AB_template.match (template): Wants role " .. role_to_fill .. " in G" .. tgid .. " but group is full in wb_dist.")
            end
          else
            AB_util.debug("AB_template.match (template): No players in bin for role " .. role_to_fill .. " (ID: " .. tostring(role_id_for_bin) .. ") or invalid role_id for G" .. tgid)
          end
        end
      end
    end
    for i=1, #group_ids_sorted_by_fullness do
      group_ids_sorted_by_fullness[i].current_size_in_wb_dist = #wb_dist[group_ids_sorted_by_fullness[i].id]
    end
    table.sort(group_ids_sorted_by_fullness, function (a, b)
      return (a.current_size_in_wb_dist < b.current_size_in_wb_dist or
         (a.current_size_in_wb_dist == b.current_size_in_wb_dist and a.id < b.id))
    end)
    AB_util.debug("AB_template.match: After template fill, " .. players_placed_by_template .. " players placed. wb_dist total: " .. AB_util.size_wb(wb_dist))
  end

    local total_players = wb_obj.player_count
    local num_groups_that_can_be_full = math.floor(total_players / AB_const.GROUP_SIZE)
    local has_partial_group_val = (total_players % AB_const.GROUP_SIZE) > 0

    local primary_target_group_count = num_groups_that_can_be_full
    if total_players > 0 and num_groups_that_can_be_full == 0 then
        primary_target_group_count = 1
    end
    if total_players == 0 then
        primary_target_group_count = 0
    end

    AB_util.debug("AB_template.match: Total players: " .. total_players ..
                  ", Num groups that can be full: " .. num_groups_that_can_be_full ..
                  ", Has partial group: " .. tostring(has_partial_group_val) ..
                  ", Primary target group count for role dist: " .. primary_target_group_count)

    local ngrp_for_main_distribution = 0
    if primary_target_group_count > 0 then
        for i = 1, math.min(primary_target_group_count, #group_ids_sorted_by_fullness) do
            local gid_to_check = group_ids_sorted_by_fullness[i].id
            if not wb_dist[gid_to_check] then wb_dist[gid_to_check] = {} end
            if #wb_dist[gid_to_check] < AB_const.GROUP_SIZE then
                ngrp_for_main_distribution = ngrp_for_main_distribution + 1
            end
        end
    end
    AB_util.debug("AB_template.match: ngrp_for_main_distribution (num primary target groups with space): " .. ngrp_for_main_distribution)

    if ngrp_for_main_distribution == 0 and primary_target_group_count > 0 and AB_util.size_wb(bins) > 0 then
         AB_util.debug("AB_template.match: Primary " .. primary_target_group_count .. " groups for role distribution are already full or have no space. Main distribution might be skipped.")
    end

    local slots_in_primary_groups = 0
    if ngrp_for_main_distribution > 0 then
        for i = 1, ngrp_for_main_distribution do
            local gid_struct_idx = group_ids_sorted_by_fullness[i]
            if gid_struct_idx then -- Ensure the entry exists in the sorted list
                local gid_to_check = gid_struct_idx.id
                if wb_dist[gid_to_check] then
                     slots_in_primary_groups = slots_in_primary_groups + (AB_const.GROUP_SIZE - #wb_dist[gid_to_check])
                end
            else
                AB_util.debug("AB_template.match: Warning - group_ids_sorted_by_fullness["..i.."] is nil when calculating slots_in_primary_groups.")
            end
        end
    end

    local max_players_for_main_dist = math.min(AB_util.size_wb(bins), slots_in_primary_groups)
    AB_util.debug("AB_template.match: Max players for main distribution phase: " .. max_players_for_main_dist)


  if (AB_util.size_wb(bins) > 0 and ngrp_for_main_distribution > 0 and max_players_for_main_dist > 0) then
    AB_util.debug("AB_template.match: Proceeding to main distribution. Algorithm: " .. AutoBand.saved.org_algo_mode .. ". Targeting " .. ngrp_for_main_distribution .. " groups, for up to " .. max_players_for_main_dist .. " players.")
    if (AutoBand.saved.org_algo_mode == AB_const.MODE_SPREAD) then
      AB_template.from_bins_spread(wb_obj, wb_dist, roles_not_taken, bins, role_per_group, ngrp_for_main_distribution, group_ids_sorted_by_fullness, max_players_for_main_dist)
    else
      AB_template.from_bins_aggregate(wb_obj, wb_dist, roles_not_taken, bins, role_per_group, ngrp_for_main_distribution, group_ids_sorted_by_fullness, max_players_for_main_dist)
    end
  end

  local left_over_count = AB_util.size_wb(bins)
  if (left_over_count > 0) then
    AB_util.debug("AB_template.match: " .. left_over_count .. " players leftover. Attempting to place.")
    local initial_target_gid_for_leftover = -1
        local max_total_groups_to_use_for_leftovers = num_groups_that_can_be_full + (has_partial_group_val and 1 or 0)
        if total_players > 0 and num_groups_that_can_be_full == 0 and has_partial_group_val then
            max_total_groups_to_use_for_leftovers = 1
        elseif total_players == 0 then
            max_total_groups_to_use_for_leftovers = 0
        end
        max_total_groups_to_use_for_leftovers = math.min(max_total_groups_to_use_for_leftovers, effective_max_groups)


    for i=1, #group_ids_sorted_by_fullness do
            local gid_ref = group_ids_sorted_by_fullness[i].id
            if not wb_dist[gid_ref] then wb_dist[gid_ref] = {} end
            group_ids_sorted_by_fullness[i].current_size_in_wb_dist = #wb_dist[gid_ref]
    end
    table.sort(group_ids_sorted_by_fullness, function(a,b) return a.current_size_in_wb_dist < b.current_size_in_wb_dist or (a.current_size_in_wb_dist == b.current_size_in_wb_dist and a.id < b.id) end)

        if has_partial_group_val and num_groups_that_can_be_full < effective_max_groups then
            local partial_gid_candidate = num_groups_that_can_be_full + 1
            if partial_gid_candidate <= max_total_groups_to_use_for_leftovers then -- Ensure candidate is within allowed range
                if not wb_dist[partial_gid_candidate] then wb_dist[partial_gid_candidate] = {} end
                if #wb_dist[partial_gid_candidate] < AB_const.GROUP_SIZE then
                    initial_target_gid_for_leftover = partial_gid_candidate
                end
            end
        end

        if initial_target_gid_for_leftover == -1 then
            for i = 1, max_total_groups_to_use_for_leftovers do
                local gid_struct = group_ids_sorted_by_fullness[i]
                if gid_struct then
                    local gid_to_check = gid_struct.id
                    if not wb_dist[gid_to_check] then wb_dist[gid_to_check] = {} end
                    if #wb_dist[gid_to_check] < AB_const.GROUP_SIZE then
                        initial_target_gid_for_leftover = gid_to_check
                        break
                    end
                end
            end
            AB_util.debug("AB_template.match: Leftovers fallback initial_target_gid: " .. tostring(initial_target_gid_for_leftover))
        else
             AB_util.debug("AB_template.match: Leftovers initial_target_gid (partial): " .. initial_target_gid_for_leftover)
        end

    if initial_target_gid_for_leftover ~= -1 and max_total_groups_to_use_for_leftovers > 0 then
      AB_template.left_over(wb_obj, wb_dist, roles_not_taken, bins, initial_target_gid_for_leftover, max_total_groups_to_use_for_leftovers)
    else
      AB_util.debug("AB_template.match: No group found for leftovers or max_total_groups_to_use is 0. " .. left_over_count .. " players remain unplaced.")
    end
  end
  AB_util.debug("AB_template.match: Final wb_dist total players: " .. AB_util.size_wb(wb_dist))
  if AutoBand.debugon then AB_util.print_wb(wb_dist) end
end

function AB_template.from_bins_spread(_wb_obj, wb_dist, roles_not_taken, bins, role_per_group, ngrp, group_ids_sorted_by_initial_fullness, max_players_to_place_in_this_phase)
  AB_util.debug("from_bins_spread: ngrp=" .. ngrp .. ", max_players_to_place_in_this_phase=" .. tostring(max_players_to_place_in_this_phase))
  local players_placed_in_this_func = 0

  if not max_players_to_place_in_this_phase or max_players_to_place_in_this_phase <= 0 then
        AB_util.debug("from_bins_spread: No players to place in this phase or no slots in target groups.")
        return
    end

  local bid = 1
  local loop_watchdog = 0
  local effective_ngrp_for_find = ngrp

  -- Optional per-group role caps: applied when totals divide evenly across target groups
  local tank_cap, heal_cap, dps_cap = nil, nil, nil
    -- Tanks
    local rid_tank = AB_const.ROLE_CATEGORIES[AB_const.TANK]
    local placed_tanks_total = 0
    for i_cap = 1, #role_per_group[rid_tank] do placed_tanks_total = placed_tanks_total + (role_per_group[rid_tank][i_cap] or 0) end
    local remaining_tanks = (bins[rid_tank] and #bins[rid_tank]) or 0
    local total_tanks = placed_tanks_total + remaining_tanks
    if effective_ngrp_for_find and effective_ngrp_for_find > 0 and total_tanks > 0 and (total_tanks % effective_ngrp_for_find == 0) then
      tank_cap = math.floor(total_tanks / effective_ngrp_for_find)
      if tank_cap <= 0 then tank_cap = nil end
    end
    -- Healers
    local rid_heal = AB_const.ROLE_CATEGORIES[AB_const.HEALER]
    local placed_heal_total = 0
    for i_cap = 1, #role_per_group[rid_heal] do placed_heal_total = placed_heal_total + (role_per_group[rid_heal][i_cap] or 0) end
    local remaining_heal = (bins[rid_heal] and #bins[rid_heal]) or 0
    local total_heal = placed_heal_total + remaining_heal
    if effective_ngrp_for_find and effective_ngrp_for_find > 0 and total_heal > 0 and (total_heal % effective_ngrp_for_find == 0) then
      heal_cap = math.floor(total_heal / effective_ngrp_for_find)
      if heal_cap <= 0 then heal_cap = nil end
    end
    -- DPS (combined MDPS+RDPS)
    local rid_mdps = AB_const.ROLE_CATEGORIES[AB_const.MDPS]
    local rid_rdps = AB_const.ROLE_CATEGORIES[AB_const.RDPS]
    local placed_mdps_total, placed_rdps_total = 0, 0
    for i_cap = 1, #role_per_group[rid_mdps] do placed_mdps_total = placed_mdps_total + (role_per_group[rid_mdps][i_cap] or 0) end
    for i_cap = 1, #role_per_group[rid_rdps] do placed_rdps_total = placed_rdps_total + (role_per_group[rid_rdps][i_cap] or 0) end
    local remaining_mdps = (bins[rid_mdps] and #bins[rid_mdps]) or 0
    local remaining_rdps = (bins[rid_rdps] and #bins[rid_rdps]) or 0
    local total_dps = placed_mdps_total + placed_rdps_total + remaining_mdps + remaining_rdps
    if effective_ngrp_for_find and effective_ngrp_for_find > 0 and total_dps > 0 and (total_dps % effective_ngrp_for_find == 0) then
      dps_cap = math.floor(total_dps / effective_ngrp_for_find)
      if dps_cap <= 0 then dps_cap = nil end
    end
  if AutoBand.live_org_verbose then
    AB_util.print("Spread Caps (ngrp=" .. tostring(effective_ngrp_for_find) .. "): tank=" .. tostring(tank_cap) .. ", heal=" .. tostring(heal_cap) .. ", dps=" .. tostring(dps_cap))
  end

  while players_placed_in_this_func < max_players_to_place_in_this_phase do
    loop_watchdog = loop_watchdog + 1
    if loop_watchdog > max_players_to_place_in_this_phase * 4 * 2 + AB_const.LOOP_MAX then
      AB_util.debug("****[ERROR] from_bins_spread: Watchdog. Placed: " .. players_placed_in_this_func .. "/" .. max_players_to_place_in_this_phase .. ". Bins left: " .. AB_util.size_wb(bins))
      break
    end

        if AB_util.size_wb(bins) == 0 then
            AB_util.debug("from_bins_spread: All bins empty. Placed: " .. players_placed_in_this_func)
            break
        end

    local current_role_bin = bins[bid]
    if current_role_bin and #current_role_bin > 0 then
      local opt_gid = AB_template.find_min_groupid_strict(bid, effective_ngrp_for_find, group_ids_sorted_by_initial_fullness, wb_dist, role_per_group)

      -- If applying caps for tanks, and chosen group already reached cap, try to pick another eligible group under the cap
      if tank_cap and bid == AB_const.ROLE_CATEGORIES[AB_const.TANK] and opt_gid and opt_gid ~= -1 then
        local current_count_in_opt = role_per_group[bid][opt_gid] or 0
        if current_count_in_opt >= tank_cap then
          local alt_gid = -1
          local best_role_ratio = AB_const.GROUP_SIZE + 1
          local best_total = AB_const.GROUP_SIZE + 1
          for i_sel = 1, effective_ngrp_for_find do
            local gid_struct = group_ids_sorted_by_initial_fullness[i_sel]
            if gid_struct then
              local gid_try = gid_struct.id
              if wb_dist[gid_try] and #wb_dist[gid_try] < AB_const.GROUP_SIZE then
                local role_count_here = role_per_group[bid][gid_try] or 0
                if role_count_here < tank_cap then
                  local total_players_here = #wb_dist[gid_try]
                  if (role_count_here < best_role_ratio) or (role_count_here == best_role_ratio and total_players_here < best_total) then
                    best_role_ratio = role_count_here
                    best_total = total_players_here
                    alt_gid = gid_try
                  end
                end
              end
            end
          end
          if alt_gid ~= -1 then
            if AutoBand.debugon then AB_util.debug("from_bins_spread: tank cap redirect from G" .. opt_gid .. " to G" .. alt_gid .. " (cap=" .. tank_cap .. ")") end
            opt_gid = alt_gid
          else
            if AutoBand.live_org_verbose then AB_util.print("Tank cap: no under-cap group found; keeping G" .. opt_gid .. " (count=" .. current_count_in_opt .. ")") end
          end
        else
          if AutoBand.live_org_verbose then AB_util.print("Tank cap OK: G" .. opt_gid .. " has " .. current_count_in_opt .. "/" .. tank_cap) end
        end
      end

      -- Reservation rule: for non-role caps, avoid consuming the last slot(s) needed for other capped roles in any group
      local has_any_cap = (tank_cap ~= nil) or (heal_cap ~= nil) or (dps_cap ~= nil)
      local function need_tank(gid)
        if not tank_cap then return 0 end
        local placed = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.TANK]][gid] or 0
        local need = tank_cap - placed
        return (need > 0) and need or 0
      end
      local function need_heal(gid)
        if not heal_cap then return 0 end
        local placed = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.HEALER]][gid] or 0
        local need = heal_cap - placed
        return (need > 0) and need or 0
      end
      local function need_dps(gid)
        if not dps_cap then return 0 end
        local md = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.MDPS]][gid] or 0
        local rd = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.RDPS]][gid] or 0
        local placed = md + rd
        local need = dps_cap - placed
        return (need > 0) and need or 0
      end
      if has_any_cap and opt_gid and opt_gid ~= -1 then
        local slots_left = AB_const.GROUP_SIZE - #(wb_dist[opt_gid] or {})
        -- Compute how many slots must remain for OTHER capped roles (excluding the current role's own cap)
        local other_need = 0
        if bid ~= AB_const.ROLE_CATEGORIES[AB_const.TANK] then other_need = other_need + need_tank(opt_gid) end
        if bid ~= AB_const.ROLE_CATEGORIES[AB_const.HEALER] then other_need = other_need + need_heal(opt_gid) end
        if (bid ~= AB_const.ROLE_CATEGORIES[AB_const.MDPS]) and (bid ~= AB_const.ROLE_CATEGORIES[AB_const.RDPS]) then other_need = other_need + need_dps(opt_gid) end
        if slots_left > 0 and (slots_left - 1) < other_need then
          local alt_gid2 = -1
          local best_role_ratio2 = AB_const.GROUP_SIZE + 1
          local best_total2 = AB_const.GROUP_SIZE + 1
          -- Only consider the primary target groups during main distribution to avoid
          -- prematurely opening new groups and creating orphans.
          for i_sel2 = 1, effective_ngrp_for_find do
            local gid_struct2 = group_ids_sorted_by_initial_fullness[i_sel2]
            if gid_struct2 then
              local gid_try2 = gid_struct2.id
              if wb_dist[gid_try2] and #wb_dist[gid_try2] < AB_const.GROUP_SIZE then
                local slots_left2 = AB_const.GROUP_SIZE - #wb_dist[gid_try2]
                local other_need2 = 0
                if bid ~= AB_const.ROLE_CATEGORIES[AB_const.TANK] then other_need2 = other_need2 + need_tank(gid_try2) end
                if bid ~= AB_const.ROLE_CATEGORIES[AB_const.HEALER] then other_need2 = other_need2 + need_heal(gid_try2) end
                if (bid ~= AB_const.ROLE_CATEGORIES[AB_const.MDPS]) and (bid ~= AB_const.ROLE_CATEGORIES[AB_const.RDPS]) then other_need2 = other_need2 + need_dps(gid_try2) end
                if (slots_left2 - 1) >= other_need2 then
                  local role_count_here2 = role_per_group[bid][gid_try2] or 0
                  local total_players_here2 = #wb_dist[gid_try2]
                  if (role_count_here2 < best_role_ratio2) or (role_count_here2 == best_role_ratio2 and total_players_here2 < best_total2) then
                    best_role_ratio2 = role_count_here2
                    best_total2 = total_players_here2
                    alt_gid2 = gid_try2
                  end
                end
              end
            end
          end
          if alt_gid2 ~= -1 then
            if AutoBand.live_org_verbose then AB_util.print("Reserve caps: redirect role " .. tostring(bid) .. " from G" .. opt_gid .. " to G" .. alt_gid2) end
            opt_gid = alt_gid2
          else
            if AutoBand.live_org_verbose then AB_util.print("Reserve caps: no safe group found; using G" .. opt_gid) end
          end
        end
      end

      if opt_gid and opt_gid ~= -1 and wb_dist[opt_gid] and #wb_dist[opt_gid] < AB_const.GROUP_SIZE then
        local picked_player = AB_template.pick_player_for_slot(current_role_bin, opt_gid, wb_dist[opt_gid], wb_dist) -- Pass current state of wb_dist[opt_gid]
        if picked_player then
          -- Leader to G1 preference (if feasible within caps/reservations)
          local target_gid_for_insert = opt_gid
          local leader_name_pref2 = AutoBand and AutoBand.organizer_leader_name and tostring(AutoBand.organizer_leader_name) or nil
          if leader_name_pref2 and tostring(picked_player.name) == leader_name_pref2 and opt_gid ~= 1 and wb_dist[1] and #wb_dist[1] < AB_const.GROUP_SIZE then
            local can_use_g1 = true
            if bid == AB_const.ROLE_CATEGORIES[AB_const.TANK] and tank_cap and (role_per_group[bid][1] or 0) >= tank_cap then can_use_g1 = false end
            if bid == AB_const.ROLE_CATEGORIES[AB_const.HEALER] and heal_cap and (role_per_group[bid][1] or 0) >= heal_cap then can_use_g1 = false end
            if (bid == AB_const.ROLE_CATEGORIES[AB_const.MDPS] or bid == AB_const.ROLE_CATEGORIES[AB_const.RDPS]) and dps_cap then
              local md = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.MDPS]][1] or 0
              local rd = role_per_group[AB_const.ROLE_CATEGORIES[AB_const.RDPS]][1] or 0
              if (md + rd) >= dps_cap then can_use_g1 = false end
            end
            if can_use_g1 and has_any_cap then
              local slots_left_g1 = AB_const.GROUP_SIZE - #(wb_dist[1] or {})
              local other_need2 = 0
              if bid ~= AB_const.ROLE_CATEGORIES[AB_const.TANK] then other_need2 = other_need2 + need_tank(1) end
              if bid ~= AB_const.ROLE_CATEGORIES[AB_const.HEALER] then other_need2 = other_need2 + need_heal(1) end
              if (bid ~= AB_const.ROLE_CATEGORIES[AB_const.MDPS]) and (bid ~= AB_const.ROLE_CATEGORIES[AB_const.RDPS]) then other_need2 = other_need2 + need_dps(1) end
              if (slots_left_g1 - 1) < other_need2 then can_use_g1 = false end
            end
            if can_use_g1 then target_gid_for_insert = 1 end
          end
          table.insert(wb_dist[target_gid_for_insert], picked_player) -- Store the full player object
          table.insert(roles_not_taken[picked_player.role], target_gid_for_insert)
          role_per_group[bid][target_gid_for_insert] = role_per_group[bid][target_gid_for_insert] + 1
          for _, g_entry in ipairs(group_ids_sorted_by_initial_fullness) do if g_entry.id == target_gid_for_insert then g_entry.current_size_in_wb_dist = #wb_dist[target_gid_for_insert]; break; end end
          players_placed_in_this_func = players_placed_in_this_func + 1
        else
                    if AutoBand.debugon then AB_util.debug("from_bins_spread: pick_player_for_slot returned nil for role " .. bid .. " in G" .. opt_gid) end
                end
      else
        if AutoBand.debugon then
                    if opt_gid and opt_gid ~= -1 and wb_dist[opt_gid] then
                        AB_util.debug("from_bins_spread: Opt GID " .. opt_gid .. " is full (#" .. #wb_dist[opt_gid] .. ") or find_min_groupid_strict returned no valid group for role " .. bid .. " within the " .. effective_ngrp_for_find .. " target groups.")
                    elseif opt_gid == -1 then
                        AB_util.debug("from_bins_spread: find_min_groupid_strict returned -1 for role " .. bid .. " within " .. effective_ngrp_for_find .. " groups. Bin size " .. #current_role_bin)
                    else
                         AB_util.debug("from_bins_spread: Opt GID " .. tostring(opt_gid) .. " issue for role " .. bid .. "; bin size: " .. #current_role_bin)
                    end
                end
      end
    end

    bid = bid + 1
    if bid > 4 then bid = 1; end
  end
  AB_util.debug("from_bins_spread: Finished. Players placed in this phase: " .. players_placed_in_this_func .. " (target: " .. max_players_to_place_in_this_phase .. ")")
end

function AB_template.from_bins_aggregate(_wb_obj, wb_dist, roles_not_taken, bins, role_per_group, ngrp, group_ids_sorted_by_initial_fullness, max_players_to_place_in_this_phase)
  AB_util.debug("from_bins_aggregate: ngrp=" .. ngrp .. ", max_players_to_place_in_this_phase=" .. tostring(max_players_to_place_in_this_phase))
  local players_placed_in_this_func = 0

  if not max_players_to_place_in_this_phase or max_players_to_place_in_this_phase <= 0 then
        AB_util.debug("from_bins_aggregate: No players to place in this phase.")
        return
    end

  local bid = 1
  local loop_watchdog = 0
  local effective_ngrp_for_find = ngrp

  while players_placed_in_this_func < max_players_to_place_in_this_phase do
    loop_watchdog = loop_watchdog + 1
    if loop_watchdog > max_players_to_place_in_this_phase * 4 * 2 + AB_const.LOOP_MAX then
      AB_util.debug("****[ERROR] from_bins_aggregate: Watchdog. Placed: " .. players_placed_in_this_func .. "/" .. max_players_to_place_in_this_phase)
      break
    end

        if AB_util.size_wb(bins) == 0 then
            AB_util.debug("from_bins_aggregate: All bins empty. Placed: " .. players_placed_in_this_func)
            break
        end

    local current_role_bin = bins[bid]
    if current_role_bin and #current_role_bin > 0 then
      local opt_gid
      if (bid == AB_const.ROLE_CATEGORIES[AutoBand.saved.org_algo_role]) then
        opt_gid = AB_template.find_min_groupid_strict(bid, effective_ngrp_for_find, group_ids_sorted_by_initial_fullness, wb_dist, role_per_group)
      else
        opt_gid = AB_template.find_max_groupid_strict(bid, effective_ngrp_for_find, group_ids_sorted_by_initial_fullness, wb_dist, role_per_group)
      end

      if opt_gid and opt_gid ~= -1 and wb_dist[opt_gid] and #wb_dist[opt_gid] < AB_const.GROUP_SIZE then
        local picked_player = AB_template.pick_player_for_slot(current_role_bin, opt_gid, wb_dist[opt_gid], wb_dist) -- Pass current state of wb_dist[opt_gid]
        if picked_player then
          table.insert(wb_dist[opt_gid], picked_player) -- Store the full player object
          table.insert(roles_not_taken[picked_player.role], opt_gid)
          role_per_group[bid][opt_gid] = role_per_group[bid][opt_gid] + 1
          for _, g_entry in ipairs(group_ids_sorted_by_initial_fullness) do if g_entry.id == opt_gid then g_entry.current_size_in_wb_dist = #wb_dist[opt_gid]; break; end end
          players_placed_in_this_func = players_placed_in_this_func + 1
        else
                     if AutoBand.debugon then AB_util.debug("from_bins_aggregate: pick_player_for_slot returned nil for role " .. bid .. " in G" .. opt_gid) end
                end
      else
                 if AutoBand.debugon then
                    if opt_gid and opt_gid ~= -1 and wb_dist[opt_gid] then
                        AB_util.debug("from_bins_aggregate: Opt GID " .. opt_gid .. " is full (#" .. #wb_dist[opt_gid] .. ") or find_max/min_groupid_strict returned no valid group for role " .. bid .. " within the " .. effective_ngrp_for_find .. " target groups.")
                    elseif opt_gid == -1 then
                         AB_util.debug("from_bins_aggregate: find_max/min_groupid_strict returned -1 for role " .. bid .. " within " .. effective_ngrp_for_find .. " groups. Bin size " .. #current_role_bin)
                    else
                         AB_util.debug("from_bins_aggregate: Opt GID " .. tostring(opt_gid) .. " issue for role " .. bid .. "; bin size: " .. #current_role_bin)
                    end
                end
      end
    end

    bid = bid + 1
    if bid > 4 then bid = 1; end
  end
  AB_util.debug("from_bins_aggregate: Finished. Players placed in this phase: " .. players_placed_in_this_func .. " (target: " .. max_players_to_place_in_this_phase .. ")")
end

function AB_template.left_over(_wb_obj, wb_dist, roles_not_taken, bins, initial_target_gid, max_groups_to_fill_with_leftovers)
    if not initial_target_gid or initial_target_gid == -1 or not max_groups_to_fill_with_leftovers or max_groups_to_fill_with_leftovers <= 0 then
        AB_util.debug("left_over: No valid initial_target_gid ("..tostring(initial_target_gid)..") or max_groups_to_fill_with_leftovers ("..tostring(max_groups_to_fill_with_leftovers)..") is invalid.")
        if AB_util.size_wb(bins) > 0 then
            AB_util.debug("left_over: Cannot place " .. AB_util.size_wb(bins) .. " players under these constraints.")
        end
        return
    end

    local current_target_gid = initial_target_gid
    AB_util.debug("left_over: Initial target G" .. current_target_gid .. ". Max group to fill up to is G" .. max_groups_to_fill_with_leftovers)

    local role_iteration_order = {1, 2, 3, 4} -- Example: Healer, Tank, MDPS, RDPS (can be adjusted)

    for _, role_id in ipairs(role_iteration_order) do
        local bin_content = bins[role_id]
        if bin_content then
            local watchdog_bin = 0
            while #bin_content > 0 do
                watchdog_bin = watchdog_bin + 1
                if watchdog_bin > (AB_const.GROUP_SIZE * max_groups_to_fill_with_leftovers) + 5 then
                    AB_util.debug("left_over: Inner watchdog for role_id " .. role_id .. " on G" .. current_target_gid)
                    break
                end

                if not wb_dist[current_target_gid] then wb_dist[current_target_gid] = {} end

                if #wb_dist[current_target_gid] < AB_const.GROUP_SIZE then
                    local player_entry = AB_template.pick_player_for_slot(bin_content, current_target_gid, wb_dist[current_target_gid], wb_dist) -- Pass current state
                    if player_entry then
                        -- Leader to G1 preference during leftovers as well
                        local target_gid2 = current_target_gid
                        local leader_name_pref3 = AutoBand and AutoBand.organizer_leader_name and tostring(AutoBand.organizer_leader_name) or nil
                        if leader_name_pref3 and tostring(player_entry.name) == leader_name_pref3 and current_target_gid ~= 1 and wb_dist[1] and #wb_dist[1] < AB_const.GROUP_SIZE then
                            target_gid2 = 1
                        end
                        table.insert(wb_dist[target_gid2], player_entry) -- Store the full player object
                        table.insert(roles_not_taken[player_entry.role], target_gid2)
                        if AutoBand.debugon then
                            local name_str = player_entry.name and tostring(player_entry.name) or "UnknownName"
                            local dist_tag = nil
                            if AB_org and AB_org.is_distance_sort_active and AB_org._distance_phase then
                                if AB_org._distance_phase == 'far' then dist_tag = '[dist:far] ' elseif AB_org._distance_phase == 'close' then dist_tag = '[dist:close] ' end
                            end
                            AB_util.print((dist_tag or '') .. "Leftover placed: " .. name_str .. " (Role: " .. player_entry.role .. ") in G" .. current_target_gid)
                        end
                    else
                        AB_util.debug("left_over: pick_player_for_slot returned nil for role_id " .. role_id .. " targeting G" .. current_target_gid .. ". Bin size: " .. #bin_content .. ". Trying next role or group.")
                        break
                    end
                else
                    local next_gid_found_within_limit = false
                    if current_target_gid < max_groups_to_fill_with_leftovers then
                        for next_g = current_target_gid + 1, max_groups_to_fill_with_leftovers do
                            if not wb_dist[next_g] then wb_dist[next_g] = {} end
                            if #wb_dist[next_g] < AB_const.GROUP_SIZE then
                                current_target_gid = next_g
                                next_gid_found_within_limit = true
                                AB_util.debug("left_over: Switched to next allowed group G" .. current_target_gid)
                                break
                            end
                        end
                    end

                    if not next_gid_found_within_limit then
                        AB_util.debug("left_over: All allowed groups (G" .. initial_target_gid .. " to G" .. max_groups_to_fill_with_leftovers .. ") are full or cannot place current role. Players in this bin ("..role_id.."): " .. #bin_content)
                        break
                    end
                end
            end
        end
    end
    AB_util.debug("left_over: Finished processing leftovers.")
end
