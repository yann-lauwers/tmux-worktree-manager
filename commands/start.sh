#!/bin/bash
# commands/start.sh - Start services in a worktree

cmd_start() {
    local branch=""
    local service=""
    local all=0
    local attach=0
    local use_tmux=0
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                service="$2"
                shift 2
                ;;
            -a|--all)
                all=1
                shift
                ;;
            --attach)
                attach=1
                shift
                ;;
            --tmux)
                use_tmux=1
                shift
                ;;
            --front|--frontend)
                positionals+=("frontend")
                shift
                ;;
            --back|--backend)
                positionals+=("backend")
                shift
                ;;
            -p|--project)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_start_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_start_help
                return 1
                ;;
            *)
                # Collect positional arguments
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Try to detect branch from current directory
    local detected_branch
    detected_branch=$(detect_worktree_branch)

    # Interpret positional arguments based on context
    local -a services=()
    if [[ -n "$detected_branch" ]]; then
        # We're in a worktree - positional args are service names
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]] && [[ -z "$service" ]]; then
            services=("${positionals[@]}")
        elif [[ -n "$service" ]]; then
            services=("$service")
        fi
        log_debug "In worktree, detected branch: $branch"
    else
        # Not in a worktree - first positional is branch, rest could be services
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
            # If there are more positionals, they're service names
            if [[ ${#positionals[@]} -gt 1 ]]; then
                services=("${positionals[@]:1}")
            elif [[ -n "$service" ]]; then
                services=("$service")
            fi
        fi
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (not in a worktree)"
            show_start_help
            return 1
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Verify worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    # Get slot for this worktree
    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        die "Could not find slot for worktree. State may be corrupted."
    fi

    # Export port and env variables
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Clean up stale service states
    cleanup_stale_services "$project" "$branch"

    # Run pre_start hook if defined
    export BRANCH_NAME="$branch"
    export WORKTREE_PATH="$(get_worktree_path "$project" "$branch")"
    run_hook "$PROJECT_CONFIG_FILE" "pre_start"

    # Determine which services to start (all by default)
    local service_names=""
    if [[ ${#services[@]} -gt 0 ]]; then
        service_names=$(printf '%s\n' "${services[@]}")
    else
        # Default: start all services
        service_names=$(yq -r '.services[].name' "$PROJECT_CONFIG_FILE" 2>/dev/null)
    fi

    if [[ -z "$service_names" ]]; then
        log_info "No services configured"
        return 0
    fi

    if [[ "$use_tmux" -eq 1 ]]; then
        # Legacy tmux mode: send commands to tmux panes
        local session
        session=$(get_session_name "$project" "$branch")

        if ! session_exists "$session"; then
            local wt_path
            wt_path=$(get_worktree_path "$project" "$branch")
            create_session "$session" "$wt_path" "$PROJECT_CONFIG_FILE"
        fi

        local failed=0
        while read -r name; do
            [[ -z "$name" ]] && continue
            if ! start_service "$project" "$branch" "$name" "$PROJECT_CONFIG_FILE"; then
                ((failed++))
            fi
            sleep 1
        done <<< "$service_names"

        # Run post_start hook
        export BRANCH_NAME="$branch"
        export WORKTREE_PATH="$(get_worktree_path "$project" "$branch")"
        run_hook "$PROJECT_CONFIG_FILE" "post_start"

        if [[ "$attach" -eq 1 ]]; then
            echo ""
            attach_session "$session"
        fi

        if [[ "$failed" -gt 0 ]]; then
            log_warn "$failed service(s) failed to start"
            return 1
        fi
    else
        # Direct mode: run services in the current terminal
        start_services_direct "$project" "$branch" "$PROJECT_CONFIG_FILE" "$service_names"
    fi
}

show_start_help() {
    cat << 'EOF'
Usage: wt start [options]
       wt start <branch> [options]

Start services in the current terminal. Runs all services by default.
When run inside a registered worktree, the branch is auto-detected.

Arguments:
  <branch>          Branch name (auto-detected inside a worktree)

Options:
  --front           Start frontend only
  --back            Start backend only
  -s, --service     Start a specific service by name
  --tmux            Legacy mode: send commands to tmux panes
  --attach          Attach to tmux session (requires --tmux)
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt start                         # Start all (inside worktree)
  wt start feat/draft-page         # Start all (outside worktree)
  wt start --front                 # Frontend only
  wt start --back                  # Backend only
  wt start feat/auth --back        # Backend only for specific branch
EOF
}
