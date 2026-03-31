#!/bin/bash
# commands/smartlist.sh - List worktrees across all projects with PR status
#
# Usage:
#   wt ls                # All projects, with PR status
#   wt ls -q             # Quick (no PR status)
#   wt ls -p nexus       # One project

cmd_smartlist() {
    local filter=""
    local smart_quick=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project) filter="$2"; shift 2 ;;
            -q|--quick) smart_quick=true; shift ;;
            -s|--status) smart_quick=false; shift ;;
            -h|--help)
                echo -e "${BOLD}wt ls${NC} - List worktrees across all projects"
                echo ""
                echo "Usage:"
                echo "  wt ls                # All projects with PR status"
                echo "  wt ls -q             # Quick (no PR check)"
                echo "  wt ls -p nexus       # One project"
                return 0
                ;;
            *) shift ;;
        esac
    done

    local total=0

    for config in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config" ]] || continue
        local project
        project=$(basename "$config" .yaml)

        [[ -n "$filter" && "$project" != "$filter" ]] && continue

        local repo_root
        repo_root=$(yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|")
        [[ -d "$repo_root" ]] || continue

        # Get repo name with owner for PR links
        local repo_nwo=""
        if [[ "$smart_quick" != "true" ]]; then
            repo_nwo=$(smart_get_repo_nwo "$repo_root")
        fi

        local entries=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && entries+=("$line")
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

        [[ ${#entries[@]} -eq 0 ]] && continue

        echo -e "${BOLD}${CYAN}${project}${NC}  ${DIM}(${#entries[@]} worktrees)${NC}"

        local local_state="$HOME/.local/share/wt/state/${project}.state.yaml"

        for entry in "${entries[@]}"; do
            local branch="${entry%%|*}"
            local path="${entry#*|}"

            # Check if managed by wt-core (has slot)
            local managed=""
            if [[ -f "$local_state" ]]; then
                local slot
                slot=$(yq -r ".worktrees.\"$branch\".slot // empty" "$local_state" 2>/dev/null || true)
                if [[ -n "$slot" ]]; then
                    managed=" ${DIM}[slot $slot]${NC}"
                fi
            fi

            # PR status
            local pr=""
            if [[ "$smart_quick" != "true" && -n "$repo_nwo" ]]; then
                pr=$(smart_pr_badge "$branch" "$repo_nwo")
            fi
            local pr_display=""
            [[ -n "$pr" ]] && pr_display="  $pr"

            echo -e "  $branch${managed}${pr_display}"
            echo -e "  ${DIM}${path}${NC}"
        done
        echo ""
        total=$((total + ${#entries[@]}))
    done

    if [[ $total -eq 0 ]]; then
        echo "No worktrees found across any project."
    else
        echo -e "${DIM}Total: ${total} worktree(s)${NC}"
    fi
}
