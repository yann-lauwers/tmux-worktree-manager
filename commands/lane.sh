#!/bin/bash
# commands/lane.sh - Start and list headless lanes: one claude session per worktree
#
# Usage:
#   wt lane start NEX-3345 --prompt "Work NEX-3345."   # detached, nothing on screen
#   wt lane start NEX-3345                             # detached, bare claude
#   wt lane ls                                         # what is running
#   wt lane attach NEX-3345                            # take this terminal to it

# Derive a lane window's tmux name from a branch or ticket.
# Args: $1 branch, ticket or worktree name
# Out: the lane window name, "<worktree-dirname>-lane"
lane_window_name() {
    echo "$(worktree_dirname "$1")-lane"
}

# Build the command a lane window runs, quoting the prompt as one argument.
# Args: $1 prompt (may be empty)
# Out: the command line, safe for a shell to parse
lane_command() {
    local prompt="$1"

    if [[ -z "$prompt" ]]; then
        echo "claude"
        return 0
    fi

    # `--` ends option parsing: a prompt opening with a hyphen is otherwise read as
    # a flag, and shell quoting cannot prevent that — the argument boundary is the
    # thing at stake, not the escaping.
    printf "claude -- '%s'\n" "${prompt//\'/\'\\\'\'}"
}

# Start a headless lane for one target, creating its worktree when absent.
# Args: $1 branch or ticket; --prompt <text>; -p <project>
# Out: the tmux target of the lane window
# Side: may create a worktree; creates a detached tmux window running claude
_lane_start() {
    local query="" prompt="" project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt)
                [[ -n "${2:-}" ]] || { log_error "--prompt requires a value"; return 1; }
                prompt="$2"; shift 2 ;;
            -p|--project)
                [[ -n "${2:-}" ]] || { log_error "$1 requires a value"; return 1; }
                project="$2"; shift 2 ;;
            -h|--help) show_lane_help; return 0 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) query="$1"; shift ;;
        esac
    done

    if [[ -z "$query" ]]; then
        log_error "Usage: wt lane start <branch|ticket> [--prompt <text>]"
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local wt_path
    wt_path=$(smart_find_worktree "$query" "$project")

    if [[ -z "$wt_path" ]]; then
        log_info "No worktree for '$query' — creating it"
        # Thread the project through: resolving against one project and creating in
        # whichever another command auto-detects puts the lane in the wrong repo.
        cmd_create "$query" ${project:+--project "$project"} || return 1
        wt_path=$(smart_find_worktree "$query" "$project")
        [[ -n "$wt_path" ]] || { log_error "Worktree still unresolved after create: $query"; return 1; }
    fi

    local session window command
    session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    window=$(lane_window_name "$(basename "$wt_path")")
    command=$(lane_command "$prompt")

    create_lane_window "$session" "$window" "$wt_path" "$command" || return 1

    log_success "Lane running: ${session}:${window}"
    echo "${session}:${window}"
}

# List the lane windows running for a project.
# Args: -p <project> (optional)
# Out: one line per lane — window name, tab, the directory it is running in
_lane_ls() {
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -n "${2:-}" ]] || { log_error "$1 requires a value"; return 1; }
                project="$2"; shift 2 ;;
            -h|--help) show_lane_help; return 0 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) shift ;;
        esac
    done

    project=$(require_project "$project")
    load_project_config "$project"

    local session
    session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    if ! session_exists "$session"; then
        log_info "No tmux session yet: $session"
        return 0
    fi

    # pane_dead separates a lane that is running from one that died and left its
    # window behind. Without it both read as present.
    local lanes
    lanes=$(tmux list-windows -t "$session" -F "#{window_name}|#{pane_current_path}|#{pane_dead}" 2>/dev/null \
        | awk -F'|' '$1 ~ /-lane$/ { printf "%s\t%s\t%s\n", $1, $2, ($3 == "1" ? "dead" : "running") }')

    if [[ -z "$lanes" ]]; then
        log_info "No lanes running in $session"
        return 0
    fi

    printf '%s\n' "$lanes"
}

# Replace this process with a tmux client attached to one target.
# Args: $1 tmux target, "<session>:<window>"
# Side: execs tmux; this function does not return on success
lane_attach_exec() {
    exec tmux attach -t "$1"
}

# Attach to the lane running for one target.
# Args: $1 branch or ticket; -p <project>
# Side: replaces this process with an attached tmux client
_lane_attach() {
    local query="" project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -n "${2:-}" ]] || { log_error "$1 requires a value"; return 1; }
                project="$2"; shift 2 ;;
            -h|--help) show_lane_help; return 0 ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *) query="$1"; shift ;;
        esac
    done

    if [[ -z "$query" ]]; then
        log_error "Usage: wt lane attach <branch|ticket>"
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local wt_path
    wt_path=$(smart_find_worktree "$query" "$project")
    [[ -n "$wt_path" ]] || { log_error "No worktree matching '$query'"; return 1; }

    local session window
    session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    window=$(lane_window_name "$(basename "$wt_path")")

    if ! window_exists "$session" "$window"; then
        log_error "No lane running for ${window%-lane}. Start one: wt lane start $query"
        return 1
    fi

    lane_attach_exec "${session}:${window}"
}

# Route the lane subcommands.
# Args: $1 subcommand (start|ls), remaining args forwarded
# Side: per subcommand
cmd_lane() {
    local subcommand="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$subcommand" in
        start)     _lane_start "$@" ;;
        ls|list)   _lane_ls "$@" ;;
        attach|a)  _lane_attach "$@" ;;
        -h|--help) show_lane_help ;;
        "")        show_lane_help >&2; return 1 ;;
        *)         log_error "Unknown lane subcommand: $subcommand"; show_lane_help >&2; return 1 ;;
    esac
}

# Print the lane command's usage.
show_lane_help() {
    cat << 'EOF'
Usage: wt lane start <branch|ticket> [--prompt <text>]
       wt lane ls
       wt lane attach <branch|ticket>

Run a claude session per worktree, detached. Nothing opens on screen; attach
when you want it with `wt lane attach <branch|ticket>`.

Subcommands:
  start             Start a lane, creating the worktree when absent
  ls, list          List the lanes running for this project
  attach, a         Attach this terminal to a running lane

Options:
  --prompt <text>   Seed the session with this prompt (omit for a bare session)
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt lane start NEX-3345 --prompt "Work NEX-3345."
  wt lane start feature/auth
  wt lane ls
  wt lane attach NEX-3345
EOF
}
