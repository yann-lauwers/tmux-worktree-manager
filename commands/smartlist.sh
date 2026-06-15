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

        # Fan out PR-status lookups concurrently — one gh call per worktree, fired in
        # parallel into a temp file each, then collected before rendering. Serial lookups
        # made `wt ls` scale linearly with worktree count (N network round-trips); this
        # caps wall time at the slowest single call instead of their sum.
        local badge_dir=""
        if [[ "$smart_quick" != "true" && -n "$repo_nwo" ]]; then
            badge_dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-badges.XXXXXX")
            local bidx=0
            for entry in "${entries[@]}"; do
                smart_pr_badge "${entry%%|*}" "$repo_nwo" > "$badge_dir/$bidx" &
                bidx=$((bidx + 1))
            done
            wait
        fi

        local idx=0
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

            # PR status (precomputed in parallel above; empty file = no PR)
            local pr_display=""
            if [[ -n "$badge_dir" && -s "$badge_dir/$idx" ]]; then
                pr_display="  $(cat "$badge_dir/$idx")"
            fi
            idx=$((idx + 1))

            echo -e "  $branch${managed}${pr_display}"
            echo -e "  ${DIM}${path}${NC}"
        done
        [[ -n "$badge_dir" ]] && rm -rf "$badge_dir"
        echo ""
        total=$((total + ${#entries[@]}))
    done

    if [[ $total -eq 0 ]]; then
        echo "No worktrees found across any project."
    else
        echo -e "${DIM}Total: ${total} worktree(s)${NC}"
    fi
}
