#!/bin/bash
# commands/list.sh - List worktrees

# Parse `wt list` arguments and print the project's worktrees, or every project's count.
# Args: flags only
cmd_list() {
    local project=""
    local show_status=0
    local json_output=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "list" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            --status)
                show_status=1
                shift
                ;;
            -s)
                die_unknown_option "list" "$1" "use --status"
                ;;
            --json)
                json_output=1
                shift
                ;;
            -h|--help)
                show_list_help
                return 0
                ;;
            -*)
                die_unknown_option "list" "$1"
                ;;
            *)
                shift
                ;;
        esac
    done

    # Detect or validate project
    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            # List all projects if we can't detect one
            list_all_projects
            return 0
        fi
    fi

    # Load project configuration
    load_project_config "$project"

    local repo_root="$PROJECT_REPO_PATH"

    if [[ "$json_output" -eq 1 ]]; then
        list_worktrees_json "$project" "$repo_root"
    else
        list_worktrees_pretty "$project" "$repo_root" "$show_status"
    fi
}

list_worktrees_pretty() {
    local project="$1"
    local repo_root="$2"
    local show_status="$3"

    echo ""
    echo -e "${BOLD}Worktrees for project: ${CYAN}$project${NC}"
    echo ""

    local count=0
    local total_slots
    total_slots=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.reserved.slots" "3")

    local used_slots
    used_slots=$(slots_in_use "$project")

    # Header
    if [[ "$show_status" -eq 1 ]]; then
        printf "${BOLD}%-30s %-8s %-15s %-10s${NC}\n" "BRANCH" "SLOT" "SESSION" "STATUS"
        printf "%s\n" "$(printf '%.0s-' {1..65})"
    else
        printf "${BOLD}%-30s %-8s %-40s${NC}\n" "BRANCH" "SLOT" "PATH"
        printf "%s\n" "$(printf '%.0s-' {1..80})"
    fi

    # Batch: read all worktree data in one yq call (branch, path, slot per entry)
    local state_file
    state_file=$(state_file "$project")

    local all_worktrees
    all_worktrees=$(yq -r '.worktrees | to_entries[] | [.key, .value.branch // .key, .value.path // "", .value.slot // ""] | @tsv' "$state_file" 2>/dev/null)

    while IFS=$'\t' read -r sanitized_branch branch path slot; do
        [[ -z "$sanitized_branch" ]] && continue

        local session
        session=$(sanitize_branch_name "$branch")

        # Show git's actual checked-out branch for a live worktree; the stored branch drifts
        # if the branch was renamed after the worktree was created.
        local display_branch="$branch"
        if [[ -d "$path" ]]; then
            local live_branch
            live_branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
            [[ -n "$live_branch" && "$live_branch" != "HEAD" ]] && display_branch="$live_branch"
        fi

        if [[ "$show_status" -eq 1 ]]; then
            local session_status="inactive"
            local tmux_session
            tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
            if window_exists "$tmux_session" "$session" 2>/dev/null; then
                session_status="${GREEN}active${NC}"
            fi

            # Check for dirty worktree
            local dirty=""
            if [[ -d "$path" ]] && [[ -n $(git -C "$path" status --porcelain 2>/dev/null) ]]; then
                dirty=" ${YELLOW}*${NC}"
            fi

            printf "%-30s %-8s %-15s %-10b%b\n" \
                "$(truncate "$display_branch" 28)" \
                "$slot" \
                "$(truncate "$session" 13)" \
                "$session_status" \
                "$dirty"
        else
            printf "%-30s %-8s %-40s\n" \
                "$(truncate "$display_branch" 28)" \
                "$slot" \
                "$(truncate "$path" 38)"
        fi

        ((count++))
    done <<< "$all_worktrees"

    echo ""
    echo -e "Total: ${BOLD}$count${NC} worktree(s), ${BOLD}$used_slots${NC}/${BOLD}$total_slots${NC} slots in use"
}

list_worktrees_json() {
    local project="$1"
    local repo_root="$2"

    local state_file
    state_file=$(state_file "$project")

    # Read all worktree data in one yq call, output as JSON directly
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    local worktrees="[]"

    # Batch read all fields per worktree
    local all_data
    all_data=$(yq -r '.worktrees | to_entries[] | [.key, .value.branch // .key, .value.path // "", .value.slot // "", .value.created_at // ""] | @tsv' "$state_file" 2>/dev/null)

    while IFS=$'\t' read -r sanitized_branch branch path slot created_at; do
        [[ -z "$sanitized_branch" ]] && continue

        local session
        session=$(sanitize_branch_name "$branch")

        # Report git's actual checked-out branch for a live worktree; the stored branch drifts
        # if the branch was renamed after the worktree was created.
        if [[ -d "$path" ]]; then
            local live_branch
            live_branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
            [[ -n "$live_branch" && "$live_branch" != "HEAD" ]] && branch="$live_branch"
        fi

        local session_active="false"
        if window_exists "$tmux_session" "$session" 2>/dev/null; then
            session_active="true"
        fi

        worktrees=$(echo "$worktrees" | jq --arg branch "$branch" \
            --arg path "$path" \
            --arg slot "$slot" \
            --arg session "$session" \
            --arg active "$session_active" \
            --arg created "$created_at" \
            '. + [{
                branch: $branch,
                path: $path,
                slot: ($slot | tonumber),
                session: $session,
                session_active: ($active == "true"),
                created_at: $created
            }]')
    done <<< "$all_data"

    echo "$worktrees" | jq '.'
}

list_all_projects() {
    echo ""
    echo -e "${BOLD}Configured projects:${NC}"
    echo ""

    local count=0
    for project in $(list_projects); do
        local config_file
        config_file=$(project_config_path "$project")

        local repo_path
        repo_path=$(yaml_get "$config_file" ".repo_path" "")
        repo_path=$(expand_path "$repo_path")

        local wt_count=0
        if [[ -f "$(state_file "$project")" ]]; then
            wt_count=$(list_worktree_states "$project" | wc -l | tr -d ' ')
        fi

        printf "  ${CYAN}%-20s${NC} %s ${DIM}(%d worktrees)${NC}\n" \
            "$project" \
            "$repo_path" \
            "$wt_count"

        ((count++))
    done

    if [[ "$count" -eq 0 ]]; then
        echo "  No projects configured. Run 'wt init' in a git repository."
    fi

    echo ""
}

# Print the `wt list` help page.
show_list_help() {
    cat << 'EOF'
Prints the worktrees for one project as a table, or every project's worktree count.
Reads state only: the state and slots files are left unchanged.

With no project detected and none given, lists every configured project instead.

Usage: wt list [options]

Options:
  -p, --project <name>   Project to list (default: detected from the current directory)
  --status                Show session and dirty-tree status per worktree (default: off)
  --json                  Print as a JSON array (default: off)
  -h, --help              Show this page

Examples:
  wt list
  wt list --status
  wt list --project myproject --json

Exit codes:
  0  success
  2  usage error: unknown option or missing argument
EOF
}
