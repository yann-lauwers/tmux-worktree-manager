#!/bin/bash
# commands/status.sh - Show worktree status

# Parse `wt status` arguments and print a worktree's git, service and DB status.
# Args: $1 branch (optional; detected from the current directory when omitted), plus flags
cmd_status() {
    local branch=""
    local project=""
    local json_output=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --services)
                die_unknown_option "status" "$1" "the service table is now shown by default whenever the project has services"
                ;;
            -p|--project)
                require_optarg "status" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            --json)
                json_output=1
                shift
                ;;
            -h|--help)
                show_status_help
                return 0
                ;;
            -*)
                die_unknown_option "status" "$1"
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
        if [[ -z "$branch" ]]; then
            die_usage "status" "branch name is required" "wt status <branch> [options]"
        fi
        log_info "Detected worktree branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Check worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die_no_worktree "status" "$branch" "$project"
    fi

    # Get worktree info
    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    local created_at
    created_at=$(get_worktree_state "$project" "$branch" "created_at")

    if [[ "$json_output" -eq 1 ]]; then
        _status_json "$project" "$branch" "$wt_path" "$slot" "$created_at"
        return 0
    fi

    echo ""
    echo -e "${BOLD}WORKTREE STATUS${NC}"
    echo "$(printf '%.0s-' {1..50})"
    echo ""

    print_kv "Project" "$project"
    print_kv "Branch" "$branch"
    print_kv "Path" "$wt_path"
    print_kv "Slot" "$slot"
    print_kv "Created" "$created_at"

    # Git info (single git call for commit, dirty state, tracking, ahead/behind)
    if [[ -d "$wt_path" ]]; then
        local git_row commit dirty_flag tracking ahead behind
        git_row=$(parse_git_worktree_status "$wt_path")
        IFS=$'\x1f' read -r commit dirty_flag tracking ahead behind <<< "$git_row"

        print_kv "Commit" "${commit:0:7}"

        local dirty="clean"
        [[ "$dirty_flag" == "true" ]] && dirty="${YELLOW}uncommitted changes${NC}"
        echo -e "$(printf '%-20s' "Status:")$dirty"

        if [[ -n "$tracking" ]]; then
            print_kv "Tracking" "$tracking (+${ahead}/-${behind})"
        fi
    fi

    # Show services (includes port info)
    if [[ "$(get_services "$PROJECT_CONFIG_FILE")" -gt 0 ]]; then
        list_services_status "$project" "$branch" "$PROJECT_CONFIG_FILE"
    else
        # No services configured — show ports standalone
        echo ""
        echo -e "${BOLD}Ports${NC}"
        echo "$(printf '%.0s-' {1..50})"

        while IFS=: read -r svc port; do
            [[ -z "$svc" ]] && continue
            local in_use=""
            if port_in_use "$port"; then
                in_use=" ${GREEN}(in use)${NC}"
            fi
            echo -e "  $(printf '%-25s' "$svc:") $port$in_use"
        done < <(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")
    fi

    # DB connection string (if configured)
    # Export port vars so the template can resolve (fallback for not-yet-created worktrees)
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"
    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch" 2>/dev/null)
    local db_url
    if db_url=$(resolve_db_url "$PROJECT_CONFIG_FILE" "$wt_path"); then
        echo ""
        echo -e "${BOLD}Database${NC}"
        echo "$(printf '%.0s-' {1..50})"
        local db_row db_host db_port db_user db_name
        db_row=$(parse_db_url_components "$db_url")
        IFS=$'\x1f' read -r db_host db_port db_user db_name <<< "$db_row"
        print_kv "Host" "$db_host"
        print_kv "Port" "$db_port"
        print_kv "User" "$db_user"
        print_kv "Database" "$db_name"
        print_kv "Connection string" "$(redact_db_url "$db_url")"
    fi

    echo ""
}

