#!/bin/bash
# lib/worktree.sh - Git worktree operations

# Default worktree directory inside repo
WT_DIR_NAME=".worktrees"

# Get worktrees directory path
# Uses PROJECT_WORKTREE_DIR (from project config) when set, otherwise falls back to $repo/.worktrees
#
# That fallback nests worktrees inside the checkout, which docs/adr/0001 argues
# against and every project config here overrides. It stays because changing a
# default silently relocates the worktrees of any project that never set the key;
# `wt doctor` is what surfaces a project still on it.
worktrees_dir() {
    local repo_root="${1:-$(git_root)}"
    if [[ -n "${PROJECT_WORKTREE_DIR:-}" ]]; then
        echo "$PROJECT_WORKTREE_DIR"
    else
        echo "$repo_root/$WT_DIR_NAME"
    fi
}

# Derive a directory name from a branch name.
# When the branch carries an issue-tracker ID (<letters>-<digits>, e.g. nex-2308), the dir IS
# that ID alone — owner prefix and trailing slug are dropped
# (yann-lauwers/nex-2308-chats-egress -> nex-2308). Branches with no tracker ID keep their full
# sanitized name (chore/lint-sweep -> chore-lint-sweep). Same-ticket collisions (a second branch
# on one ticket) are disambiguated by worktree_path with a numeric suffix (nex-2308-2).
worktree_dirname() {
    local branch="$1"
    # Tracker ID = <letters>-<digits> at the start of a path segment (after ^ or /).
    if [[ "$branch" =~ (^|/)([a-zA-Z]+-[0-9]+)(-|/|$) ]]; then
        echo "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]'
    else
        sanitize_branch_name "$branch" | tr '[:upper:]' '[:lower:]'
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

    local dirname base_dir
    dirname=$(worktree_dirname "$branch")
    base_dir=$(worktrees_dir "$repo_root")

    # Disambiguate a same-ticket collision: if the ticket-id dir is already taken (by another
    # branch on the same ticket), append the lowest free numeric suffix — nex-2308, nex-2308-2, …
    local candidate="$base_dir/$dirname"
    if [[ -e "$candidate" ]]; then
        local n=2
        while [[ -e "$base_dir/${dirname}-${n}" ]]; do n=$((n + 1)); done
        candidate="$base_dir/${dirname}-${n}"
    fi

    echo "$candidate"
}

