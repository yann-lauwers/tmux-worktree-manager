#!/bin/bash
# lib/worktree.sh - Git worktree operations

# Default worktree directory inside repo
WT_DIR_NAME=".worktrees"

# Get worktrees directory path
# Uses PROJECT_WORKTREE_DIR (from project config) when set, otherwise falls back to $repo/.worktrees
worktrees_dir() {
    local repo_root="${1:-$(git_root)}"
    if [[ -n "${PROJECT_WORKTREE_DIR:-}" ]]; then
        echo "$PROJECT_WORKTREE_DIR"
    else
        echo "$repo_root/$WT_DIR_NAME"
    fi
}

# Shorten branch name for directory use
# Linear branches: user/prefix-1234-slug OR prefix-1234/slug -> prefix-1234
# Everything else -> full sanitized name
worktree_dirname() {
    local branch="$1"
    # Match user/prefix-number-slug (e.g. yann-lauwers/nex-1641-some-slug)
    if [[ "$branch" =~ ^[a-zA-Z-]+/([a-zA-Z]+-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
    # Match prefix-number/slug (e.g. nex-1234/some-slug)
    elif [[ "$branch" =~ ^([a-zA-Z]+-[0-9]+)/ ]]; then
        echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
    else
        sanitize_branch_name "$branch"
    fi
}

# Resolve a worktree path from git's actual branch↔worktree mapping (the source of truth).
# A branch renamed after its worktree was created no longer matches the dirname derived from
# the branch string; git still records which directory holds the branch. The main worktree is
# skipped so a branch checked out in the primary repo never resolves to the repo root.
worktree_path_for_branch() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk \
        -v ref="refs/heads/$branch" -v root="$repo_root" '
        /^worktree / { p = substr($0, 10) }
        $1 == "branch" && $2 == ref && p != root { print p; exit }
    '
}

# Get worktree path for a branch. Prefers git's real mapping; falls back to the path derived
# from the branch name when no live worktree holds the branch (e.g. during create).
worktree_path() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    local live_path
    live_path=$(worktree_path_for_branch "$branch" "$repo_root")
    if [[ -n "$live_path" ]]; then
        echo "$live_path"
        return
    fi

    local dirname
    dirname=$(worktree_dirname "$branch")

    echo "$(worktrees_dir "$repo_root")/$dirname"
}

# Check if a worktree exists for a branch
worktree_exists() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    # Check default .worktrees/ location first
    local path
    path=$(worktree_path "$branch" "$repo_root")
    [[ -d "$path" ]] && return 0

    # Fall back to state file (supports externally-created worktrees)
    if [[ -n "${PROJECT_NAME:-}" ]]; then
        local state_path
        state_path=$(get_worktree_state "$PROJECT_NAME" "$branch" "path" 2>/dev/null)
        [[ -n "$state_path" ]] && [[ -d "$state_path" ]]
    else
        return 1
    fi
}

# List all worktrees (excluding the main one)
list_worktrees() {
    local repo_root="${1:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | while read -r line; do
        if [[ "$line" =~ ^worktree\ (.+) ]]; then
            local wt_path="${BASH_REMATCH[1]}"
            # Skip main worktree
            if [[ "$wt_path" != "$repo_root" ]]; then
                echo "$wt_path"
            fi
        fi
    done
}

# Get branch name for a worktree path
get_worktree_branch() {
    local wt_path="$1"
    local repo_root="${2:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | awk -v path="$wt_path" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / && wt == path { print substr($0, 19) }
    '
}

