#!/bin/bash
# commands/status.sh - Show worktree status

# Parse `wt status` arguments and print a worktree's git, service and DB status.
# Args: $1 branch (optional; detected from the current directory when omitted), plus flags
cmd_status() {
    local branch=""
    local show_services=0
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --services)
                show_services=1
                shift
                ;;
            -p|--project)
                require_optarg "status" "$1" "${2:-}"
                project="$2"
                shift 2
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
        local git_status
        git_status=$(git -C "$wt_path" status -b --porcelain=v2 2>/dev/null)

        local commit
        commit=$(echo "$git_status" | grep '^# branch.oid' | cut -d' ' -f3)
        print_kv "Commit" "${commit:0:7}"

        local dirty="clean"
        if echo "$git_status" | grep -q '^[12?!]'; then
            dirty="${YELLOW}uncommitted changes${NC}"
        fi
        echo -e "$(printf '%-20s' "Status:")$dirty"

        # Ahead/behind info
        local tracking
        tracking=$(echo "$git_status" | grep '^# branch.upstream' | cut -d' ' -f3 || true)
        if [[ -n "$tracking" ]]; then
            local ab_line
            ab_line=$(echo "$git_status" | grep '^# branch.ab')
            local ahead behind
            ahead=$(echo "$ab_line" | awk '{print $3}' | tr -d '+')
            behind=$(echo "$ab_line" | awk '{print $4}' | tr -d '-')
            print_kv "Tracking" "$tracking (+${ahead:-0}/-${behind:-0})"
        fi
    fi

    # Show services (includes port info)
    if [[ "$show_services" -eq 1 ]] || [[ "$(get_services "$PROJECT_CONFIG_FILE")" -gt 0 ]]; then
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
        # Parse components from postgresql://user@host:port/dbname
        local db_user db_host db_port db_name
        db_user=$(echo "$db_url" | sed -n 's|.*://\([^@]*\)@.*|\1|p')
        db_user="${db_user%%:*}"
        db_host=$(echo "$db_url" | sed -n 's|.*@\([^:]*\):.*|\1|p')
        db_port=$(echo "$db_url" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
        db_name=$(echo "$db_url" | sed -n 's|.*/\([^?]*\).*|\1|p')
        print_kv "Host" "$db_host"
        print_kv "Port" "$db_port"
        print_kv "User" "$db_user"
        print_kv "Database" "$db_name"
        print_kv "Connection string" "$(redact_db_url "$db_url")"
    fi

    echo ""
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
  --services              Show detailed per-service status, including ports (default: off — shown
                          anyway when the project has services)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt status feature/auth
  wt status feature/auth --services
  wt status                        # branch detected from the current directory

Exit codes:
  0  success
  1  project not found, or worktree not found for the branch
  2  usage error: unknown option, missing argument, or no branch detected
EOF
}
