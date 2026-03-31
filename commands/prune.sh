#!/bin/bash
# commands/prune.sh - Delete worktrees whose PRs have been merged
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
                echo -e "${BOLD}wt prune${NC} - Delete worktrees whose PRs have been merged"
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

    # Collect merged worktrees
    local merged=()

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

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local branch="${line%%|*}"
            local path="${line#*|}"

            local pr_number
            pr_number=$(gh pr list --repo "$repo_nwo" \
                --head "$branch" --state merged --json number --jq '.[0].number // empty' 2>/dev/null || true)

            if [[ -n "$pr_number" ]]; then
                merged+=("${project}|${branch}|${path}|#${pr_number}")
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

    if [[ ${#merged[@]} -eq 0 ]]; then
        echo "No merged worktrees found. Nothing to prune."
        return 0
    fi

    local selected=()

    if $auto_yes; then
        for entry in "${merged[@]}"; do
            selected+=("$entry")
        done
    else
        if ! command -v fzf &>/dev/null; then
            # No fzf — show list and confirm
            echo -e "${BOLD}Merged worktrees:${NC}"
            for entry in "${merged[@]}"; do
                local project branch path pr
                IFS='|' read -r project branch path pr <<< "$entry"
                echo -e "  ${CYAN}${project}${NC} / ${branch}  ${MAGENTA}${pr} merged${NC}"
            done
            echo ""
            read -r -p "Delete all? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                selected=("${merged[@]}")
            fi
        else
            # fzf multi-select
            local fzf_input=""
            for entry in "${merged[@]}"; do
                local project branch path pr
                IFS='|' read -r project branch path pr <<< "$entry"
                fzf_input+="${project}  ${branch}  ${pr} merged|${entry}"$'\n'
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
                    --height "~$((${#merged[@]} + 3))" || true
            )
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "Nothing selected."
        return 0
    fi

    echo ""
    local deleted=0
    for entry in "${selected[@]}"; do
        local project branch path pr
        IFS='|' read -r project branch path pr <<< "$entry"
        echo -e "Deleting ${CYAN}${project}${NC} / ${branch}..."

        if ! cmd_delete "$branch" -p "$project" 2>/dev/null; then
            git worktree remove "$path" --force 2>/dev/null || true
            git branch -d "$branch" 2>/dev/null || true
        fi

        deleted=$((deleted + 1))
    done

    echo ""
    echo -e "${BOLD}Done.${NC} Pruned ${deleted} merged worktree(s)."
}
