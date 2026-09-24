#!/bin/bash
# commands/ports.sh - Show and manage port assignments for worktrees

# Print port table header
# Usage: _ports_table_header <title> <check_availability>
_ports_table_header() {
    local title="$1"
    local check_availability="$2"

    echo -e "${BOLD}${title}${NC}"
    printf "%-25s %-8s %-10s" "SERVICE" "PORT" "OVERRIDE"
    [[ "$check_availability" -eq 1 ]] && printf " %-12s" "STATUS"
    echo ""
    printf "%s\n" "$(printf '%.0s-' {1..60})"
}

# Print a single port row with override and availability info
# Usage: _ports_table_row <service> <port> <project> <branch> <check_availability>
_ports_table_row() {
    local service="$1"
    local port="$2"
    local project="$3"
    local branch="$4"
    local check_availability="$5"

    local override
    override=$(get_port_override "$project" "$branch" "$service")
    local effective_port="$port"

    printf "%-25s %-8s" "$service" "$port"

    if [[ -n "$override" ]]; then
        printf " ${CYAN}%-10s${NC}" "$override"
        effective_port="$override"
    else
        printf " %-10s" "-"
    fi

    if [[ "$check_availability" -eq 1 ]]; then
        if port_in_use "$effective_port"; then
            printf '%b' " ${RED}in use${NC}"
        else
            printf '%b' " ${GREEN}available${NC}"
        fi
    fi
    echo ""
}

# Show port assignments for a worktree's slot, or dispatch to the set/clear subcommands.
# Args: none (reads 'set'/'clear' as $1, else -c/--check, -p/--project, [branch] from argv)
# Side: dies (exit 1) when the branch has no slot and no worktree exists
cmd_ports() {
    local subcommand=""
    local branch=""
    local project=""
    local check_availability=0
    local json_output=0

    # Check for subcommand
    if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
        case "$1" in
            set|clear)
                subcommand="$1"
                shift
                ;;
        esac
    fi

    # Route to subcommand handlers
    case "$subcommand" in
        set)
            cmd_ports_set "$@"
            return $?
            ;;
        clear)
            cmd_ports_clear "$@"
            return $?
            ;;
    esac

    # Parse arguments for show (default)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--check)
                check_availability=1
                shift
                ;;
            -p|--project)
                require_optarg "ports" "$1" "${2:-}" "wt ports [branch] [options]"
                project="$2"
                shift 2
                ;;
            --json)
                json_output=1
                shift
                ;;
            -h|--help)
                show_ports_help
                return 0
                ;;
            -*)
                die_unknown_option "ports" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    # Auto-detect branch from current git branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(detect_worktree_branch)
        [[ -z "$branch" ]] && branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "ports" "branch name is required and could not be detected" "wt ports [branch] [options]"
        fi
        log_info "Using current branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Get slot
    local slot
    slot=$(get_slot_for_worktree "$project" "$branch")

    local projected="false"
    if [[ -z "$slot" ]]; then
        # A branch wt does not manage has no slot. Falling through to slot 0 here
        # would print another worktree's real ports as if they were this branch's,
        # and still exit 0 — a caller cannot tell the answer is fiction. Fail the
        # same way `wt status` does, and keep the projected-ports preview for a
        # worktree that exists but has not claimed a slot yet.
        if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
            die_no_worktree "ports" "$branch" "$project"
        fi
        log_info "Worktree not created yet, showing projected ports..."
        slot=0
        projected="true"
    fi

    if [[ "$json_output" -eq 1 ]]; then
        _ports_json "$project" "$branch" "$slot" "$projected" "$check_availability"
        return 0
    fi

    echo ""
    echo -e "${BOLD}Port Assignments for: ${CYAN}$branch${NC}"
    echo "$(printf '%.0s-' {1..50})"
    echo ""

    print_kv "Project" "$project"
    print_kv "Slot" "$slot"
    echo ""

    # Reserved ports section
    local reserved_min
    reserved_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.reserved.range.min" "3000")

    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | to_entries | .[] | "\(.key):\(.value)"' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$reserved_services" ]]; then
        _ports_table_header "Reserved Ports (Slot $slot)" "$check_availability"

        while IFS=: read -r service offset; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_reserved_port "$slot" "$offset" "$reserved_min")
            _ports_table_row "$service" "$port" "$project" "$branch" "$check_availability"
        done <<< "$reserved_services"
        echo ""
    fi

    # Dynamic ports section
    local dynamic_services
    dynamic_services=$(yq -r '.ports.dynamic.services // {} | keys | .[]' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$dynamic_services" ]]; then
        _ports_table_header "Dynamic Ports" "$check_availability"

        local dynamic_min
        dynamic_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.min" "4000")

        local dynamic_max
        dynamic_max=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.max" "5000")

        while read -r service; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_dynamic_port "$branch" "$dynamic_min" "$dynamic_max")
            _ports_table_row "$service" "$port" "$project" "$branch" "$check_availability"
        done <<< "$dynamic_services"
        echo ""
    fi

    # Environment variables (with overrides applied)
    echo -e "${BOLD}Environment Variables (effective)${NC}"
    printf "%s\n" "$(printf '%.0s-' {1..60})"

    while IFS=: read -r service port; do
        [[ -z "$service" ]] && continue
        local var_name
        var_name=$(port_env_var_name "$service")

        # Check for override
        local override
        override=$(get_port_override "$project" "$branch" "$service")
        local effective_port="${override:-$port}"

        echo "export $var_name=$effective_port"
        export "$var_name=$effective_port"
    done < <(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    echo ""

    # DB connection string (if configured)
    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch" 2>/dev/null)
    local db_url
    if db_url=$(resolve_db_url "$PROJECT_CONFIG_FILE" "$wt_path"); then
        echo -e "${BOLD}Database${NC}"
        printf "%s\n" "$(printf '%.0s-' {1..60})"
        local db_row db_host db_port db_user db_name
        db_row=$(parse_db_url_components "$db_url")
        IFS=$'\x1f' read -r db_host db_port db_user db_name <<< "$db_row"
        print_kv "Host" "$db_host"
        print_kv "Port" "$db_port"
        print_kv "User" "$db_user"
        print_kv "Database" "$db_name"
        print_kv "Connection string" "$(redact_db_url "$db_url")"
        echo ""
    fi
}

