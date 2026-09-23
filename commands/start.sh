#!/bin/bash
# commands/start.sh - Start services in a worktree

# Parse `wt start` arguments, resolve a branch/services context (in-worktree,
# main repo root, or explicit branch), and start the resolved services.
# Args: $1 branch (optional; auto-detected inside a worktree or the main repo root),
#       further positionals treated as service names, plus flags
cmd_start() {
    local branch=""
    local service=""
    local attach=0
    local use_tmux=0
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                require_optarg "start" "$1" "${2:-}"
                service="$2"
                shift 2
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
                require_optarg "start" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_start_help
                return 0
                ;;
            -*)
                die_unknown_option "start" "$1"
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
    local is_main_root=0
    if [[ -n "$detected_branch" ]]; then
        # We're in a worktree - positional args are service names
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]] && [[ -z "$service" ]]; then
            services=("${positionals[@]}")
        elif [[ -n "$service" ]]; then
            services=("$service")
        fi
        log_debug "In worktree, detected branch: $branch"
    elif [[ ${#positionals[@]} -eq 0 ]] && detect_main_repo_root; then
        # Main repo root: synthesize a slot-0 context for the current HEAD so the
        # root runs the same start_services_direct + hook pipeline as a worktree.
        is_main_root=1
        branch=$(current_branch)
        export WT_MAIN_CONTEXT=1
        export WT_ROOT_WORKTREE_PATH="$(git_root)"
        export WT_ROOT_SLOT=0
        if [[ -n "$service" ]]; then
            services=("$service")
        fi
        log_debug "Main repo root, synthesized context for branch: $branch"
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
            die_usage "start" "branch name is required (not in a worktree)" "wt start <branch> [service...] [options]"
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Verify worktree exists (skipped at the main repo root — it is the checkout itself)
    if [[ "$is_main_root" -ne 1 ]] && ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    # Get slot for this worktree
    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        die "Could not find slot for worktree. State may be corrupted."
    fi

    # Export port and env variables (overrides set at create time are picked up automatically)
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"
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

# Print the `wt start` / `wt up` help page.
show_start_help() {
    cat << 'EOF'
Starts services in the current terminal, all of them by default.

The branch is auto-detected inside a registered worktree, or at the main repo
root; outside both, the first positional is the branch.

Usage: wt start [options]
       wt start <branch> [options]

Arguments:
  <branch>          Branch name (auto-detected inside a worktree or at the main repo root)

Aliases: wt up

Options:
  --front, --frontend     Start the frontend service only (default: off — all services)
  --back, --backend       Start the backend service only (default: off — all services)
  -s, --service <name>   Start one service by name (default: all services)
  --tmux                 Legacy mode: send commands to tmux panes (default: off — direct mode)
  --attach               Attach to the tmux session, requires --tmux (default: off)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help             Show this page

Examples:
  wt start                         # Start all (inside worktree)
  wt start feat/draft-page         # Start all (outside worktree)
  wt start --front                 # Frontend only
  wt start feat/auth --back        # Backend only for specific branch

Exit codes:
  0  success
  1  no slot for the worktree, or one or more services failed to start
  2  usage error: unknown option, missing argument, or missing branch outside a worktree
EOF
}
