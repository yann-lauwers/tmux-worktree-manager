#!/bin/bash
# commands/send.sh - Send command to a tmux pane

# Send a command string to one tmux pane in a worktree's window.
# Args: $1 [branch] (detected from the current directory when omitted), then
#       <service|pane_index> <command...> — everything from the pane target
#       onward is read positionally, dashes included, once that many
#       leading words are seen.
# Side: writes to the target pane via send_to_pane; dies (exit 1) if the
#       session, window or service/pane cannot be resolved
cmd_send() {
    local branch=""
    local project=""
    local target=""
    local -a cmd_parts=()
    local -a positionals=()

    # Try to detect branch from current directory before parsing: it decides
    # how many leading positionals (branch + target, or target alone) precede
    # the command, so option parsing can stop at the right word and pass a
    # command like `ls -la` through without rejecting `-la` as an option.
    local detected_branch
    detected_branch=$(detect_worktree_branch)
    local leading=2
    [[ -n "$detected_branch" ]] && leading=1

    # Parse arguments. Once `leading` positionals are collected, stop option
    # parsing and pass everything left, dashes included, as the command.
    while [[ $# -gt 0 ]]; do
        if [[ ${#positionals[@]} -ge $leading ]]; then
            cmd_parts=("$@")
            break
        fi
        case "$1" in
            -p|--project)
                require_optarg "send" "$1" "${2:-}" "wt send [branch] <service|pane_index> <command...>"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_send_help
                return 0
                ;;
            -*)
                die_unknown_option "send" "$1"
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n "$detected_branch" ]]; then
        # In a worktree: positionals = target
        branch="$detected_branch"
        if [[ ${#positionals[@]} -lt 1 || ${#cmd_parts[@]} -eq 0 ]]; then
            die_usage "send" "missing pane target or command" "wt send <service|pane_index> <command...>"
        fi
        target="${positionals[0]}"
    else
        # Not in a worktree: positionals = branch target
        if [[ ${#positionals[@]} -lt 2 || ${#cmd_parts[@]} -eq 0 ]]; then
            die_usage "send" "missing branch, pane target, or command" "wt send <branch> <service|pane_index> <command...>"
        fi
        branch="${positionals[0]}"
        target="${positionals[1]}"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Resolve pane index: numeric = direct pane index, string = service name lookup
    local pane_idx
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        pane_idx="$target"
    else
        pane_idx=$(find_service_pane_index "$PROJECT_CONFIG_FILE" "$target")
        if [[ -z "$pane_idx" ]]; then
            die "Service not found in pane config: $target"
        fi
    fi

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Verify session and window exist
    if ! session_exists "$tmux_session"; then
        die "Tmux session does not exist: $tmux_session"
    fi
    if ! window_exists "$tmux_session" "$window_name"; then
        die "Tmux window does not exist: $window_name"
    fi

    # Join command parts and send
    local full_cmd="${cmd_parts[*]}"
    send_to_pane "$tmux_session" "$window_name" "$pane_idx" "$full_cmd"

    log_success "Sent to ${target} (pane $pane_idx): $full_cmd"
}

# Print the 'wt send' help page to stdout.
show_send_help() {
    cat << 'EOF'
Sends a command string to one tmux pane in a worktree's window and prints a confirmation line naming
the target pane and the command sent.
Everything typed after the pane target is read as the command, flags included: `wt send <branch> 0
ls -la` sends `ls -la`, not an unknown option. Only a -h/--help or unknown option written before the
pane target is read by wt.

Usage: wt send [branch] <service|pane_index> <command...>
       wt send <service|pane_index> <command...>  (inside worktree)

Arguments:
  <branch>          Full branch name (detected from the current directory
                    when omitted)
  <service>         Service name to target (resolved to a pane index)
  <pane_index>      Numeric pane index to target directly
  <command...>      Command string to send, unparsed by wt

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt send feature/auth api-server "echo hello"
  wt send api-server "npm restart"          # Inside worktree
  wt send feature/auth 0 ls -la             # By pane index

Aliases: wt s

Exit codes:
  0  command sent
  1  no matching tmux session, window, or service pane
  2  usage error: unknown option before the pane target, missing option argument, or missing branch,
     pane target, or command
EOF
}
