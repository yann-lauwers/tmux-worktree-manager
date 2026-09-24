#!/bin/bash
# commands/create.sh - Create a new worktree (smart, Linear-aware)
#
# Usage:
#   wt create NEX-1500              # From Linear task -> yann/nex-1500-google-sheets-sync
#   wt create fix/my-bug            # Plain branch -> fix/my-bug
#   wt create                       # Scratch worktree -> scratch/<timestamp>
#   wt create fix/my-bug --from staging   # Override base branch
#   wt create NEX-1500 -p nexus     # Explicit project

# Parse `wt create` arguments and delegate to _cmd_create_core.
# Args: $1 branch-or-task (optional), plus flags
# Side: exits 2 on a usage error; see _cmd_create_core for the rest
cmd_create() {
    local input=""
    local project=""
    local no_db=""
    local from_branch=""
    local no_setup=0
    local skip_groups=""
    local db_from=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "create" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            --from)
                require_optarg "create" "$1" "${2:-}"
                from_branch="$2"
                shift 2
                ;;
            --no-setup)
                no_setup=1
                shift
                ;;
            --skip-groups)
                require_optarg "create" "$1" "${2:-}"
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
            --db-from)
                require_optarg "create" "$1" "${2:-}"
                db_from="$2"
                shift 2
                ;;
            --stack-on)
                require_optarg "create" "$1" "${2:-}"
                from_branch="$2"
                db_from="$2"
                shift 2
                ;;
            -h|--help)
                show_create_help
                return 0
                ;;
            -*)
                die_unknown_option "create" "$1"
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

    # --db-from / --stack-on: borrow another branch's ephemeral DB instead of spinning
    # our own. The project's borrow-shared-db setup step reads WT_DB_FROM and points this
    # worktree's env at the base branch's Postgres; --no-db skips spin/dump/seed.
    if [[ -n "$db_from" ]]; then
        export WT_DB_FROM="$db_from"
        no_db=1
        log_info "Stacked worktree — sharing ephemeral DB from '$db_from'"
    fi

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
        printf '%b' "${BOLD}Spin up ephemeral DB?${NC} [Y/n] "
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
        log_info "Skipping setup steps (--no-setup), except unskippable ones"
    fi

    # Delegate to core worker
    _cmd_create_core "$branch" "$base_branch" "$project" "$no_setup" "$skip_groups"
}

# Print the `wt create` / `wt c` help page.
show_create_help() {
    cat << 'EOF'
Creates a worktree, its git branch, a port slot, and runs its setup steps.

The input decides the branch: a Linear task ID fetches its title and generates a
branch, a plain branch name is used as-is, and no input creates a scratch/<timestamp>
branch.

Usage: wt create [<branch-or-task>] [options]

Arguments:
  <branch-or-task>  Linear ID, plain branch name, or omitted for a scratch worktree

Aliases: wt c

Options:
  --from <branch>       Base branch to create from (default: the project's base_branch)
  --no-setup             Skip setup steps except those marked `always: true` (default: off)
  --skip-groups <g>      Skip setup groups, comma-separated (default: none skipped)
  --no-db                Skip ephemeral DB setup (default: off — prompts when the project has db
                         steps)
  --db                   Force ephemeral DB setup with no prompt (default: off)
  --db-from <branch>     Share <branch>'s ephemeral DB instead of spinning one; implies --no-db
                         (default: spin its own)
  --stack-on <branch>    Shortcut for --from <branch> --db-from <branch> (default: not stacked)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help             Show this page

Writes state and slots: it creates the worktree's state entry and claims a
port slot. When every slot is taken, it first reclaims the slots of stale
entries — worktrees whose directory is missing — then retries once before
failing.

Examples:
  wt create NEX-1500
  wt create fix/my-bug --from staging
  wt create NEX-2544 --stack-on nex-2543/foo   # stack: branch + DB from nex-2543/foo

Linear API key lookup (first found wins):
  1. $WT_LINEAR_API_KEY env var
  2. ~/.config/wt/config.yaml -> linear.api_key
  3. <repo>/me/config.json -> apiKeys.linear
  4. ~/.claude/me/config.json -> apiKeys.linear

Exit codes:
  0  success
  1  no project detected, no available slot, or worktree creation failed
  2  usage error: unknown option or missing argument
EOF
}

# Claim a slot for a new worktree, reclaiming stale entries only on exhaustion:
# a free slot short-circuits, so a worktree whose directory is only missing for
# now keeps its slot until one is actually needed.
# Args: $1 project, $2 branch, $3 max_slots, $4 port_base, $5 services_per_slot
# Out: the claimed slot number
# Side: on exhaustion, releases stale slots and deletes their state entries
claim_slot_reclaiming() {
    local project="$1"
    local branch="$2"
    local max_slots="$3"
    local port_base="$4"
    local services_per_slot="$5"

    local slot
    if slot=$(claim_slot "$project" "$branch" "$max_slots" "$port_base" "$services_per_slot"); then
        echo "$slot"
        return 0
    fi

    local reclaimed
    reclaimed=$(reclaim_stale_worktrees "$project")
    [[ "$reclaimed" -gt 0 ]] || return 1

    claim_slot "$project" "$branch" "$max_slots" "$port_base" "$services_per_slot"
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
    #
    # The bare "already exists" this used to print reads as stale state, and a session that
    # reads it that way writes into a checkout somebody else is standing in. Naming the path
    # and the occupant turns it into what it is: a collision with another seat.
    if worktree_exists "$branch" "$repo_root"; then
        local existing_path occupant
        existing_path=$(worktree_path "$branch" "$repo_root")
        occupant=$(worktree_occupant "$existing_path")

        if [[ -n "$occupant" ]]; then
            die "Worktree for '$branch' already exists at $existing_path, held by cmux workspace '$occupant'. Tell them before writing there, or join with: wt open $branch"
        fi
        die "Worktree for '$branch' already exists at $existing_path (nobody sitting in it). Join with: wt open $branch"
    fi

    # Run pre_create hook if defined
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    # Track state for cleanup on interrupt
    local _create_cleanup_project=""
    local _create_cleanup_branch=""
    local _create_cleanup_slot=""
    local _create_cleanup_wt_path=""

    # shellcheck disable=SC2329 # invoked indirectly via `trap _create_cleanup INT TERM` below
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

    # Claim a slot for reserved ports (checks system port availability); on
    # exhaustion, reclaims stale entries of this project and retries once.
    local slot
    if ! slot=$(claim_slot_reclaiming "$project" "$branch" "$PROJECT_RESERVED_SLOTS" "$PROJECT_RESERVED_PORT_MIN" "$services_per_slot"); then
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

    # Run setup steps. --no-setup still runs the steps a config marked `always: true`:
    # those produce what a worktree IS rather than what it has installed, and a checkout
    # missing one is broken rather than merely bare. Canon linking is the case that
    # earned it — a lane created with --no-setup came up with no CLAUDE.md, no .claude/
    # and no CONTEXT-MAP.md, and nothing reported it.
    local setup_failed=0
    if [[ "$no_setup" -eq 0 ]]; then
        echo ""
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE" "" "$skip_groups"; then
            log_warn "Setup completed with errors"
            setup_failed=1
        fi
    else
        log_info "Skipping setup (--no-setup) — running unskippable steps only"
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE" "" "$skip_groups" 1; then
            log_warn "Unskippable setup steps completed with errors"
            setup_failed=1
        fi
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