# Assemble and print `wt ports --json`'s document for the show form. Takes
# ALL ports (reserved and dynamic alike) from one `calculate_worktree_ports`
# call, then splits them by which config section declares the service —
# the human dynamic table computes dynamic ports separately and has its own
# known bug with two dynamic services, left as-is here.
# Args: $1 project, $2 branch, $3 slot, $4 projected (true|false),
#       $5 check_availability (0|1)
# Side: runs json_begin/json_emit; writes the document to real stdout
_ports_json() {
    local project="$1"
    local branch="$2"
    local slot="$3"
    local projected="$4"
    local check_availability="$5"

    json_begin

    json_set ".project" str "$project"
    json_set ".branch" str "$branch"
    json_set ".slot" int "$slot"
    json_set ".projected" bool "$projected"

    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | keys | .[]' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    json_set ".reserved" arr
    json_set ".dynamic" arr
    json_set ".env" obj

    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    local r_idx=0 d_idx=0
    while IFS=: read -r svc port; do
        [[ -z "$svc" ]] && continue

        local override effective_port bucket idx
        override=$(get_port_override "$project" "$branch" "$svc")
        effective_port="${override:-$port}"

        if echo "$reserved_services" | grep -qx "$svc"; then
            bucket="reserved"
            idx=$r_idx
            r_idx=$((r_idx + 1))
        else
            bucket="dynamic"
            idx=$d_idx
            d_idx=$((d_idx + 1))
        fi

        json_set ".${bucket}[$idx].service" str "$svc"
        json_set ".${bucket}[$idx].port" int "$port"
        json_set ".${bucket}[$idx].override" int "$override"
        json_set ".${bucket}[$idx].effective_port" int "$effective_port"

        if [[ "$check_availability" -eq 1 ]]; then
            local in_use_flag="false"
            port_in_use "$effective_port" && in_use_flag="true"
            json_set ".${bucket}[$idx].in_use" bool "$in_use_flag"
        else
            json_set ".${bucket}[$idx].in_use" null
        fi

        json_set_key ".env" "$(port_env_var_name "$svc")" int "$effective_port"
    done <<< "$all_ports"

    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project" "$all_ports"
    local wt_path db_url
    wt_path=$(get_worktree_path "$project" "$branch" 2>/dev/null)
    if db_url=$(resolve_db_url "$PROJECT_CONFIG_FILE" "$wt_path"); then
        local db_row db_host db_port db_user db_name
        db_row=$(parse_db_url_components "$db_url")
        IFS=$'\x1f' read -r db_host db_port db_user db_name <<< "$db_row"

        json_set ".database" obj
        json_set ".database.host" str "$db_host"
        json_set ".database.port" int "$db_port"
        json_set ".database.user" str "$db_user"
        json_set ".database.name" str "$db_name"
        json_set ".database.url_redacted" str "$(redact_db_url "$db_url")"
    else
        json_set ".database" null
    fi

    json_emit
}

