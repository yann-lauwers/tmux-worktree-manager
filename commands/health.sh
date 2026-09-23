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
    local json_output=0

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
            --json)
                json_output=1
                shift
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
        die_no_worktree "health" "$branch" "$project"
    fi

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    local service_count
    service_count=$(get_services "$PROJECT_CONFIG_FILE")

    if [[ "$service_count" -eq 0 ]]; then
        log_warn "No services configured for project: $project"
        if [[ "$json_output" -eq 1 ]]; then
            json_begin
            json_set ".project" str "$project"
            json_set ".branch" str "$branch"
            json_set ".slot" int "$slot"
            json_set ".services" arr
            json_set ".healthy" bool true
            json_set ".summary" obj
            json_set ".summary.total" int 0
            json_set ".summary.healthy" int 0
            json_set ".summary.unhealthy" int 0
            json_emit
        fi
        return 0
    fi

    # Export PORT_* so an http health_check url template resolves via envsubst
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"

    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    if [[ "$json_output" -eq 1 ]]; then
        json_begin
        json_set ".project" str "$project"
        json_set ".branch" str "$branch"
        json_set ".slot" int "$slot"
        json_set ".services" arr
    else
        echo ""
        echo -e "${BOLD}WORKTREE HEALTH${NC}"
        echo "$(printf '%.0s-' {1..50})"
        print_kv "Project" "$project"
        print_kv "Branch" "$branch"
        print_kv "Slot" "$slot"

        printf "\n${BOLD}%-25s %-8s %-10s %s${NC}\n" "SERVICE" "PORT" "CHECK" "VERDICT"
        printf "%s\n" "$(printf '%.0s-' {1..60})"
    fi

    local failures=0
    local healthy_count=0

    for ((i = 0; i < service_count; i++)); do
        local name port_key port

        name=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "name")
        port_key=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "port_key")

        port=""
        if [[ -n "$project" ]]; then
            port=$(get_port_override "$project" "$branch" "$port_key")
        fi
        if [[ -z "$port" ]]; then
            port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
        fi

        local probe_row check check_declared verdict
        probe_row=$(_health_probe_service "$name" "$port" "$PROJECT_CONFIG_FILE" "$timeout")
        IFS=$'\t' read -r check check_declared verdict <<< "$probe_row"

        if [[ "$verdict" == "healthy" ]]; then
            healthy_count=$((healthy_count + 1))
        else
            failures=$((failures + 1))
        fi

        if [[ "$json_output" -eq 1 ]]; then
            local svc_healthy="false"
            [[ "$verdict" == "healthy" ]] && svc_healthy="true"
            json_set ".services[$i].name" str "$name"
            json_set ".services[$i].port" int "$port"
            json_set ".services[$i].check" str "$check"
            json_set ".services[$i].check_declared" bool "$check_declared"
            json_set ".services[$i].verdict" str "$verdict"
            json_set ".services[$i].healthy" bool "$svc_healthy"
        else
            local check_label="$check"
            [[ "$check_declared" == "false" ]] && check_label="${check}*"
            local verdict_color="$RED"
            [[ "$verdict" == "healthy" ]] && verdict_color="$GREEN"
            printf "%-25s %-8s %-10s ${verdict_color}%s${NC}\n" \
                "$name" "${port:-N/A}" "$check_label" "$verdict"
        fi
    done

    if [[ "$json_output" -eq 1 ]]; then
        local overall_healthy="true"
        [[ "$failures" -gt 0 ]] && overall_healthy="false"
        json_set ".healthy" bool "$overall_healthy"
        json_set ".summary" obj
        json_set ".summary.total" int "$service_count"
        json_set ".summary.healthy" int "$healthy_count"
        json_set ".summary.unhealthy" int "$failures"
        json_emit
    else
        echo ""

        if [[ "$failures" -gt 0 ]]; then
            log_warn "$failures service(s) not healthy — logs: wt logs <service> (from inside the worktree)"
        fi
    fi

    if [[ "$failures" -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Print the `wt health` / `wt hc` help page.
show_health_help() {
    cat << 'EOF'
Live-probes a worktree's services right now and reports per-service health.
Reads state only: the state and slots files are left unchanged.

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
  --json                    Print one JSON document instead of the table (default: off)
  -h, --help                 Show this page

Output (--json):
  project, branch, slot
  services[]: name, port, check, check_declared, verdict, healthy
  healthy, summary: { total, healthy, unhealthy }

Examples:
  wt health
  wt health feature/auth
  wt health feature/auth --timeout 15
  wt health feature/auth --json

Exit codes:
  0  every service healthy
  1  a service is unhealthy, or the worktree is not managed by wt
  2  usage error: unknown option, missing argument, or no branch detected

Exit codes are the same with --json.
EOF
}
