#!/bin/bash
# commands/new.sh - Smart worktree creator (Linear-aware)
#
# Usage:
#   wt new NEX-1500           # From Linear task -> nex-1500/google-sheets-sync
#   wt new fix/my-bug         # Plain branch -> fix/my-bug
#   wt new                    # Scratch worktree -> scratch/<timestamp>
#   wt new NEX-1500 -p nexus  # Explicit project

cmd_new() {
    local input=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                project="$2"
                shift 2
                ;;
            -h|--help)
                echo -e "${BOLD}wt new${NC} - Smart worktree creator"
                echo ""
                echo "Usage:"
                echo "  wt new NEX-1500              # From Linear task"
                echo "  wt new fix/my-bug            # Plain branch name"
                echo "  wt new                       # Scratch worktree"
                echo "  wt new NEX-1500 -p nexus     # Explicit project"
                echo ""
                echo "Linear API key lookup (first found wins):"
                echo "  1. \$WT_LINEAR_API_KEY env var"
                echo "  2. ~/.config/wt/config.yaml -> linear.api_key"
                echo "  3. <repo>/me/config.json -> apiKeys.linear"
                echo "  4. ~/.claude/me/config.json -> apiKeys.linear"
                return 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                input="$1"
                shift
                ;;
        esac
    done

    # Detect project
    if [[ -z "$project" ]]; then
        project=$(smart_detect_project) || die "Not in a git repo with wt config. Run: wt init"
    fi

    local base_branch
    base_branch=$(smart_read_config "$project" ".base_branch" "main")

    local branch=""

    if [[ -z "$input" ]]; then
        # Scratch worktree
        branch="scratch/$(date +%Y%m%d-%H%M)"
        log_info "Creating scratch worktree: ${BOLD}$branch${NC}"

    elif smart_is_linear_id "$input"; then
        # Linear task
        local issue_id
        issue_id=$(echo "$input" | tr '[:lower:]' '[:upper:]')

        log_info "Fetching Linear issue: ${BOLD}$issue_id${NC}"

        local api_key
        api_key=$(smart_find_linear_key)
        [[ -n "$api_key" ]] || die "No Linear API key found. Set WT_LINEAR_API_KEY or add to ~/.config/wt/config.yaml"

        local title
        title=$(smart_fetch_linear_issue "$issue_id" "$api_key")

        local slug
        slug=$(smart_slugify "$title")

        local lower_id
        lower_id=$(echo "$issue_id" | tr '[:upper:]' '[:lower:]')
        branch="${lower_id}/${slug}"

        log_info "Linear: ${DIM}${issue_id}${NC} - $title"
        log_info "Branch: ${BOLD}$branch${NC}"

    else
        # Plain branch name
        branch="$input"
        log_info "Creating worktree: ${BOLD}$branch${NC}"
    fi

    log_info "Project: ${BOLD}$project${NC}  Base: ${BOLD}$base_branch${NC}"
    echo ""

    # Delegate to core create
    cmd_create "$branch" --from "$base_branch" -p "$project"
}
