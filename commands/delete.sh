#!/bin/bash
# commands/delete.sh - Delete worktrees (direct or interactive fzf picker)
#
# Usage:
#   wt delete                        # fzf picker (multi-select)
#   wt delete -p nexus               # fzf picker, one project
#   wt delete <branch>               # direct delete
#   wt delete <branch> --force       # skip confirmation
#   wt rm ...                        # alias for delete

cmd_delete() {
    local branch=""
    local force=0
    local keep_branch=0
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                force=1
                shift
                ;;
            --keep-branch)
                keep_branch=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_delete_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_delete_help
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    # No branch given → interactive fzf picker
    if [[ -z "$branch" ]]; then
        _delete_interactive "$project"
        return
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local repo_root="$PROJECT_REPO_PATH"

    # Resolve against git's real branch↔worktree mapping, then relink to the state entry by
    # its path. Both survive a branch rename that breaks the dirname and state key derived
    # from the branch string — the drift that left renamed worktrees un-prunable.
    local wt_real_path state_key
    wt_real_path=$(worktree_path_for_branch "$branch" "$repo_root")
    state_key="$branch"
    if [[ -n "$wt_real_path" ]]; then
        local _resolved_key
        _resolved_key=$(state_key_for_path "$project" "$wt_real_path")
        [[ -n "$_resolved_key" ]] && state_key="$_resolved_key"
    fi

    # Check if worktree exists on disk
    local wt_on_disk=1
    if ! worktree_exists "$branch" "$repo_root"; then
        wt_on_disk=0
        # Check if there's orphaned state or slot to clean up
        local has_state
        has_state=$(get_worktree_state "$project" "$state_key" "path")
        local has_slot
        has_slot=$(get_slot_for_worktree "$project" "$state_key")
        if [[ -z "$has_state" ]] && [[ -z "$has_slot" ]]; then
            die "Worktree not found for branch: $branch"
        fi
        log_warn "Worktree directory not found, cleaning up orphaned state..."
    fi

    # Confirmation
    if [[ "$force" -eq 0 ]]; then
        if ! confirm "Delete worktree for branch '$branch'?"; then
            log_info "Aborted"
            return 2
        fi
    fi

    # Stop all services first
    log_info "Stopping services..."
    stop_all_services "$project" "$state_key" "$PROJECT_CONFIG_FILE" 2>/dev/null || true

    # Kill tmux window — prefer the session recorded in state (stable across branch renames),
    # falling back to the name derived from the branch.
    local window_name
    window_name=$(get_worktree_state "$project" "$state_key" "session")
    [[ -z "$window_name" ]] && window_name=$(get_session_name "$project" "$branch")
    kill_session "$window_name" "$PROJECT_CONFIG_FILE"

    # Run pre_delete hook if defined
    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")
    # Fall back to state file path if computed path doesn't exist
    if [[ ! -d "$wt_path" ]]; then
        local state_path
        state_path=$(get_worktree_state "$project" "$branch" "path" 2>/dev/null)
        [[ -n "$state_path" ]] && wt_path="$state_path"
    fi
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "pre_delete"

    # Remove worktree (only if it exists on disk)
    if [[ "$wt_on_disk" -eq 1 ]]; then
        if ! remove_worktree "$branch" "$force" "$keep_branch" "$repo_root"; then
            die "Failed to remove worktree"
        fi
    fi

    # Release slot
    release_slot "$project" "$state_key"

    # Delete state
    delete_worktree_state "$project" "$state_key"

    # Check if branch still exists (may have been deleted by remove_worktree)
    local branch_deleted=0
    if [[ "$keep_branch" == "1" ]]; then
        log_info "Branch kept: $branch"
    elif ! branch_exists "$branch"; then
        branch_deleted=1
    fi

    # Run post_delete hook if defined
    run_hook "$PROJECT_CONFIG_FILE" "post_delete"

    if [[ "$branch_deleted" == "1" ]]; then
        log_success "Worktree and branch deleted: $branch"
    else
        log_success "Worktree deleted: $branch (branch kept)"
    fi
}

