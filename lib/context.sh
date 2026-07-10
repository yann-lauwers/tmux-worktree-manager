#!/bin/bash
# lib/context.sh - Resolve a command's operating context into WT_CTX_* globals.
#
# Deepens the identical preamble that every single-worktree command otherwise
# re-derives: project resolution, config load, worktree verification, path/slot
# lookup, and (optionally) port/env export. Callers resolve the branch first —
# its positional grammar varies per command (auto-detect, explicit, subcommand-
# first) — then hand it here for the identical tail.

# Resolve project + worktree path/slot for a command operating on one existing worktree.
# Args: $1 branch (already resolved by caller), $2 project override ("" = auto-detect)
# Side: sets WT_CTX_{PROJECT,BRANCH,PATH,SLOT}; loads PROJECT_*; dies if the worktree is missing
resolve_worktree_context() {
    local branch="$1"
    local project="${2:-}"

    WT_CTX_PROJECT=$(require_project "$project")
    load_project_config "$WT_CTX_PROJECT"

    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    WT_CTX_BRANCH="$branch"
    WT_CTX_PATH=$(get_worktree_path "$WT_CTX_PROJECT" "$branch")
    WT_CTX_SLOT=$(get_worktree_slot "$WT_CTX_PROJECT" "$branch")
}

# Export ports + env for the resolved context; call after resolve_worktree_context.
# Args: none (reads WT_CTX_*)
# Side: exports PORT_<service> (honoring overrides), project .env vars, WORKTREE_PATH, BRANCH_NAME
export_worktree_env() {
    export_port_vars "$WT_CTX_BRANCH" "$PROJECT_CONFIG_FILE" "$WT_CTX_SLOT" "$WT_CTX_PROJECT"
    export_env_vars "$PROJECT_CONFIG_FILE"
    export WORKTREE_PATH="$WT_CTX_PATH"
    export BRANCH_NAME="$WT_CTX_BRANCH"
}

# Resolve project + the tmux session/window for a command inspecting a worktree window.
# Args: $1 branch (already resolved by caller), $2 project override ("" = auto-detect)
# Side: sets WT_CTX_{PROJECT,BRANCH,TMUX_SESSION,TMUX_WINDOW}; loads PROJECT_*; dies if session/window absent
resolve_tmux_context() {
    local branch="$1"
    local project="${2:-}"

    WT_CTX_PROJECT=$(require_project "$project")
    load_project_config "$WT_CTX_PROJECT"
    WT_CTX_BRANCH="$branch"
    WT_CTX_TMUX_SESSION=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    WT_CTX_TMUX_WINDOW=$(get_session_name "$WT_CTX_PROJECT" "$branch")

    if ! session_exists "$WT_CTX_TMUX_SESSION"; then
        die "Tmux session does not exist: $WT_CTX_TMUX_SESSION"
    fi
    if ! window_exists "$WT_CTX_TMUX_SESSION" "$WT_CTX_TMUX_WINDOW"; then
        die "Tmux window does not exist: $WT_CTX_TMUX_WINDOW"
    fi
}

# Synthesize a slot-0 context for the main checkout, so start/stop run the root like a worktree.
# Args: none
# Side: sets WT_CTX_{BRANCH,PATH,SLOT,MAIN}; exports WT_MAIN_CONTEXT, WT_ROOT_WORKTREE_PATH, WT_ROOT_SLOT
synth_main_root_context() {
    WT_CTX_BRANCH=$(current_branch)
    WT_CTX_PATH=$(git_root)
    WT_CTX_SLOT=0
    WT_CTX_MAIN=1
    export WT_MAIN_CONTEXT=1
    export WT_ROOT_WORKTREE_PATH="$WT_CTX_PATH"
    export WT_ROOT_SLOT=0
}
