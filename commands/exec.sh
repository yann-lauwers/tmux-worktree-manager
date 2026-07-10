#!/bin/bash
# commands/exec.sh - Execute a command in worktree context

# Execute an arbitrary command in a worktree's directory with ports/env exported.
# Args: $@ CLI flags — <branch> <command...>, -p/--project, -- (end-of-options)
# Side: exports PORT_*/env (via resolve_worktree_context + export_worktree_env); cd's into the worktree and runs the command; dies if the project/worktree is missing
cmd_exec() {
    local branch=""
    local project=""
    local cmd_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_exec_help
                return 0
                ;;
            --)
                shift
                cmd_args+=("$@")
                break
                ;;
            -*)
                if [[ -z "$branch" ]]; then
                    log_error "Unknown option: $1"
                    show_exec_help
                    return 1
                fi
                # After branch, all args are part of the command
                cmd_args+=("$1")
                shift
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    cmd_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        show_exec_help
        return 1
    fi

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        log_error "Command is required"
        show_exec_help
        return 1
    fi

    # Resolve project + worktree context, then export ports/env for the command
    resolve_worktree_context "$branch" "$project"
    export_worktree_env

    # Execute command in worktree directory
    log_debug "Executing in $WT_CTX_PATH: ${cmd_args[*]}"
    (cd "$WT_CTX_PATH" && "${cmd_args[@]}")
}

# Print the `wt exec` usage/help text.
# Out: usage text
show_exec_help() {
    cat << 'EOF'
Usage: wt exec <branch> <command...>

Execute a command in the context of a worktree.

The command runs with:
- Working directory set to the worktree path
- PORT variables exported
- Project environment variables set

Arguments:
  <branch>          Branch name of the worktree
  <command...>      Command and arguments to execute

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt exec feature/auth npm test
  wt exec feature/auth git status
  wt exec feature/auth -- npm run build
EOF
}