# Print the 'wt ports' help page to stdout.
show_ports_help() {
    cat << 'EOF'
Prints the reserved and dynamic port assignments, effective environment variables, and database
connection string for a worktree's slot.
`set` and `clear` manage a per-service port override instead of printing.

Usage: wt ports [branch] [options]
       wt ports set <service> <port> [branch] [options]
       wt ports clear <service> [branch] [options]

Subcommands:
  set <service> <port>   Override the port for a service in a worktree (see 'wt ports set --help')
  clear <service>        Remove a port override for a service (see 'wt ports clear --help')

Arguments:
  [branch]          Full branch name of the worktree (default: detected from the current directory,
                    else the current git branch)

Options:
  -c, --check          Check whether each effective port is currently in use (default: off)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  --json                  Print one JSON document instead of the tables (default: off; applies to
                          the show form only)
  -h, --help              Show this page

Output (--json):
  project, branch, slot, projected
  reserved[], dynamic[]: service, port, override, effective_port, in_use (null without --check)
  env: { PORT_<SERVICE>: effective port }
  database: { host, port, user, name, url_redacted } (or null when none is configured)

Examples:
  wt ports feature/auth
  wt ports feature/auth --check
  wt ports feature/auth --json
  wt ports set api-server 4500 feature/auth
  wt ports clear api-server feature/auth

Exit codes:
  0  printed
  1  no slot found for a branch wt does not manage and the worktree does not exist
  2  usage error: unknown option, missing option argument, or missing branch

Exit codes are the same with --json.
EOF
}

# Set port override for a service
cmd_ports_set() {
    local service=""
    local port=""
    local branch=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "ports set" "$1" "${2:-}" "wt ports set <service> <port> [branch] [options]"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_ports_set_help
                return 0
                ;;
            -*)
                die_unknown_option "ports set" "$1"
                ;;
            *)
                if [[ -z "$service" ]]; then
                    service="$1"
                elif [[ -z "$port" ]]; then
                    port="$1"
                elif [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$service" ]] || [[ -z "$port" ]]; then
        die_usage "ports set" "service name and port are required" "wt ports set <service> <port> [branch] [options]"
    fi

    # Validate port is a number
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number"
        return 1
    fi

    project=$(require_project "$project")

    # Auto-detect branch from current git branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "ports set" "branch name is required and could not be detected" "wt ports set <service> <port> [branch] [options]"
        fi
        log_info "Using current branch: $branch"
    fi

    # Check if worktree exists
    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")
    if [[ -z "$worktree_path" ]]; then
        die_no_worktree "ports set" "$branch" "$project"
    fi

    # Warn if port is currently in use
    if ! is_port_available "$port"; then
        log_warn "Port $port is currently in use. Override will be set, but the service may fail to start until the port is freed."
    fi

    # Set the override
    set_port_override "$project" "$branch" "$service" "$port"
    log_success "Port override set: $service -> $port (branch: $branch)"

    # Show note about restarting
    echo ""
    log_info "Restart the service to apply: wt stop $service && wt start $service"
}

# Print the 'wt ports set' help page to stdout.
show_ports_set_help() {
    cat << 'EOF'
Writes a per-branch port override for one service and prints a confirmation naming the branch and
the new port.

Usage: wt ports set <service> <port> [branch] [options]

Arguments:
  <service>         Service name (e.g., api-server, frontend)
  <port>            Port number to use
  <branch>          Full branch name (default: the current git branch)

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt ports set api-server 4500
  wt ports set api-server 4500 feature/auth
  wt ports set frontend 3100 --project myproject

Exit codes:
  0  override set
  1  worktree not found for the branch, or the port is not a number
  2  usage error: unknown option, missing option argument, missing service or port, or missing
     branch
EOF
}

# Clear port override for a service
cmd_ports_clear() {
    local service=""
    local branch=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "ports clear" "$1" "${2:-}" "wt ports clear <service> [branch] [options]"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_ports_clear_help
                return 0
                ;;
            -*)
                die_unknown_option "ports clear" "$1"
                ;;
            *)
                if [[ -z "$service" ]]; then
                    service="$1"
                elif [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$service" ]]; then
        die_usage "ports clear" "service name is required" "wt ports clear <service> [branch] [options]"
    fi

    project=$(require_project "$project")

    # Auto-detect branch from current git branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "ports clear" "branch name is required and could not be detected" "wt ports clear <service> [branch] [options]"
        fi
        log_info "Using current branch: $branch"
    fi

    # Clear the override
    clear_port_override "$project" "$branch" "$service"
    log_success "Port override cleared: $service (branch: $branch)"

    # Show note about restarting
    echo ""
    log_info "Restart the service to use default port: wt stop $service && wt start $service"
}

# Print the 'wt ports clear' help page to stdout.
show_ports_clear_help() {
    cat << 'EOF'
Removes a per-branch port override for one service and prints a confirmation naming the branch.

Usage: wt ports clear <service> [branch] [options]

Arguments:
  <service>         Service name (e.g., api-server, frontend)
  <branch>          Full branch name (default: the current git branch)

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt ports clear api-server
  wt ports clear api-server feature/auth

Exit codes:
  0  override cleared (a no-op when none was set)
  1  project could not be resolved
  2  usage error: unknown option, missing option argument, missing service, or missing branch
EOF
}