# Assemble and print `wt status --json`'s document. Reads the same state and
# config `cmd_status`'s pretty path reads, through the same shared helpers
# (parse_git_worktree_status, parse_db_url_components), so the two never
# disagree about what a worktree's status is.
# Args: $1 project, $2 branch, $3 worktree path, $4 slot, $5 created_at
# Side: runs json_begin/json_emit; writes the document to real stdout
_status_json() {
    local project="$1"
    local branch="$2"
    local wt_path="$3"
    local slot="$4"
    local created_at="$5"

    json_begin

    json_set ".project" str "$project"
    json_set ".branch" str "$branch"
    json_set ".path" str "$wt_path"
    json_set ".slot" int "$slot"
    json_set ".created_at" ts "$created_at"

    if [[ -d "$wt_path" ]]; then
        local git_row commit dirty upstream ahead behind
        git_row=$(parse_git_worktree_status "$wt_path")
        IFS=$'\x1f' read -r commit dirty upstream ahead behind <<< "$git_row"

        json_set ".git" obj
        json_set ".git.commit" str "$commit"
        json_set ".git.dirty" bool "$dirty"
        if [[ -n "$upstream" ]]; then
            json_set ".git.upstream" str "$upstream"
            json_set ".git.ahead" int "$ahead"
            json_set ".git.behind" int "$behind"
        else
            json_set ".git.upstream" null
            json_set ".git.ahead" null
            json_set ".git.behind" null
        fi
    else
        json_set ".git" null
    fi

    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    json_set ".services" arr
    local service_count
    service_count=$(get_services "$PROJECT_CONFIG_FILE")

    if [[ "$service_count" -gt 0 ]]; then
        local i
        for ((i = 0; i < service_count; i++)); do
            local name port_key port override port_override_flag status pid started_at

            name=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "name")
            port_key=$(get_service_by_index "$PROJECT_CONFIG_FILE" "$i" "port_key")

            override=""
            [[ -n "$project" ]] && override=$(get_port_override "$project" "$branch" "$port_key")
            if [[ -n "$override" ]]; then
                port="$override"
                port_override_flag="true"
            else
                port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
                port_override_flag="false"
            fi

            status=$(get_service_status "$project" "$branch" "$name")
            pid=$(get_service_state "$project" "$branch" "$name" "pid")
            [[ "$pid" == "null" ]] && pid=""
            started_at=$(get_service_state "$project" "$branch" "$name" "started_at")

            json_set ".services[$i].name" str "$name"
            json_set ".services[$i].status" str "$status"
            json_set ".services[$i].port" int "$port"
            json_set ".services[$i].port_override" bool "$port_override_flag"
            json_set ".services[$i].pid" int "$pid"
            json_set ".services[$i].started_at" ts "$started_at"
        done
    fi

    json_set ".ports" arr
    local idx=0
    while IFS=: read -r svc port; do
        [[ -z "$svc" ]] && continue
        local override effective_port in_use_flag

        override=""
        [[ -n "$project" ]] && override=$(get_port_override "$project" "$branch" "$svc")
        effective_port="${override:-$port}"

        in_use_flag="false"
        port_in_use "$effective_port" && in_use_flag="true"

        json_set ".ports[$idx].service" str "$svc"
        json_set ".ports[$idx].port" int "$effective_port"
        json_set ".ports[$idx].in_use" bool "$in_use_flag"
        idx=$((idx + 1))
    done <<< "$all_ports"

    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project" "$all_ports"
    local db_url
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

# Print the `wt status` help page.
show_status_help() {
    cat << 'EOF'
Prints a worktree's git status, ports, services and database connection info.
Reads state only: the state and slots files are left unchanged.

Usage: wt status [<branch>] [options]

Arguments:
  <branch>          Branch name (detected from the current directory when omitted)

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  --json                  Print one JSON document instead of the report (default: off)
  -h, --help              Show this page

The per-service status table, including ports, is shown by default whenever the project has
services; a project with none shows the standalone Ports section instead. --json always
includes both services and ports.

Output (--json):
  project, branch, path, slot, created_at, created_at_epoch, created_at_local
  git: { commit, dirty, upstream, ahead, behind } (or null when the path is not a directory)
  services[]: name, status, port, port_override, pid, started_at, started_at_epoch, started_at_local
  ports[]: service, port, in_use
  database: { host, port, user, name, url_redacted } (or null when none is configured)

Examples:
  wt status feature/auth
  wt status feature/auth --json
  wt status                        # branch detected from the current directory

Exit codes:
  0  success
  1  project not found, or worktree not found for the branch
  2  usage error: unknown option, missing argument, or no branch detected

Exit codes are the same with --json.
EOF
}
