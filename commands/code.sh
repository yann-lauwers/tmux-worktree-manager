#!/bin/bash
# commands/code.sh - Open a worktree in an editor
#
# Usage:
#   wt code                   # Auto-detect from cwd or fzf picker
#   wt code <branch>          # Open by branch name
#   wt cursor <branch>        # Alias

cmd_code() {
    local branch="${1:-}"
    local wt_path=""

    if [[ "$branch" == "-h" || "$branch" == "--help" ]]; then
        echo -e "${BOLD}wt code${NC} - Open a worktree in an editor"
        echo ""
        echo "Usage:"
        echo "  wt code                   # Auto-detect from cwd or fzf picker"
        echo "  wt code <branch>          # Open by branch name"
        echo ""
        echo "Editor is configurable in ~/.config/wt/config.yaml -> editor"
        echo "Fallback: \$VISUAL > \$EDITOR > open"
        return 0
    fi

    if [[ -z "$branch" ]]; then
        # Auto-detect from current dir
        local git_dir git_common
        git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
        git_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
        if [[ -n "$git_dir" ]] && [[ "$git_dir" != "$git_common" ]]; then
            wt_path=$(git rev-parse --show-toplevel 2>/dev/null)
        fi
    fi

    if [[ -z "$wt_path" ]] && [[ -z "$branch" ]]; then
        # No branch, not in worktree -> fzf picker
        if ! command -v fzf &>/dev/null; then
            die "Not in a worktree. Specify a branch or install fzf."
        fi
        local selected
        selected=$(git worktree list --porcelain 2>/dev/null | awk '
            /^worktree / { path = substr($0, 10) }
            /^branch refs\/heads\// { branch = substr($0, 19); if (path != "") print branch "|" path }
        ' | fzf --prompt="Open in editor> " --delimiter='|' --with-nth=1)
        [[ -z "$selected" ]] && return 0
        wt_path="${selected#*|}"
    fi

    if [[ -z "$wt_path" ]] && [[ -n "$branch" ]]; then
        wt_path=$(smart_resolve_worktree_path "$branch")
    fi

    if [[ -z "$wt_path" ]] || [[ ! -d "$wt_path" ]]; then
        die "Could not find worktree for: ${branch:-<none>}"
    fi

    local editor_cmd
    editor_cmd=$(smart_resolve_editor)

    echo -e "${BOLD}Opening in ${editor_cmd##*/}:${NC} $wt_path"
    "$editor_cmd" "$wt_path"
}
