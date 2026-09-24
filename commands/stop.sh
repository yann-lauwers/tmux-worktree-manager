#!/bin/bash
# commands/stop.sh - Stop services in a worktree

# Parse `wt stop` arguments, resolve a branch/services context (in-worktree, main
# repo root, or explicit branch), and stop the resolved services.
# Args: $1 branch (optional; auto-detected inside a worktree or the main repo root),
#       further positionals treated as service names, plus flags
cmd_stop() {
    local branch=""
    local service=""
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                require_optarg "stop" "$1" "${2:-}"
                service="$2"
                shift 2
                ;;
            -a|--all)
                # accepted for backwards compatibility — stopping all services is already the default
                shift
                ;;
            -p|--project)
                require_optarg "stop" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_stop_help
                return 0
                ;;
            -*)
                die_unknown_option "stop" "$1"
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
    elif [[ ${#positionals[@]} -eq 0 ]] && detect_main_repo_root; then
        # Main repo root: resolve the same slot-0 context cmd_start synthesized, so
        # the port-based kills and post_stop hook target the root's services.
        branch=$(current_branch)
        export WT_MAIN_CONTEXT=1
        export_or_empty WT_ROOT_WORKTREE_PATH git_root
        export WT_ROOT_SLOT=0
        if [[ -n "$service" ]]; then
            services=("$service")
        fi
        log_debug "Main repo root, resolved context for branch: $branch"
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
            die_usage "stop" "branch name is required (not in a worktree)" "wt stop [service...] <branch> [options]"
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

# Print the `wt stop` / `wt down` help page.
show_stop_help() {
    cat << 'EOF'
Stops services in a worktree, all of them with no service names given.

The branch is auto-detected inside a registered worktree or at the main repo
root; outside both, the first positional is the branch and later ones are
service names.

Usage: wt stop [service...] [options]
       wt stop <branch> [service...] [options]

Arguments:
  <service...>      One or more service names (omit to stop all)
  <branch>          Branch name (required outside a worktree and the main repo root)

Aliases: wt down

Options:
  -s, --service <name>   Stop one service, an alternative to the positional form (default: none)
  -a, --all               Stop all services — the default; kept for backwards compatibility
                          (default: on)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt stop                          # Stop all services (default)
  wt stop api-server indexer       # Stop multiple services
  wt stop feature/auth             # Outside worktree: stop all for a branch

Exit codes:
  0  success
  2  usage error: unknown option, missing argument, or missing branch outside a worktree
EOF
}