# Interactive fzf multi-select picker
_delete_interactive() {
    local filter="${1:-}"

    if ! command -v fzf &>/dev/null; then
        die "fzf is required for interactive delete. Install: brew install fzf"
    fi

    # Build worktree list with PR status
    local fzf_input=""

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

        # One batched query per repo (newest-first), looked up locally per branch —
        # replaces one `gh pr list` network call per worktree. TSV: branch \t number \t state \t isDraft.
        local pr_map=""
        if [[ -n "$repo_nwo" ]]; then
            pr_map=$(gh pr list --repo "$repo_nwo" --state all --limit 500 \
                --json number,state,isDraft,headRefName \
                --jq '.[] | [.headRefName, (.number|tostring), .state, (.isDraft|tostring)] | @tsv' 2>/dev/null || true)
        fi

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local branch="${line%%|*}"
            local path="${line#*|}"

            # PR status label — first match = newest PR (gh returns newest-first).
            local pr_label=""
            if [[ -n "$pr_map" ]]; then
                local pr_line
                pr_line=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$branch" '$1==b {print; exit}')
                if [[ -n "$pr_line" ]]; then
                    local number state draft
                    number=$(printf '%s' "$pr_line" | cut -f2)
                    state=$(printf '%s' "$pr_line" | cut -f3)
                    draft=$(printf '%s' "$pr_line" | cut -f4)
                    if [[ "$state" == "MERGED" ]]; then
                        pr_label="#${number} merged"
                    elif [[ "$draft" == "true" ]]; then
                        pr_label="#${number} draft"
                    elif [[ "$state" == "OPEN" ]]; then
                        pr_label="#${number} open"
                    elif [[ "$state" == "CLOSED" ]]; then
                        pr_label="#${number} closed"
                    fi
                fi
            fi

            local display="${project}  ${branch}"
            [[ -n "$pr_label" ]] && display="${display}  ${pr_label}"
            fzf_input+="${display}|${project}|${branch}|${path}"$'\n'
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

    if [[ -z "$fzf_input" ]]; then
        echo "No worktrees found."
        return 0
    fi

    local selected=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        selected+=("$line")
    done < <(
        echo -n "$fzf_input" | fzf --multi --ansi \
            --header "TAB select | CTRL-A all | ENTER confirm | ESC cancel" \
            --delimiter '|' --with-nth 1 \
            --preview-window hidden \
            --bind 'ctrl-a:toggle-all' \
            --height "~20" || true
    )

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "Nothing selected."
        return 0
    fi

    echo ""
    local deleted=0
    for entry in "${selected[@]}"; do
        local _display project branch path
        IFS='|' read -r _display project branch path <<< "$entry"
        echo -e "Deleting ${CYAN}${project}${NC} / ${branch}..."
        if ! cmd_delete "$branch" -p "$project" -f 2>/dev/null; then
            # Fallback: force cleanup if cmd_delete fails
            git worktree remove "$path" --force 2>/dev/null || true
            git branch -D "$branch" 2>/dev/null || true
            git worktree prune 2>/dev/null || true
            release_slot "$project" "$branch" 2>/dev/null || true
            delete_worktree_state "$project" "$branch" 2>/dev/null || true
        fi
        deleted=$((deleted + 1))
    done

    echo ""
    echo -e "${BOLD}Done.${NC} Deleted ${deleted} worktree(s)."
}

show_delete_help() {
    local cmd="${WT_CMD_NAME:-delete}"
    cat << EOF
Usage: wt ${cmd} [<branch>] [options]

Delete worktrees. Without a branch, opens an interactive fzf picker.

Arguments:
  <branch>          Branch name (omit for interactive picker)

Options:
  -f, --force       Force deletion even with uncommitted changes
  --keep-branch     Don't delete the git branch
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ${cmd}                            # interactive fzf picker
  wt ${cmd} -p nexus                   # picker filtered to one project
  wt ${cmd} feature/auth               # direct delete
  wt ${cmd} feature/auth --force       # skip confirmation
  wt ${cmd} feature/auth --keep-branch
EOF
}
