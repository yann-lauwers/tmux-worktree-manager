#!/bin/bash
# commands/exec.sh - Execute a command in worktree context

# Run a command inside a worktree's directory, with its port and env vars exported.
# Args: $1 branch, $2... command and its own arguments (unparsed by wt, dashes included)
# Side: exports WORKTREE_PATH/BRANCH_NAME/PORT_*, runs the command in $wt_path, dies (exit 1) if the worktree is missing
cmd_exec() {
    local branch=""
    local project=""
    local cmd_args=()

    # Parse arguments. Once the branch positional is set, option parsing stops
    # dead — every remaining word, dashes included, is the command to run, so
    # `wt exec <branch> git --help` passes --help to git rather than to wt.
    while [[ $# -gt 0 ]]; do
        if [[ -n "$branch" ]]; then
            cmd_args+=("$@")
            break
        fi
        case "$1" in
            -p|--project)
                require_optarg "exec" "$1" "${2:-}" "wt exec <branch> <command...>"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_exec_help
                return 0
                ;;
            -*)
                die_unknown_option "exec" "$1"
                ;;
            *)
                branch="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        die_usage "exec" "branch name is required" "wt exec <branch> <command...>"
    fi

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        die_usage "exec" "command is required" "wt exec <branch> <command...>"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Verify worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die_no_worktree "exec" "$branch" "$project"
    fi

    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    # Get slot and export port variables
    local slot
    slot=$(get_worktree_slot "$project" "$branch")
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Export worktree info
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"

    # Execute command in worktree directory
    log_debug "Executing in $wt_path: ${cmd_args[*]}"
    (cd "$wt_path" && "${cmd_args[@]}")
}

show_exec_help() {
    cat << 'EOF'
Runs a command inside a worktree, with its working directory, PORT variables and the project's env
vars set first, and prints whatever that command writes to stdout and stderr.
Everything typed after <branch> is passed to the command as-is, flags included: `wt exec <branch>
git --help` runs `git --help`, not wt's own help. Only a -h/--help or unknown option written before
<branch> is read by wt.

Usage: wt exec <branch> <command...>

Arguments:
  <branch>          Full branch name of the worktree
  <command...>      Command and arguments to execute, unparsed by wt

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt exec feature/auth npm test
  wt exec feature/auth git status
  wt exec feature/auth git --help

Exit codes:
  0  the command exited 0
  1  worktree not found for the branch; otherwise wt exits with the executed command's own status
  2  usage error: unknown option before <branch>, missing option argument, missing branch, or
     missing command
EOF
}
