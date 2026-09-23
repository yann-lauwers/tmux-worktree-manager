#!/bin/bash
# commands/health.sh - Live-probe a worktree's services

# Default probe timeout (seconds). Deliberately short: `wt health` answers
# "is it healthy now?", unlike `wt start`, which waits for boot.
WT_HEALTH_DEFAULT_TIMEOUT=5

# Parse `wt health` arguments and live-probe the resolved worktree's services.
# Args: $1 branch (optional; detected from the current directory when omitted), plus flags
cmd_health() {
    local branch=""
    local project=""
    local timeout="$WT_HEALTH_DEFAULT_TIMEOUT"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--timeout)
                require_optarg "health" "$1" "${2:-}"
                timeout="$2"
                shift 2
                ;;
            -p|--project)
                require_optarg "health" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_health_help
                return 0
                ;;
            -*)
                die_unknown_option "health" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    # If no branch specified, try to detect from current directory
    if [[ -z "$branch" ]]; then
        branch=$(detect_worktree_branch)
        # At the main repo root there is no worktree branch to detect; fall back
        # to the checked-out branch so `wt health` works there like `wt start`.
        [[ -z "$branch" ]] && branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        if [[ -z "$branch" ]]; then
            die_usage "health" "branch name is required" "wt health [<branch>] [options]"
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Registration gate — an unmanaged checkout has no slot, no ports, and no
    # services. Fail loudly rather than probing invented ports.
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    local service_count
    service_count=$(get_services "$PROJECT_CONFIG_FILE")

    if [[ "$service_count" -eq 0 ]]; then
        log_warn "No services configured for project: $project"
        return 0
    fi

    # Export PORT_* so an http health_check url template resolves via envsubst
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"

    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    echo ""
    echo -e "${BOLD}WORKTREE HEALTH${NC}"
    echo "$(printf '%.0s-' {1..50})"
    print_kv "Project" "$project"
    print_kv "Branch" "$branch"
    print_kv "Slot" "$slot"

    printf "\n${BOLD}%-25s %-8s %-10s %s${NC}\n" "SERVICE" "PORT" "CHECK" "VERDICT"
    printf "%s\n" "$(printf '%.0s-' {1..60})"

    local failures=0

    for ((i = 0; i < service_count; i++)); do
        local name port_key port health_type verdict verdict_color check_label

        name=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "name")
        port_key=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "port_key")

        port=""
        if [[ -n "$project" ]]; then
            port=$(get_port_override "$project" "$branch" "$port_key")
        fi
        if [[ -z "$port" ]]; then
            port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
        fi

        health_type=$(yq -r ".services[] | select(.name == \"$name\") | .health_check.type // \"\"" \
            "$PROJECT_CONFIG_FILE" 2>/dev/null)

        if [[ -z "$health_type" ]] || [[ "$health_type" == "null" ]]; then
            # No declared check — fall back to a listener probe rather than
            # reporting healthy, which is what run_health_check would do.
            check_label="tcp*"
            if port_in_use "$port"; then
                verdict="healthy"; verdict_color="$GREEN"
            else
                verdict="down"; verdict_color="$RED"
                failures=$((failures + 1))
            fi
        else
            check_label="$health_type"
            if run_health_check "$name" "$port" "$PROJECT_CONFIG_FILE" "$timeout" >/dev/null 2>&1; then
                verdict="healthy"; verdict_color="$GREEN"
            else
                verdict="unhealthy"; verdict_color="$RED"
                failures=$((failures + 1))
            fi
        fi

        printf "%-25s %-8s %-10s ${verdict_color}%s${NC}\n" \
            "$name" "${port:-N/A}" "$check_label" "$verdict"
    done

    echo ""

    if [[ "$failures" -gt 0 ]]; then
        log_warn "$failures service(s) not healthy — logs: wt logs <service> (from inside the worktree)"
        return 1
    fi

    return 0
}

# Print the `wt health` / `wt hc` help page.
show_health_help() {
    cat << 'EOF'
Live-probes a worktree's services right now and reports per-service health.

Unlike `wt status`, which reports the status recorded when services were last
started, this runs the health check declared for each service right now. A
listening port is not health: a process can hold its port open while failing
every request. Services with no health_check declared are probed for a
listening port and marked `tcp*`.

Usage: wt health [<branch>] [options]

Arguments:
  <branch>          Branch name (auto-detected inside a worktree, or the main repo root)

Aliases: wt hc

Options:
  -t, --timeout <seconds>   Seconds to wait per service (default: 5)
  -p, --project <name>      Project to act on (default: detected from the current directory)
  -h, --help                 Show this page

Reads state only: the state and slots files are left unchanged.

Examples:
  wt health
  wt health feature/auth
  wt health feature/auth --timeout 15

Exit codes:
  0  every service healthy
  1  a service is unhealthy, or the worktree is not managed by wt
  2  usage error: unknown option, missing argument, or no branch detected
EOF
}
