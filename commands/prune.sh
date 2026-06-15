#!/bin/bash
# commands/prune.sh - Delete worktrees whose PRs have been merged or closed
#
# Usage:
#   wt prune                # All projects, interactive
#   wt prune -p nexus       # One project
#   wt prune -y             # Skip confirmation

cmd_prune() {
    local filter=""
    local auto_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project) filter="$2"; shift 2 ;;
            -y|--yes) auto_yes=true; shift ;;
            -h|--help)
                echo -e "${BOLD}wt prune${NC} - Delete worktrees whose PRs have been merged or closed"
                echo ""
                echo "Usage:"
                echo "  wt prune                # All projects, interactive"
                echo "  wt prune -p nexus       # One project"
                echo "  wt prune -y             # Skip confirmation"
                return 0
                ;;
            *) shift ;;
        esac
    done

    # Collect merged/closed worktrees
    local prunable=()

    for config in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config" ]] || continue
        local project
        project=$(basename "$config" .yaml)

        [[ -n "$filter" && "$project" != "$filter" ]] && continue

        local repo_root
        repo_root=$(yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|")
        [[ -d "$repo_root" ]] || continue

        local repo_nwo
        repo_nwo=$(smart_get_repo_nwo "$repo_root")
        [[ -z "$repo_nwo" ]] && continue

        # One batched query per repo (newest-first), looked up locally per branch —
        # replaces one `gh pr list` network call per worktree. TSV: branch \t number \t state.
        local pr_map
        pr_map=$(gh pr list --repo "$repo_nwo" --state all --limit 500 \
            --json number,state,headRefName \
            --jq '.[] | [.headRefName, (.number|tostring), .state] | @tsv' 2>/dev/null || true)

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local branch="${line%%|*}"
            local path="${line#*|}"

            # First match = newest PR for this branch (gh returns newest-first).
            local pr_line
            pr_line=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$branch" '$1==b {print; exit}')
            [[ -z "$pr_line" ]] && continue

            local pr_number pr_state
            pr_number=$(printf '%s' "$pr_line" | cut -f2)
            pr_state=$(printf '%s' "$pr_line" | cut -f3)

            if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
                local state_lower
                state_lower=$(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]')
                prunable+=("${project}|${branch}|${path}|#${pr_number}|${state_lower}")
            fi
        done < <(
            git -C "$repo_root" worktree list --porcelain 2>/dev/null | {
                local wt_path=""
                while IFS= read -r l; do
                    if [[ "$l" =~ ^worktree\ (.+) ]]; then
                        wt_path="${BASH_REMATCH[1]}"
                    elif [[ "$l" =~ ^branch\ refs/heads/(.+) ]]; then
                        [[ "$wt_path" == "$repo_root" ]] && continue
                        echo "${BASH_REMATCH[1]}|${wt_path}"
                    fi
                done
            }
        )
    done

    if [[ ${#prunable[@]} -eq 0 ]]; then
        echo "No merged/closed worktrees found. Nothing to prune."
        return 0
    fi

    local selected=()

    if $auto_yes; then
        for entry in "${prunable[@]}"; do
            selected+=("$entry")
        done
    else
        if ! command -v fzf &>/dev/null; then
            # No fzf — show list and confirm
            echo -e "${BOLD}Prunable worktrees:${NC}"
            for entry in "${prunable[@]}"; do
                local project branch path pr state
                IFS='|' read -r project branch path pr state <<< "$entry"
                if [[ "$state" == "merged" ]]; then
                    echo -e "  ${CYAN}${project}${NC} / ${branch}  ${MAGENTA}${pr} merged${NC}"
                else
                    echo -e "  ${CYAN}${project}${NC} / ${branch}  ${RED}${pr} closed${NC}"
                fi
            done
            echo ""
            read -r -p "Delete all? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                selected=("${prunable[@]}")
            fi
        else
            # fzf multi-select
            local fzf_input=""
            for entry in "${prunable[@]}"; do
                local project branch path pr state
                IFS='|' read -r project branch path pr state <<< "$entry"
                fzf_input+="${project}  ${branch}  ${pr} ${state}|${entry}"$'\n'
            done

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                selected+=("${line#*|}")
            done < <(
                echo -n "$fzf_input" | fzf --multi --ansi \
                    --header "TAB select | CTRL-A all | ENTER confirm | ESC cancel" \
                    --delimiter '|' --with-nth 1 \
                    --preview-window hidden \
                    --bind 'ctrl-a:toggle-all' \
                    --height "~$((${#prunable[@]} + 3))" || true
            )
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "Nothing selected."
        return 0
    fi

    echo ""
    local total=${#selected[@]}
    local deleted=0
    local failed=0
    local i=0
    for entry in "${selected[@]}"; do
        local project branch path pr state
        IFS='|' read -r project branch path pr state <<< "$entry"
        i=$((i + 1))

        printf "%b[%d/%d]%b Deleting %b%s%b / %s ... " \
            "$DIM" "$i" "$total" "$NC" "$CYAN" "$project" "$NC" "$branch"

        # Subshell isolates cmd_delete's `die`/exit so one failure can't abort the batch.
        if ( cmd_delete "$branch" -p "$project" -f >/dev/null 2>&1 ); then
            printf "%b✓%b\n" "$GREEN" "$NC"
            deleted=$((deleted + 1))
        elif git worktree remove "$path" --force 2>/dev/null; then
            git branch -d "$branch" 2>/dev/null || true
            git worktree prune 2>/dev/null || true
            release_slot "$project" "$branch" 2>/dev/null || true
            delete_worktree_state "$project" "$branch" 2>/dev/null || true
            printf "%b✓%b %b(fallback cleanup)%b\n" "$GREEN" "$NC" "$DIM" "$NC"
            deleted=$((deleted + 1))
        else
            printf "%b✗ failed%b — try %bwt rm %s -p %s%b\n" \
                "$RED" "$NC" "$DIM" "$branch" "$project" "$NC"
            failed=$((failed + 1))
        fi
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        echo -e "${BOLD}Done.${NC} Pruned ${GREEN}${deleted}${NC}, ${RED}${failed} failed${NC} (of ${total})."
    else
        echo -e "${BOLD}Done.${NC} Pruned ${GREEN}${deleted}${NC} worktree(s)."
    fi
}