# Create a new worktree
# Usage: create_worktree <branch> [base_branch] [repo_root]
# Outputs: the worktree path on success (to stdout)
# All log messages go to stderr
create_worktree() {
    local branch="$1"
    local base_branch="${2:-}"
    local repo_root="${3:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    # Ensure worktrees directory exists
    local wt_dir
    wt_dir=$(worktrees_dir "$repo_root")
    ensure_dir "$wt_dir"

    # Add to .gitignore only if worktrees are inside repo
    if [[ "$wt_dir" == "$repo_root"/* ]]; then
        local gitignore="$repo_root/.gitignore"
        local dir_name
        dir_name=$(basename "$wt_dir")
        if [[ -f "$gitignore" ]]; then
            if ! grep -q "^${dir_name}/?$" "$gitignore" 2>/dev/null; then
                echo "${dir_name}/" >> "$gitignore"
                log_debug "Added ${dir_name}/ to .gitignore"
            fi
        fi
    fi

    local git_output
    local git_exit_code

    # Check if branch already exists
    if branch_exists "$branch"; then
        log_info "Branch '$branch' exists, creating worktree..." >&2
        git_output=$(git -C "$repo_root" worktree add "$wt_path" "$branch" 2>&1)
        git_exit_code=$?
    else
        # Branch doesn't exist, create it
        if [[ -n "$base_branch" ]]; then
            log_info "Creating branch '$branch' from '$base_branch'..." >&2
            git_output=$(git -C "$repo_root" worktree add -b "$branch" "$wt_path" "$base_branch" 2>&1)
            git_exit_code=$?
        else
            # Check if remote branch exists
            if remote_branch_exists "$branch"; then
                log_info "Tracking remote branch '$branch'..." >&2
                git_output=$(git -C "$repo_root" worktree add --track -b "$branch" "$wt_path" "origin/$branch" 2>&1)
                git_exit_code=$?
            else
                # Create from current branch
                local current
                current=$(current_branch)
                if [[ "$current" == "HEAD" ]]; then
                    log_error "Repository is in detached HEAD state." >&2
                    log_error "Specify a base branch with --from <branch>, e.g.: wt create $branch --from main" >&2
                    return 1
                fi
                log_info "Creating branch '$branch' from '$current'..." >&2
                git_output=$(git -C "$repo_root" worktree add -b "$branch" "$wt_path" 2>&1)
                git_exit_code=$?
            fi
        fi
    fi

    if [[ $git_exit_code -eq 0 ]]; then
        log_success "Worktree created at: $wt_path" >&2
        # Only output the path to stdout (this is what gets captured)
        echo "$wt_path"
        return 0
    else
        log_error "Failed to create worktree: $git_output" >&2
        return 1
    fi
}

# Remove a worktree
# Usage: remove_worktree <branch> [force] [keep_branch] [repo_root]
remove_worktree() {
    local branch="$1"
    local force="${2:-0}"
    local keep_branch="${3:-0}"
    local repo_root="${4:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    # Fall back to state file path if computed path doesn't exist
    if [[ ! -d "$wt_path" ]] && [[ -n "${PROJECT_NAME:-}" ]]; then
        local state_path
        state_path=$(get_worktree_state "$PROJECT_NAME" "$branch" "path" 2>/dev/null)
        if [[ -n "$state_path" ]] && [[ -d "$state_path" ]]; then
            log_debug "Computed path $wt_path not found, using state path: $state_path"
            wt_path="$state_path"
        fi
    fi

    if [[ ! -d "$wt_path" ]]; then
        log_warn "Worktree not found: $wt_path"
        return 1
    fi

    # Remove the worktree
    local force_flag=""
    if [[ "$force" == "1" ]]; then
        force_flag="--force"
    fi

    log_info "Removing worktree at: $wt_path"
    git -C "$repo_root" worktree remove $force_flag "$wt_path"

    if [[ $? -ne 0 ]]; then
        log_error "Failed to remove worktree. Use --force to force removal."
        return 1
    fi

    # Optionally delete the branch
    if [[ "$keep_branch" == "0" ]]; then
        if branch_exists "$branch"; then
            log_info "Deleting branch: $branch"
            if [[ "$force" == "1" ]]; then
                git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
            else
                if ! git -C "$repo_root" branch -d "$branch" 2>/dev/null; then
                    log_warn "Branch '$branch' has unmerged changes. Use --force to delete anyway, or --keep-branch to preserve it."
                fi
            fi
        fi
    fi

    # Prune worktree metadata
    git -C "$repo_root" worktree prune

    return 0
}

# Prune stale worktrees
prune_worktrees() {
    local repo_root="${1:-$(git_root)}"

    log_info "Pruning stale worktrees..."
    git -C "$repo_root" worktree prune -v
}

# Execute a command in worktree context
exec_in_worktree() {
    local branch="$1"
    shift
    local repo_root="${REPO_ROOT:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    # Fall back to state file path if computed path doesn't exist
    if [[ ! -d "$wt_path" ]] && [[ -n "${PROJECT_NAME:-}" ]]; then
        local state_path
        state_path=$(get_worktree_state "$PROJECT_NAME" "$branch" "path" 2>/dev/null)
        if [[ -n "$state_path" ]] && [[ -d "$state_path" ]]; then
            wt_path="$state_path"
        fi
    fi

    if [[ ! -d "$wt_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    log_debug "Executing in $wt_path: $*"
    (cd "$wt_path" && "$@")
}

# Count worktrees (excluding main)
count_worktrees() {
    local repo_root="${1:-$(git_root)}"
    list_worktrees "$repo_root" | wc -l | tr -d ' '
}

# Get all branches with worktrees
get_worktree_branches() {
    local repo_root="${1:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | grep "^branch " | sed 's/branch refs\/heads\///'
}

# Detect if we're inside a worktree and return its branch name
detect_worktree_branch() {
    local current_dir
    current_dir=$(pwd)

    # Check if we're in a .worktrees directory
    if [[ "$current_dir" == *"/.worktrees/"* ]]; then
        # Extract the worktree name from the path
        local wt_part="${current_dir#*/.worktrees/}"
        local wt_name="${wt_part%%/*}"

        # Find the actual branch name from git worktree list
        local repo_root="${current_dir%/.worktrees/*}"
        local branch
        branch=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk -v wt="$repo_root/.worktrees/$wt_name" '
            /^worktree / { current_wt = substr($0, 10) }
            /^branch / && current_wt == wt { print substr($0, 19); exit }
        ')

        if [[ -n "$branch" ]]; then
            echo "$branch"
            return 0
        fi
    fi

    # Try using git to detect if in a worktree
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local git_dir git_common_dir
        git_dir=$(git rev-parse --git-dir 2>/dev/null)
        git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)

        # In a worktree, --git-dir differs from --git-common-dir
        if [[ "$git_dir" != "$git_common_dir" ]]; then
            local branch
            branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [[ -n "$branch" ]] && [[ "$branch" != "HEAD" ]]; then
                echo "$branch"
                return 0
            fi
        fi
    fi

    echo ""
    return 0
}
