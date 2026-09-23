#!/bin/bash
# commands/code.sh - Open a worktree in an editor
#
# Usage:
#   wt code                   # Auto-detect from cwd or fzf picker
#   wt code <branch>          # Open by branch name
#   wt cursor <branch>        # Alias

# Parse `wt code` arguments and open the resolved worktree in the configured editor.
# Args: $1 branch (optional), plus flags
cmd_code() {
    local branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_code_help
                return 0
                ;;
            -*)
                die_unknown_option "code" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    local wt_path=""

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

# Print the `wt code` / `wt cursor` help page.
show_code_help() {
    cat << 'EOF'
Opens a worktree in the configured editor.

With no branch, auto-detects the worktree from the current directory, or falls
back to an fzf picker when the current directory is not one.

Usage: wt code [<branch>] [options]

Arguments:
  <branch>          Branch name (auto-detected inside a worktree, else an fzf picker)

Aliases: wt cursor

Options:
  -h, --help        Show this page

Editor is configurable in ~/.config/wt/config.yaml -> editor.
Fallback: $VISUAL > $EDITOR > open

Examples:
  wt code
  wt code feature/auth
  wt cursor feature/auth

Exit codes:
  0  success
  1  no worktree found for the branch, or not in a worktree with no fzf installed
  2  usage error: unknown option
EOF
}
