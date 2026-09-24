#!/bin/bash
# commands/attach.sh - Attach to a worktree's tmux session

# Attach to a worktree's tmux session, creating its window first if none exists.
# Args: $1 branch (detected from the current directory when omitted)
# Side: creates/attaches a tmux session and window; dies (exit 1) if the worktree is missing
cmd_attach() {
    local branch=""
    local window=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--window)
                require_optarg "attach" "$1" "${2:-}" "wt attach <branch> [options]"
                window="$2"
                shift 2
                ;;
            -p|--project)
                require_optarg "attach" "$1" "${2:-}" "wt attach <branch> [options]"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_attach_help
                return 0
                ;;
            -*)
                die_unknown_option "attach" "$1"
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
            die_usage "attach" "branch name is required and could not be detected" "wt attach <branch> [options]"
        fi
        log_info "Detected worktree branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Get window name (sanitized branch)
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Get tmux session name from config
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    # Check if window exists, create if needed
    if ! session_exists "$tmux_session" || ! window_exists "$tmux_session" "$window_name"; then
        if worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
            log_info "Window not found, creating..."
            local wt_path
            wt_path=$(get_worktree_path "$project" "$branch")
            create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE" "$window"
        else
            die_no_worktree "attach" "$branch" "$project"
        fi
    fi

    # Attach to session and select window
    attach_session "$window_name" "$PROJECT_CONFIG_FILE"
}

# Print the 'wt attach' help page to stdout.
show_attach_help() {
    cat << 'EOF'
Attaches to the tmux session for a worktree, creating its window first if none exists yet.
Prints nothing on success — the terminal switches into tmux.

Usage: wt attach <branch> [options]

Arguments:
  <branch>          Full branch name of the worktree (detected from the
                    current directory when omitted)

Options:
  -w, --window <index>   Create the window at this index, moving an existing occupant aside
                          (default: tmux assigns the next index)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt attach feature/auth
  wt attach feature/auth -w 2    # Create at window index 2

Aliases: wt a

Exit codes:
  0  attached
  1  no worktree found for the branch, or the tmux session could not be created
  2  usage error: unknown option, missing option argument, or missing branch
EOF
}
