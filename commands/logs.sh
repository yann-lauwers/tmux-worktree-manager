#!/bin/bash
# commands/logs.sh - Capture tmux pane output

cmd_logs() {
    local branch=""
    local project=""
    local lines=50
    local show_all=0
    local target=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                project="$2"
                shift 2
                ;;
            --lines|-n)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                lines="$2"
                shift 2
                ;;
            --all|-a)
                show_all=1
                shift
                ;;
            -h|--help)
                show_logs_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_logs_help
                return 1
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Try to detect branch from current directory
    local detected_branch
    detected_branch=$(detect_worktree_branch)

    if [[ -n "$detected_branch" ]]; then
        # In a worktree: positional is service/pane
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]]; then
            target="${positionals[0]}"
        fi
    else
        # Not in a worktree: first positional is branch, second is service/pane
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
        fi
        if [[ ${#positionals[@]} -gt 1 ]]; then
            target="${positionals[1]}"
        fi
    fi

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required (not in a worktree)"
        show_logs_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Direct mode is the default for `wt start` and writes per-service log files;
    # tmux mode is legacy. Try the files first — a stale tmux session can exist
    # with no service panes, in which case the tmux path finds nothing and exits
    # silently, which reads as "no errors" rather than "no logs".
    if _logs_from_files "$project" "$branch" "$target" "$lines" "$show_all"; then
        return 0
    fi

    if ! session_exists "$tmux_session" || ! window_exists "$tmux_session" "$window_name"; then
        die "No logs for $branch — no direct-mode log file, and no tmux session. Start services with: wt start"
    fi

    if [[ "$show_all" -eq 1 ]]; then
        # Show all panes
        local pane_info
        pane_info=$(list_window_panes "$tmux_session" "$window_name")

        while IFS=: read -r idx active cmd size; do
            [[ -z "$idx" ]] && continue

            # Try to resolve pane name from config
            local pane_label="pane $idx"
            local pane_service
            pane_service=$(yq -r ".tmux.windows[0].panes[$idx].service // \"\"" "$PROJECT_CONFIG_FILE" 2>/dev/null)
            if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
                pane_label="$pane_service"
            fi

            echo -e "${BOLD}=== $pane_label (pane $idx) ===${NC}"
            capture_pane "$tmux_session" "$window_name" "$idx" "$lines"
            echo ""
        done <<< "$pane_info"
    elif [[ -n "$target" ]]; then
        # Resolve target to pane index
        local pane_idx
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            pane_idx="$target"
        else
            # `|| true` matters: find_service_pane_index returns 1 when the service
            # has no pane, and under `set -e` the assignment would abort the script
            # here — exiting 1 with no message at all, which reads as empty logs.
            pane_idx=$(find_service_pane_index "$PROJECT_CONFIG_FILE" "$target" || true)
            if [[ -z "$pane_idx" ]]; then
                die "Service '$target' has no tmux pane and no direct-mode log file. Running services log to: $(service_log_file "$project" "$branch" "$target")"
            fi
        fi

        capture_pane "$tmux_session" "$window_name" "$pane_idx" "$lines"
    else
        # Default: show pane 0
        capture_pane "$tmux_session" "$window_name" "0" "$lines"
    fi
}

# Read direct-mode log files. Returns 1 when none exist, so the caller can fall
# through to its own error rather than reporting success on an empty read.
_logs_from_files() {
    local project="$1"
    local branch="$2"
    local target="$3"
    local lines="$4"
    local show_all="$5"

    local found=0

    if [[ -n "$target" ]] && [[ "$show_all" -ne 1 ]]; then
        local log_file
        log_file=$(service_log_file "$project" "$branch" "$target")
        if [[ -f "$log_file" ]]; then
            tail -n "$lines" "$log_file"
            found=1
        fi
    else
        local service_count
        service_count=$(get_services "$PROJECT_CONFIG_FILE")

        local i
        for ((i = 0; i < service_count; i++)); do
            local name log_file
            name=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "name")
            log_file=$(service_log_file "$project" "$branch" "$name")
            [[ -f "$log_file" ]] || continue

            echo -e "${BOLD}=== $name ===${NC}"
            tail -n "$lines" "$log_file"
            echo ""
            found=1
        done
    fi

    [[ "$found" -eq 1 ]]
}

show_logs_help() {
    cat << 'EOF'
Usage: wt logs [branch] [service|pane_index] [options]
       wt logs [service|pane_index] [options]  (inside worktree)

Capture and display tmux pane output for a worktree.

Arguments:
  <branch>          Branch name (auto-detected inside worktree)
  <service>         Service name to capture (resolved to pane index)
  <pane_index>      Numeric pane index to capture directly

Options:
  --lines, -n N     Number of lines to capture (default: 50)
  --all, -a         Show output from all panes
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt logs feature/auth api-server
  wt logs feature/auth --all
  wt logs api-server --lines 100          # Inside worktree
  wt logs feature/auth 0 -n 20           # By pane index
EOF
}
