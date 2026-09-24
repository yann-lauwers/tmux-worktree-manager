#!/bin/bash
# commands/run.sh - Run a specific setup step

# Re-run one named setup step from the project config in a worktree.
# Args: $1 branch, $2 step-name
# Side: exports port/env vars, runs the step; dies (exit 1) if the worktree or step is missing
cmd_run() {
    local branch=""
    local step_name=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "run" "$1" "${2:-}" "wt run <branch> <step-name>"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_run_help
                return 0
                ;;
            -*)
                die_unknown_option "run" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                elif [[ -z "$step_name" ]]; then
                    step_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        die_usage "run" "branch name is required" "wt run <branch> <step-name>"
    fi

    if [[ -z "$step_name" ]]; then
        die_usage "run" "step name is required" "wt run <branch> <step-name>"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Verify worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die_no_worktree "run" "$branch" "$project"
    fi

    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    # Get slot and export port variables
    local slot
    slot=$(get_worktree_slot "$project" "$branch")
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Run the step
    run_setup_step "$wt_path" "$PROJECT_CONFIG_FILE" "$step_name"
}

# Print the 'wt run' help page to stdout.
show_run_help() {
    cat << 'EOF'
Re-runs one named setup step from the project config in a worktree, with the worktree's port and
environment variables exported first.
Prints only the step's own "Running: <description>" line plus whatever the step's command writes —
nothing else.

Usage: wt run <branch> <step-name>

Arguments:
  <branch>          Full branch name of the worktree
  <step-name>       Name of the setup step to run (see your project config's
                    setup: list for the available names)

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt run feature/auth init-submodules
  wt run feature/auth install-deps-app

Exit codes:
  0  step ran and reported success
  1  worktree not found, or the step failed
  2  usage error: unknown option, missing option argument, missing branch, or missing step name
EOF
}
