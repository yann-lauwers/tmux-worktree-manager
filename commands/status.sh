#!/bin/bash
# commands/status.sh - Show worktree status

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
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_status_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_status_help
                return 1
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
            log_error "Branch name is required"
            show_status_help
            return 1
        fi
        log_info "Detected worktree branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Clean up stale worktree entries
    cleanup_stale_worktrees "$project"

    # Check worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    # Get worktree info
    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    local created_at
    created_at=$(get_worktree_state "$project" "$branch" "created_at")

    # Clean up stale services
    cleanup_stale_services "$project" "$branch"

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
    # Export port vars so the template can resolve
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"
    local db_url
    if db_url=$(resolve_db_url "$PROJECT_CONFIG_FILE"); then
        echo ""
        echo -e "${BOLD}Database${NC}"
        echo "$(printf '%.0s-' {1..50})"
        # Parse components from postgresql://user@host:port/dbname
        local db_user db_host db_port db_name
        db_user=$(echo "$db_url" | sed -n 's|.*://\([^@]*\)@.*|\1|p')
        db_host=$(echo "$db_url" | sed -n 's|.*@\([^:]*\):.*|\1|p')
        db_port=$(echo "$db_url" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
        db_name=$(echo "$db_url" | sed -n 's|.*/\([^?]*\).*|\1|p')
        print_kv "Host" "$db_host"
        print_kv "Port" "$db_port"
        print_kv "User" "$db_user"
        print_kv "Password" "(none)"
        print_kv "Database" "$db_name"
        print_kv "Connection string" "$db_url"
    fi

    echo ""
}

show_status_help() {
    cat << 'EOF'
Usage: wt status <branch> [options]

Show detailed status of a worktree.

Arguments:
  <branch>          Branch name of the worktree

Options:
  --services        Show detailed service status
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt status feature/auth
  wt status feature/auth --services
EOF
}
