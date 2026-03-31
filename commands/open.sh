#!/bin/bash
# commands/open.sh - Open a worktree in cmux/tmux/editor
#
# Usage:
#   wt open                       # fzf picker across all projects
#   wt open nex-1500/fix-chat     # Open by branch/directory name
#   wt open NEX-1500              # Fuzzy match by Linear ID
#   wt open -p nexus              # Filter to one project

cmd_open() {
    local query=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project) project="$2"; shift 2 ;;
            -a|--all) project=""; shift ;;
            -h|--help)
                echo -e "${BOLD}wt open${NC} - Open a worktree"
                echo ""
                echo "Usage:"
                echo "  wt open                        # fzf picker (all projects)"
                echo "  wt open nex-1500/fix-chat      # Open by branch name"
                echo "  wt open NEX-1500               # Fuzzy match"
                echo "  wt open -p nexus               # Filter to one project"
                echo "  wt open -a                     # All projects (default)"
                echo ""
                echo "Opener is configurable in ~/.config/wt/config.yaml -> opener"
                echo "Auto-detects: cmux > tmux > cd"
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *) query="$1"; shift ;;
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
