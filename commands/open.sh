#!/bin/bash
# commands/open.sh - Open a worktree in cmux/tmux/editor
#
# Usage:
#   wt open                       # fzf picker across all projects
#   wt open nex-1500/fix-chat     # Open by branch/directory name
#   wt open NEX-1500              # Fuzzy match by Linear ID
#   wt open -p nexus              # Filter to one project

# Parse `wt open` arguments and hand off to the resolved opener (cmux, tmux, or a
# plain `cd` into a subshell).
# Args: $1 branch-or-query (optional), plus flags
# Side: execs into the opener; never returns on success
cmd_open() {
    local query=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "open" "$1" "${2:-}"
                project="$2"
                shift 2
                ;;
            -a|--all)
                project=""
                shift
                ;;
            -h|--help)
                show_open_help
                return 0
                ;;
            -*)
                die_unknown_option "open" "$1"
                ;;
            *)
                query="$1"
                shift
                ;;
        esac
    done

    # Default to current project if in a git repo
    if [[ -z "$project" && -z "$query" ]]; then
        project=$(smart_detect_project 2>/dev/null || true)
    fi

    local wt_path=""

    if [[ -z "$query" ]]; then
        wt_path=$(smart_pick_worktree "$project")
    else
        wt_path=$(smart_find_worktree "$query" "$project")
        [[ -n "$wt_path" ]] || die "No worktree matching '$query'. Run: wt ls"
    fi

    local opener
    opener=$(smart_resolve_opener)

    log_info "Opening in ${opener}: ${BOLD}$wt_path${NC}"

    case "$opener" in
        cmux)
            exec cmux "$wt_path"
            ;;
        tmux)
            # Try to attach to existing session or create new one
            local session_name
            session_name=$(basename "$wt_path" | sed 's/[^a-zA-Z0-9_-]/-/g')
            if tmux has-session -t "$session_name" 2>/dev/null; then
                exec tmux attach-session -t "$session_name"
            else
                exec tmux new-session -s "$session_name" -c "$wt_path"
            fi
            ;;
        *)
            echo "cd $wt_path"
            cd "$wt_path" || die "Could not cd to $wt_path"
            exec "$SHELL"
            ;;
    esac
}

# Print the `wt open` / `wt o` help page.
show_open_help() {
    cat << 'EOF'
Opens a worktree in the resolved opener.

With no query, opens an fzf picker; with one, fuzzy-matches it by branch or Linear ID.

Usage: wt open [<branch-or-query>] [options]

Arguments:
  <branch-or-query>  Branch name, directory name, or Linear ID (omit for the fzf picker)

Aliases: wt o

Options:
  -p, --project <name>   Restrict the picker/match to one project (default: all projects)
  -a, --all               Search all projects (default: on — cancels an earlier -p)
  -h, --help              Show this page

Opener is configurable in ~/.config/wt/config.yaml -> opener. Auto-detects: cmux > tmux > cd.

Examples:
  wt open
  wt open nex-1500/fix-chat
  wt open -p nexus

Exit codes:
  0  success
  1  no worktree matches the query
  2  usage error: unknown option or missing argument
EOF
}
