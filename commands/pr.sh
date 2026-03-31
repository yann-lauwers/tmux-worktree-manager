#!/bin/bash
# commands/pr.sh - Open PR in browser for a worktree branch
#
# Usage:
#   wt pr                    # Auto-detect branch from cwd
#   wt pr <branch>           # Open PR for specific branch

cmd_pr() {
    local branch="${1:-}"

    if [[ "$branch" == "-h" || "$branch" == "--help" ]]; then
        echo -e "${BOLD}wt pr${NC} - Open PR in browser"
        echo ""
        echo "Usage:"
        echo "  wt pr                    # Auto-detect branch from cwd"
        echo "  wt pr <branch>           # Open PR for specific branch"
        return 0
    fi

    if [[ -z "$branch" ]]; then
        # Auto-detect branch from current dir
        local git_dir git_common
        git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
        git_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
        if [[ -n "$git_dir" ]] && [[ "$git_dir" != "$git_common" ]]; then
            branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        fi
    fi

    if [[ -z "$branch" ]]; then
        die "Not in a worktree and no branch specified. Usage: wt pr [branch]"
    fi

    # Try to find and open the PR
    local pr_url
    pr_url=$(gh pr view "$branch" --json url --jq '.url' 2>/dev/null || true)

    if [[ -n "$pr_url" ]]; then
        echo -e "${BOLD}PR:${NC} $pr_url"
        # Cross-platform open
        if command -v open &>/dev/null; then
            open "$pr_url"
        elif command -v xdg-open &>/dev/null; then
            xdg-open "$pr_url"
        else
            echo "Open in browser: $pr_url"
        fi
    else
        log_warn "No PR found for branch: $branch"
    fi
}
