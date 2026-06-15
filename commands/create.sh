#!/bin/bash
# commands/create.sh - Create a new worktree (smart, Linear-aware)
#
# Usage:
#   wt create NEX-1500              # From Linear task -> yann/nex-1500-google-sheets-sync
#   wt create fix/my-bug            # Plain branch -> fix/my-bug
#   wt create                       # Scratch worktree -> scratch/<timestamp>
#   wt create fix/my-bug --from staging   # Override base branch
#   wt create NEX-1500 -p nexus     # Explicit project

cmd_create() {
    local input=""
    local project=""
    local no_db=""
    local from_branch=""
    local no_setup=0
    local skip_groups=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            --from)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                from_branch="$2"
                shift 2
                ;;
            --no-setup)
                no_setup=1
                shift
                ;;
            --skip-groups)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                skip_groups="$2"
                shift 2
                ;;
            --no-db)
                no_db=1
                shift
                ;;
            --db)
                no_db=0
                shift
                ;;
            -h|--help)
                show_create_help
                return 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                input="$1"
                shift
                ;;
        esac
    done

    # Detect project
    if [[ -z "$project" ]]; then
        project=$(smart_detect_project) || die "Not in a git repo with wt config. Run: wt init"
    fi

    local base_branch
    if [[ -n "$from_branch" ]]; then
        base_branch="$from_branch"
    else
        base_branch=$(smart_read_config "$project" ".base_branch" "main")
    fi

    local branch=""

    if [[ -z "$input" ]]; then
        # Scratch worktree
        branch="scratch/$(date +%Y%m%d-%H%M)"
        log_info "Creating scratch worktree: ${BOLD}$branch${NC}"

    elif smart_is_linear_id "$input"; then
        # Linear task
        local issue_id
        issue_id=$(echo "$input" | tr '[:lower:]' '[:upper:]')

        log_info "Fetching Linear issue: ${BOLD}$issue_id${NC}"

        local api_key
        api_key=$(smart_find_linear_key)
        [[ -n "$api_key" ]] || die "No Linear API key found. Set WT_LINEAR_API_KEY or add to ~/.config/wt/config.yaml"

        local title
        title=$(smart_fetch_linear_issue "$issue_id" "$api_key")

        local slug
        slug=$(smart_slugify "$title")

        local lower_id
        lower_id=$(echo "$issue_id" | tr '[:upper:]' '[:lower:]')

        local user
        user=$(smart_get_user)
        if [[ -n "$user" ]]; then
            branch="${user}/${lower_id}-${slug}"
        else
            branch="${lower_id}-${slug}"
        fi

        log_info "Linear: ${DIM}${issue_id}${NC} - $title"
        log_info "Branch: ${BOLD}$branch${NC}"

    else
        # Plain branch name
        branch="$input"
        log_info "Creating worktree: ${BOLD}$branch${NC}"
    fi

    log_info "Project: ${BOLD}$project${NC}  Base: ${BOLD}$base_branch${NC}"
    echo ""

    # Check if project has db-grouped setup steps — prompt for ephemeral DB
    local has_db_steps=false
    local config_file
    config_file=$(project_config_path "$project")
    if [[ -f "$config_file" ]]; then
        local sc
        sc=$(get_setup_steps "$config_file")
        for ((idx = 0; idx < sc; idx++)); do
            local grp
            grp=$(get_setup_step "$config_file" "$idx" "group")
            if [[ "$grp" == "db" ]]; then
                has_db_steps=true
                break
            fi
        done
    fi

    if [[ "$has_db_steps" == "true" ]] && [[ -z "$no_db" ]] && [[ "$no_setup" -eq 0 ]]; then
        # Interactive prompt
        local reply
        printf "${BOLD}Spin up ephemeral DB?${NC} [Y/n] "
        read -r reply </dev/tty
        reply="${reply:-y}"
        if [[ "$reply" =~ ^[Nn] ]]; then
            no_db=1
        fi
    fi

    if [[ "$no_db" == "1" ]]; then
        if [[ -n "$skip_groups" ]]; then
            skip_groups="${skip_groups},db"
        else
            skip_groups="db"
        fi
        log_info "Skipping ephemeral DB setup"
    fi

    if [[ "$no_setup" -eq 1 ]]; then
        log_info "Skipping setup steps (--no-setup)"
    fi

    # Delegate to core worker
    _cmd_create_core "$branch" "$base_branch" "$project" "$no_setup" "$skip_groups"
}

show_create_help() {
    cat << 'EOF'
Usage: wt create [<branch-or-task>] [options]

Create a new worktree. Smart and Linear-aware:
  - Linear ID (e.g. NEX-1500) → fetches title, generates branch
  - Plain branch name (e.g. fix/my-bug) → uses it as-is
  - No argument → scratch worktree with timestamp

Aliases: wt c

Options:
  --from <branch>    Base branch (default: project base_branch)
  --no-setup         Skip running setup steps
  --skip-groups <g>  Skip setup groups (comma-separated)
  --no-db            Skip ephemeral DB setup
  --db               Force ephemeral DB setup (no prompt)
  -p, --project      Explicit project name
  -h, --help         Show this help message

Examples:
  wt create NEX-1500
  wt create fix/my-bug
  wt create
  wt create fix/my-bug --from staging
  wt create NEX-1500 -p nexus --no-db

Linear API key lookup (first found wins):
  1. $WT_LINEAR_API_KEY env var
  2. ~/.config/wt/config.yaml -> linear.api_key
  3. <repo>/me/config.json -> apiKeys.linear
  4. ~/.claude/me/config.json -> apiKeys.linear
EOF
}