# Name the cmux workspace standing in a worktree, when one is.
# A worktree nobody sits in reads as free to every session that arrives later, including one
# picking up the same branch — so a collision has to say who is already there, not just that
# the directory exists. Degrades to silence rather than failing: cmux and jq are how this
# machine answers the question, not a dependency of the CLI.
# Args: $1 worktree path
# Out: a human-readable workspace label, or nothing when unoccupied or unanswerable
worktree_occupant() {
    local path="$1"

    [[ -n "$path" ]] || return 0
    command -v cmux &>/dev/null || return 0
    command -v jq &>/dev/null || return 0

    cmux workspace list --json 2>/dev/null | jq -r --arg p "$path" '
        .workspaces[]?
        | select(.current_directory == $p or (.current_directory | startswith($p + "/")))
        | if (.has_custom_title // false) then .custom_title else (.id | .[0:8]) end
    ' 2>/dev/null | head -1
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

# Resolve a base branch to the freshest ref that is safe to branch from.
# Usage: _freshest_base_ref <base_branch> <repo_root>
# Outputs: the ref to branch from — `origin/<base>` when the local ref is
#          strictly behind it, otherwise <base> unchanged
# All log messages go to stderr
#
# Best-effort by design: no network failure, missing remote, or absent
# remote-tracking ref may fail a create, so every probe falls back to the
# caller's own ref.
_freshest_base_ref() {
    local base="$1"
    local repo_root="${2:-$(git_root)}"

    # A base that is not a local branch is already whatever the caller meant
    # (a tag, a sha, a remote ref) — leave it alone.
    git -C "$repo_root" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null || {
        printf '%s' "$base"
        return 0
    }

    # Refresh this one ref if the network allows; a failure is not an error.
    git -C "$repo_root" fetch --quiet origin "$base" 2>/dev/null || true

    git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null || {
        printf '%s' "$base"
        return 0
    }

    local counts ahead behind
    counts=$(git -C "$repo_root" rev-list --left-right --count "$base...origin/$base" 2>/dev/null) || {
        printf '%s' "$base"
        return 0
    }
    ahead=${counts%%[[:space:]]*}
    behind=${counts##*[[:space:]]}

    if [[ "$ahead" == "0" ]] && [[ "$behind" != "0" ]]; then
        log_info "Base '$base' is $behind commit(s) behind origin — branching from origin/$base" >&2
        printf '%s' "origin/$base"
        return 0
    fi

    if [[ "$ahead" != "0" ]] && [[ "$behind" != "0" ]]; then
        log_warn "Base '$base' has diverged from origin/$base ($ahead ahead, $behind behind) — branching from the local ref" >&2
    fi

    printf '%s' "$base"
}

# Point a navigation symlink at this repo's worktree tree, beside the checkout.
#
# The worktrees themselves live outside the checkout (docs/adr/0001), which costs
# the one thing nesting was reaching for: you cannot open the project folder and
# see its branches. The link buys that back without moving anything — every
# traversal tool ignores a symlink (`grep -r`, `find` and `rg` do not follow one
# without `--follow`), and removing a symlink never follows it, so no `clean` or
# `rm` reaches the worktrees through it.
#
# Named `<repo>-worktrees` and placed beside the checkout, so each link opens onto
# one repo's branches. A single link per product folder pointing at the whole tree
# was the first shape and listed every unrelated project.
#
# Best-effort: a create never fails because a convenience link could not be
# written, and anything already at the path is left exactly as it is.
# Args: $1 repo_root, $2 worktrees_dir
# Side: may create a symlink beside $1
_ensure_nav_link() {
    local repo_root="$1"
    local wt_dir="$2"

    # A nested layout is already navigable from the checkout — nothing to link.
    [[ "$wt_dir" == "$repo_root"/* ]] && return 0

    local link="${repo_root%/}-worktrees"

    if [[ -L "$link" ]]; then
        [[ "$(readlink "$link")" == "$wt_dir" ]] || log_debug "Nav link $link points elsewhere; left as is"
        return 0
    fi
    if [[ -e "$link" ]]; then
        log_debug "Nav link path $link is occupied by a real file; left as is"
        return 0
    fi

    if ln -s "$wt_dir" "$link" 2>/dev/null; then
        log_debug "Nav link created: $link -> $wt_dir"
    else
        log_debug "Could not create nav link at $link"
    fi
    return 0
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

    # Link the worktree to its repo with RELATIVE paths.
    #
    # Both sides of a worktree link are absolute by default: the worktree's `.git`
    # file names the repo, and `.git/worktrees/<id>/gitdir` names the worktree back.
    # Rename or move either tree and both pointers rot — and only one direction is
    # loud about it. `git worktree list` keeps listing the worktree from the repo
    # side while `git status` inside it answers "not a git repository", so the
    # breakage reads as fine from wherever you happen to be standing.
    #
    # Relative linking survives any move that preserves the geometry between the
    # two trees. Requires git 2.48+; older git refuses the repo outright via the
    # `extensions.relativeWorktrees` marker this sets, which is why it is applied
    # per repo at create time rather than globally.
    if git -C "$repo_root" config worktree.useRelativePaths true 2>/dev/null; then
        log_debug "worktree.useRelativePaths enabled for $repo_root"
    fi

    local git_output
    local git_exit_code

    # Prefer the remote's tip of the base branch over a stale local ref.
    #
    # `git worktree add -b <new> <path> <base>` resolves <base> as an ordinary
    # local ref. That is correct for a branch this checkout tracks and pulls —
    # the project base_branch, typically — and wrong for one it never checks
    # out. A long-lived integration branch that only ever receives merges on
    # the forge is the case: the local ref stays pinned at whatever commit it
    # held when it was first created here, so every worktree cut from it starts
    # from a base that is silently days behind, missing both the code and the
    # decision records merged since.
    #
    # Only a local ref strictly BEHIND its remote is redirected. Local commits
    # on the base are somebody's deliberate work, so an ahead-or-diverged local
    # ref is used as-is and the divergence is reported rather than resolved.
    if [[ -n "$base_branch" ]] && [[ "$base_branch" != origin/* ]]; then
        base_branch=$(_freshest_base_ref "$base_branch" "$repo_root")
    fi

    # Check if branch already exists
    if branch_exists "$branch" "$repo_root"; then
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
            if remote_branch_exists "$branch" origin "$repo_root"; then
                log_info "Tracking remote branch '$branch'..." >&2
                git_output=$(git -C "$repo_root" worktree add --track -b "$branch" "$wt_path" "origin/$branch" 2>&1)
                git_exit_code=$?
            else
                # Create from current branch
                local current
                current=$(current_branch "$repo_root")
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
        _ensure_nav_link "$repo_root" "$wt_dir"
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
        log_warn "No worktree directory at $wt_path"
        return 1
    fi

    # Remove the worktree
    local force_flag=""
    if [[ "$force" == "1" ]]; then
        force_flag="--force"
    fi

    log_info "Removing worktree at: $wt_path"
    if ! git -C "$repo_root" worktree remove $force_flag "$wt_path"; then
        # Without --force this is the expected refusal on a dirty tree — surface it.
        if [[ "$force" != "1" ]]; then
            log_error "Failed to remove worktree. Use --force to force removal."
            return 1
        fi
        # --force was given yet git aborted mid-unlink: a surviving watcher process
        # (esbuild/vite/tsc file-watchers aren't port listeners, so the port-based
        # service stop misses them) re-creates a file under node_modules/.cache while
        # git is emptying it -> rmdir ENOTEMPTY. That strands an unregistered husk dir
        # AND skips the branch delete below. Let the writer settle, retry once, then
        # force the directory removal + prune so a partial teardown never leaves a husk.
        log_warn "git worktree remove aborted mid-unlink; retrying teardown of $wt_path"
        sleep 1
        if [[ -d "$wt_path" ]]; then
            git -C "$repo_root" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
        fi
        git -C "$repo_root" worktree prune
        if [[ -d "$wt_path" ]]; then
            log_error "Failed to remove worktree at: $wt_path"
            return 1
        fi
        log_warn "Worktree force-removed after retry: $wt_path"
    fi

    # Optionally delete the branch. Resolve against the repo, never the cwd: `wt delete`
    # runs from outside the repo, or from inside the worktree that was just removed.
    if [[ "$keep_branch" == "0" ]]; then
        if branch_exists "$branch" "$repo_root"; then
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
        log_error "No directory found at $wt_path for branch '$branch'"
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

# True when the current directory is the MAIN checkout of a configured project
# (not a worktree). At the main root --git-dir == --git-common-dir; inside a
# worktree they differ. Also requires the resolved root to map to a configured
# project (root == that project's repo_path, via detect_project), so the
# exception stays scoped to known roots.
detect_main_repo_root() {
    is_git_repo 2>/dev/null || return 1

    local git_dir git_common_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    [[ "$git_dir" == "$git_common_dir" ]] || return 1

    [[ -n "$(detect_project)" ]] || return 1
    return 0
}

# Parse a worktree's `git status -b --porcelain=v2` into the fields `wt status`
# reports, in one git call. Shared by its human and --json paths so both read
# the same commit, dirty state, and tracking info.
# Args: $1 worktree path
# Out: commit (full sha), dirty (true|false), upstream (empty when untracked),
#      ahead, behind (both "0" when upstream is empty), as one line of
#      \x1f-separated fields — `read` collapses empty tab-separated fields
# Side: runs `git status` read-only in $1
parse_git_worktree_status() {
    local wt_path="$1"
    local git_status
    git_status=$(git -C "$wt_path" status -b --porcelain=v2 2>/dev/null)

    local commit
    commit=$(echo "$git_status" | grep '^# branch.oid' | cut -d' ' -f3)

    local dirty="false"
    echo "$git_status" | grep -q '^[12?!]' && dirty="true"

    local upstream
    upstream=$(echo "$git_status" | grep '^# branch.upstream' | cut -d' ' -f3 || true)

    local ahead="0" behind="0"
    if [[ -n "$upstream" ]]; then
        local ab_line
        ab_line=$(echo "$git_status" | grep '^# branch.ab')
        ahead=$(echo "$ab_line" | awk '{print $3}' | tr -d '+')
        behind=$(echo "$ab_line" | awk '{print $4}' | tr -d '-')
        ahead="${ahead:-0}"
        behind="${behind:-0}"
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$commit" "$dirty" "$upstream" "$ahead" "$behind"
}
