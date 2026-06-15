#!/bin/bash
# commands/stop.sh - Stop services in a worktree

cmd_stop() {
    local branch=""
    local service=""
    local all=0
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                service="$2"
                shift 2
                ;;
            -a|--all)
                all=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_stop_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_stop_help
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
            show_stop_help
            return 1
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Stop services
    if [[ ${#services[@]} -gt 0 ]]; then
        # Specific service(s) requested
        for svc in "${services[@]}"; do
            stop_service "$project" "$branch" "$svc" "$PROJECT_CONFIG_FILE"
        done
    else
        # Default (and explicit --all): stop all services
        stop_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE"
    fi

    # Run post_stop hook if defined
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "post_stop"
}

show_stop_help() {
    cat << 'EOF'
Usage: wt stop [service...] [options]
       wt stop <branch> [service...] [options]

Stop services in a worktree. With no service names, stops all services
(this is the default; --all is kept for backwards compatibility).

When run inside a worktree, the branch is auto-detected and positional
arguments are treated as service names. Multiple services can be
specified.

Arguments:
  <service...>      One or more service names (omit to stop all)
  <branch>          Branch name (required when outside a worktree)

Options:
  -s, --service     Stop a specific service (alternative syntax)
  -a, --all         Stop all services (now the default — optional)
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt stop                          # Stop all services (default)
  wt stop api-server               # Stop one service
  wt stop api-server indexer       # Stop multiple services
  wt stop feature/auth             # Outside worktree: stop all for a branch
EOF
}
