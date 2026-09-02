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
    local merged_only=0
    local auto_yes=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                force=1
                shift
                ;;
            -m|--merged)
                merged_only=1
                shift
                ;;
            -y|--yes)
                auto_yes=1
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

    # No branch given → interactive picker (over all worktrees, or merged/closed with --merged)
    if [[ -z "$branch" ]]; then
        _delete_interactive "$project" "$merged_only" "$auto_yes"
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
    # Export this worktree's port vars so delete hooks (e.g. tunnel teardown) can
    # resolve PORT_* like start/stop do. Skip if the slot is already gone.
    local del_slot
    del_slot=$(get_worktree_slot "$project" "$state_key")
    if [[ -n "$del_slot" ]]; then
        export_port_vars "$state_key" "$PROJECT_CONFIG_FILE" "$del_slot" "$project"
    fi
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
    elif ! branch_exists "$branch" "$repo_root"; then
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

# Interactive multi-select picker over all worktrees (or merged/closed only with merged_only=1).
# auto_yes=1 skips the picker and deletes every matching worktree non-interactively.
_delete_interactive() {
    local filter="${1:-}"
    local merged_only="${2:-0}"
    local auto_yes="${3:-0}"

    # Shared builder: TSV rows  project \t branch \t path \t pr_label \t dirty
    local rows
    rows=$(build_worktree_rows "$filter" "$merged_only")

    if [[ -z "$rows" ]]; then
        if [[ "$merged_only" == "1" ]]; then
            echo "No merged/closed worktrees found. Nothing to delete."
        else
            echo "No worktrees found."
        fi
        return 0
    fi

    local fzf_input=""
    local -a all_entries=()
    while IFS=$'\t' read -r project branch path pr_label dirty; do
        [[ -z "$branch" ]] && continue
        local display="${project}  ${branch}"
        [[ -n "$pr_label" ]] && display="${display}  ${pr_label}"
        [[ "${dirty:-0}" -gt 0 ]] && display="${display}  ⚠${dirty} uncommitted"
        all_entries+=("${project}|${branch}|${path}")
        fzf_input+="${display}|${project}|${branch}|${path}"$'\n'
    done <<< "$rows"

    local -a selected=()
    if [[ "$auto_yes" == "1" ]]; then
        selected=("${all_entries[@]}")
    elif ! command -v fzf &>/dev/null; then
        # No fzf — print the list and confirm-all
        echo -e "${BOLD}Worktrees:${NC}"
        while IFS='|' read -r d _rest; do
            [[ -z "$d" ]] && continue
            echo "  $d"
        done <<< "$fzf_input"
        echo ""
        read -r -p "Delete all? [y/N] " response
        [[ "$response" =~ ^[Yy]$ ]] && selected=("${all_entries[@]}")
    else
        local header="TAB select | CTRL-A all | ENTER confirm | ESC cancel"
        [[ "$merged_only" == "1" ]] && header="Merged/closed only — ${header}"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Drop the display field, keep project|branch|path
            selected+=("${line#*|}")
        done < <(
            printf '%s' "$fzf_input" | fzf --multi --ansi \
                --header "$header" \
                --delimiter '|' --with-nth 1 \
                --preview-window hidden \
                --bind 'ctrl-a:toggle-all' \
                --height "~20" || true
        )
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "Nothing selected."
        return 0
    fi

    echo ""
    _delete_batch "${selected[@]}"
}

# Batch-delete the given `project|branch|path` entries with per-item progress.
_delete_batch() {
    local -a entries=("$@")
    local total=${#entries[@]}
    local deleted=0 failed=0 i=0

    for entry in "${entries[@]}"; do
        local project branch path
        IFS='|' read -r project branch path <<< "$entry"
        i=$((i + 1))

        printf "%b[%d/%d]%b Deleting %b%s%b / %s ... " \
            "$DIM" "$i" "$total" "$NC" "$CYAN" "$project" "$NC" "$branch"

        # Subshell isolates cmd_delete's `die`/exit so one failure can't abort the batch.
        if ( cmd_delete "$branch" -p "$project" -f >/dev/null 2>&1 ); then
            printf "%b✓%b\n" "$GREEN" "$NC"
            deleted=$((deleted + 1))
        elif git worktree remove "$path" --force 2>/dev/null; then
            git branch -D "$branch" 2>/dev/null || true
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
        echo -e "${BOLD}Done.${NC} Deleted ${GREEN}${deleted}${NC}, ${RED}${failed} failed${NC} (of ${total})."
    else
        echo -e "${BOLD}Done.${NC} Deleted ${GREEN}${deleted}${NC} worktree(s)."
    fi
}

show_delete_help() {
    local cmd="${WT_CMD_NAME:-delete}"
    cat << EOF
Usage: wt ${cmd} [<branch>] [options]

Delete worktrees. Without a branch, opens an interactive fzf picker over all
worktrees (merged/closed ones first, dirty worktrees flagged). With --merged the
picker is limited to worktrees whose PR is merged/closed; add -y to delete them all.

Arguments:
  <branch>          Branch name (omit for interactive picker)

Options:
  -f, --force       Force deletion even with uncommitted changes
  -m, --merged      Restrict the picker to merged/closed-PR worktrees
  -y, --yes         Non-interactive: delete every matching worktree (pairs with --merged)
  --keep-branch     Don't delete the git branch
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ${cmd}                            # picker over all worktrees
  wt ${cmd} -p nexus                   # picker filtered to one project
  wt ${cmd} --merged                   # picker over merged/closed only
  wt ${cmd} --merged -y                # delete all merged/closed (no prompt)
  wt ${cmd} feature/auth               # direct delete
  wt ${cmd} feature/auth --force       # skip confirmation
  wt ${cmd} feature/auth --keep-branch
EOF
}