# Internal worker — runs `git worktree add`, slot allocation, setup, tmux session.
# Called only by cmd_create after argument resolution.
_cmd_create_core() {
    local branch="$1"
    local base_branch="$2"
    local project="$3"
    local no_setup="$4"
    local skip_groups="$5"

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        return 1
    fi

    project=$(require_project "$project" "Could not detect project. Use --project or run 'wt init' first.")
    load_project_config "$project"

    # Verify we're in or at the repo
    local repo_root="$PROJECT_REPO_PATH"
    if [[ ! -d "$repo_root/.git" ]] && [[ ! -f "$repo_root/.git" ]]; then
        die "Not a git repository: $repo_root"
    fi

    # Check if worktree already exists
    if worktree_exists "$branch" "$repo_root"; then
        die "Worktree already exists for branch: $branch"
    fi

    # Run pre_create hook if defined
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    # Track state for cleanup on interrupt
    local _create_cleanup_project=""
    local _create_cleanup_branch=""
    local _create_cleanup_slot=""
    local _create_cleanup_wt_path=""

    _create_cleanup() {
        if [[ -n "$_create_cleanup_slot" ]]; then
            log_warn "Interrupted — cleaning up partial state..."
            release_slot "$_create_cleanup_project" "$_create_cleanup_branch" 2>/dev/null || true
            delete_worktree_state "$_create_cleanup_project" "$_create_cleanup_branch" 2>/dev/null || true
            if [[ -n "$_create_cleanup_wt_path" ]] && [[ -d "$_create_cleanup_wt_path" ]]; then
                git -C "$repo_root" worktree remove --force "$_create_cleanup_wt_path" 2>/dev/null || true
                git -C "$repo_root" worktree prune 2>/dev/null || true
            fi
        fi
    }
    trap _create_cleanup INT TERM

    # Count reserved services for port availability checks
    local services_per_slot
    services_per_slot=$(yq -r '.ports.reserved.services // {} | length' "$PROJECT_CONFIG_FILE" 2>/dev/null)
    [[ -z "$services_per_slot" || "$services_per_slot" == "0" ]] && services_per_slot=2

    # Claim a slot for reserved ports (checks system port availability)
    local slot
    if ! slot=$(claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS" "$PROJECT_RESERVED_PORT_MIN" "$services_per_slot"); then
        die "No available slots. Maximum $PROJECT_RESERVED_SLOTS concurrent worktrees with reserved ports, or all slots have ports in use. Stop or delete an existing worktree, or free the conflicting ports."
    fi
    _create_cleanup_project="$project"
    _create_cleanup_branch="$branch"
    _create_cleanup_slot="$slot"

    log_info "Claimed slot $slot for worktree"

    # Create the worktree
    local wt_path
    if ! wt_path=$(create_worktree "$branch" "$base_branch" "$repo_root"); then
        release_slot "$project" "$branch"
        _create_cleanup_slot=""  # Prevent double cleanup
        die "Failed to create worktree"
    fi
    _create_cleanup_wt_path="$wt_path"

    # Store state
    create_worktree_state "$project" "$branch" "$wt_path" "$slot"

    # Resolve port conflicts at create time
    local port_map
    port_map=$(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")
    local assigned_ports=""

    while IFS=: read -r svc_name svc_port; do
        [[ -z "$svc_name" ]] && continue
        # Prefer any existing override over the calculated port
        local effective_port
        effective_port=$(get_port_override "$project" "$branch" "$svc_name")
        if [[ -z "$effective_port" ]]; then
            effective_port="$svc_port"
        fi
        if port_in_use "$effective_port" || [[ " $assigned_ports " == *" $effective_port "* ]]; then
            local new_port
            if new_port=$(find_available_port "$PROJECT_RESERVED_PORT_MIN" "$PROJECT_RESERVED_PORT_MAX" "" "$assigned_ports"); then
                log_warn "Port $effective_port for '$svc_name' is in use — reassigning to $new_port"
                set_port_override "$project" "$branch" "$svc_name" "$new_port"
                assigned_ports="$assigned_ports $new_port"
            else
                log_warn "Port $effective_port for '$svc_name' is in use and no free port found in reserved range"
                assigned_ports="$assigned_ports $effective_port"
            fi
        else
            assigned_ports="$assigned_ports $effective_port"
        fi
    done <<< "$port_map"

    # Export port variables for setup
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"

    # Export global env vars
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Run setup steps
    local setup_failed=0
    if [[ "$no_setup" -eq 0 ]]; then
        echo ""
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE" "" "$skip_groups"; then
            log_warn "Setup completed with errors"
            setup_failed=1
        fi
    else
        log_info "Skipping setup (--no-setup)"
    fi

    # Create tmux window in the main session
    echo ""
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE"
    set_session_state "$project" "$branch" "$window_name"

    # Creation complete, disable cleanup trap
    _create_cleanup_slot=""
    trap - INT TERM

    # Run post_create hook if defined
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "post_create"

    echo ""
    if [[ "$setup_failed" -eq 1 ]]; then
        log_warn "Worktree created but setup had errors. You may need to run setup manually."
    else
        log_success "Worktree ready!"
    fi
    echo ""
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    print_kv "Branch" "$branch"
    print_kv "Path" "$wt_path"
    print_kv "Slot" "$slot"
    print_kv "tmux" "$tmux_session:$window_name"

    # DB connection string (if configured)
    local db_url
    if db_url=$(resolve_db_url "$PROJECT_CONFIG_FILE"); then
        print_kv "DB" "$db_url"
    fi

    echo ""
    echo "Next step:"
    echo "  cd $wt_path"
}
