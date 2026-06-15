#!/bin/bash
# commands/pr.sh - PR management: open in browser, check conflicts, resolve
#
# Usage:
#   wt pr                         # Open PR in browser (auto-detect branch)
#   wt pr <branch>                # Open PR for specific branch
#   wt pr conflicts               # Current project conflicts
#   wt pr c -a                    # All projects
#   wt pr c -r                    # Interactive resolve
#   wt pr c -p nexus              # Specific project

cmd_pr() {
    case "${1:-}" in
        conflicts|c)
            shift
            cmd_pr_conflicts "$@"
            ;;
        -h|--help)
            show_pr_help
            ;;
        *)
            _pr_open "$@"
            ;;
    esac
}

show_pr_help() {
    echo -e "${BOLD}wt pr${NC} - PR management"
    echo ""
    echo "Usage:"
    echo "  wt pr                         # Open PR in browser (auto-detect)"
    echo "  wt pr <branch>                # Open PR for specific branch"
    echo "  wt pr conflicts               # Current project"
    echo "  wt pr conflicts -a            # All projects"
    echo "  wt pr conflicts -r            # Interactive resolve"
    echo "  wt pr conflicts -p <project>  # Specific project"
    echo ""
    echo "Alias: wt pr c"
}

# ─── wt pr [branch] — open in browser ──────────────────────────────────────

_pr_open() {
    local branch="${1:-}"

    if [[ -z "$branch" ]]; then
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

    local pr_url
    pr_url=$(gh pr view "$branch" --json url --jq '.url' 2>/dev/null || true)

    if [[ -n "$pr_url" ]]; then
        echo -e "${BOLD}PR:${NC} $pr_url"
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

# ─── wt pr conflicts — list and resolve conflicting PRs ────────────────────

cmd_pr_conflicts() {
    local filter=""
    local all=false
    local resolve=false
    local quick=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project) filter="$2"; shift 2 ;;
            -a|--all) all=true; shift ;;
            -r|--resolve) resolve=true; shift ;;
            -q|--quick) quick=true; shift ;;
            -h|--help)
                echo -e "${BOLD}wt pr conflicts${NC} - Show PRs with merge conflicts"
                echo ""
                echo "Usage:"
                echo "  wt pr conflicts              # Current project"
                echo "  wt pr conflicts -a           # All projects"
                echo "  wt pr conflicts -r           # Interactive resolve"
                echo "  wt pr conflicts -q           # List only (no picker)"
                echo "  wt pr conflicts -p nexus     # Specific project"
                echo ""
                echo "Alias: wt pr c"
                return 0
                ;;
            *) shift ;;
        esac
    done

    # Default scope: current project (unless -a or -p given)
    if [[ -z "$filter" ]] && ! $all; then
        filter=$(smart_detect_project 2>/dev/null || true)
        if [[ -z "$filter" ]]; then
            log_warn "Could not detect project from cwd. Use -a for all projects or -p <project>."
            return 1
        fi
    fi

    # Get current GitHub username for mine/other tagging
    local gh_user
    gh_user=$(gh api user --jq '.login' 2>/dev/null || true)

    local conflicting=()

    for config in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config" ]] || continue
        local project
        project=$(basename "$config" .yaml)

        [[ -n "$filter" && "$project" != "$filter" ]] && continue

        local repo_root
        repo_root=$(yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|")
        [[ -d "$repo_root" ]] || continue

        local repo_nwo
        repo_nwo=$(smart_get_repo_nwo "$repo_root")
        [[ -z "$repo_nwo" ]] && continue

        # Fetch all open PRs with mergeable status and author in one call
        local prs_json
        prs_json=$(gh pr list --repo "$repo_nwo" --state open \
            --json number,headRefName,title,mergeable,isDraft,author 2>/dev/null || true)
        [[ -z "$prs_json" || "$prs_json" == "[]" ]] && continue

        # Get worktree branches for this project
        local wt_branches=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && wt_branches+=("$line")
        done < <(
            git -C "$repo_root" worktree list --porcelain 2>/dev/null | {
                local wt_path=""
                while IFS= read -r l; do
                    if [[ "$l" =~ ^worktree\ (.+) ]]; then
                        wt_path="${BASH_REMATCH[1]}"
                    elif [[ "$l" =~ ^branch\ refs/heads/(.+) ]]; then
                        [[ "$wt_path" == "$repo_root" ]] && continue
                        echo "${BASH_REMATCH[1]}|${wt_path}"
                    fi
                done
            }
        )

        # Match PRs to worktrees and check for conflicts
        while IFS= read -r pr_line; do
            [[ -z "$pr_line" ]] && continue
            local pr_number pr_branch pr_title pr_mergeable pr_draft pr_author
            pr_number=$(echo "$pr_line" | jq -r '.number')
            pr_branch=$(echo "$pr_line" | jq -r '.headRefName')
            pr_title=$(echo "$pr_line" | jq -r '.title')
            pr_mergeable=$(echo "$pr_line" | jq -r '.mergeable')
            pr_draft=$(echo "$pr_line" | jq -r '.isDraft')
            pr_author=$(echo "$pr_line" | jq -r '.author.login')

            [[ "$pr_mergeable" != "CONFLICTING" ]] && continue

            # Check if this branch has a local worktree
            local wt_path=""
            for entry in "${wt_branches[@]}"; do
                local b="${entry%%|*}"
                if [[ "$b" == "$pr_branch" ]]; then
                    wt_path="${entry#*|}"
                    break
                fi
            done

            local draft_label=""
            [[ "$pr_draft" == "true" ]] && draft_label=" draft"

            local owner_tag="other"
            [[ -n "$gh_user" && "$pr_author" == "$gh_user" ]] && owner_tag="mine"

            conflicting+=("${project}|${pr_branch}|${pr_number}|${pr_title}|${wt_path}|${draft_label}|${repo_nwo}|${pr_author}|${owner_tag}")
        done < <(echo "$prs_json" | jq -c '.[]')
    done

    if [[ ${#conflicting[@]} -eq 0 ]]; then
        echo -e "${GREEN}No conflicting PRs found. All clear!${NC}"
        return 0
    fi

    # Count mine vs total
    local mine_count=0
    for entry in "${conflicting[@]}"; do
        local owner_tag="${entry##*|}"
        [[ "$owner_tag" == "mine" ]] && ((mine_count++))
    done

    # Build display lines for both list and fzf
    # Format: visible_text|owner_tag|idx
    local display_lines=()
    for idx in "${!conflicting[@]}"; do
        local entry="${conflicting[$idx]}"
        local project branch pr_number title wt_path draft_label repo_nwo pr_author owner_tag
        IFS='|' read -r project branch pr_number title wt_path draft_label repo_nwo pr_author owner_tag <<< "$entry"

        local local_tag=""
        [[ -n "$wt_path" ]] && local_tag=" ◆"

        local author_display=""
        [[ "$owner_tag" == "other" ]] && author_display="  @${pr_author}"

        display_lines+=("$(printf "%-10s  #%-5s  %-50s  %s%s%s%s" "$project" "$pr_number" "$branch" "$title" "$draft_label" "$local_tag" "$author_display")")
    done

    # Non-interactive or quick mode: plain list
    if $quick || [[ ! -t 0 ]]; then
        echo -e "${BOLD}${RED}Conflicting PRs (mine: ${mine_count}/${#conflicting[@]}):${NC}"
        echo ""
        local i=1
        for idx in "${!display_lines[@]}"; do
            local owner_tag="${conflicting[$idx]##*|}"
            if [[ "$owner_tag" == "mine" ]]; then
                echo -e "  ${CYAN}${i})${NC}  ${display_lines[$idx]}"
            else
                echo -e "  ${DIM}${i})  ${display_lines[$idx]}${NC}"
            fi
            ((i++))
        done
        echo ""
        echo -e "${DIM}Total: ${#conflicting[@]} conflicting PR(s)  ◆ = local worktree${NC}"
        return 0
    fi

    # Resolve mode: fzf picker
    if $resolve; then
        if ! command -v fzf &>/dev/null; then
            die "fzf is required for interactive resolve. Install it or use -q for list mode."
        fi

        # Build fzf input — all PRs, greyed-out if no local worktree
        local fzf_input=""
        for idx in "${!conflicting[@]}"; do
            local entry="${conflicting[$idx]}"
            local wt_path owner_tag
            wt_path=$(echo "$entry" | cut -d'|' -f5)
            owner_tag="${entry##*|}"

            if [[ -n "$wt_path" ]]; then
                fzf_input+="${display_lines[$idx]}§${owner_tag}§${idx}"$'\n'
            else
                fzf_input+="${display_lines[$idx]}  (no worktree — read only)§${owner_tag}§${idx}"$'\n'
            fi
        done

        if [[ -z "$fzf_input" ]]; then
            echo -e "${GREEN}No conflicting PRs found.${NC}"
            return 0
        fi

        local selected
        selected=$(echo -n "$fzf_input" | fzf --ansi \
            --header "Pick a PR to resolve  ◆ local  CTRL-A toggle mine/all" \
            --delimiter '§' --with-nth 1 \
            --height "~$((${#conflicting[@]} + 4))" \
            --reverse \
            --prompt "resolve (mine) > " \
            --query "◆" \
            --bind "ctrl-a:transform-query(if [[ {q} == '◆' ]]; then echo ''; else echo '◆'; fi)+transform-prompt(if [[ {q} == '◆' ]]; then echo 'resolve (all) > '; else echo 'resolve (mine) > '; fi)" \
        ) || { echo "Cancelled."; return 0; }

        local sel_idx="${selected##*§}"
        local sel_entry="${conflicting[$sel_idx]}"
        local sel_project sel_branch sel_pr sel_title sel_wt_path sel_draft sel_nwo sel_author sel_owner
        IFS='|' read -r sel_project sel_branch sel_pr sel_title sel_wt_path sel_draft sel_nwo sel_author sel_owner <<< "$sel_entry"

        # Block selection of PRs without local worktree
        if [[ -z "$sel_wt_path" ]]; then
            echo -e "${YELLOW}No local worktree for #${sel_pr} (${sel_branch}).${NC}"
            echo -e "Create one first:  ${BOLD}wt create ${sel_branch} -p ${sel_project}${NC}"
            return 1
        fi

        local base_branch
        base_branch=$(smart_read_config "$sel_project" '.base_branch' 'main')

        # Strategy picker
        local strategy
        strategy=$(printf "rebase  Rewrite history onto %s (cleaner)\nmerge   Merge %s into branch (preserves history)" "$base_branch" "$base_branch" \
            | fzf --ansi \
                --header "Strategy for ${sel_branch} (#${sel_pr})" \
                --height "~5" \
                --reverse \
                --prompt "strategy > " \
        ) || { echo "Cancelled."; return 0; }

        case "${strategy%%  *}" in
            rebase) _pr_conflicts_rebase "$sel_project" "$sel_branch" "$sel_wt_path" "$base_branch" ;;
            merge)  _pr_conflicts_merge "$sel_project" "$sel_branch" "$sel_wt_path" "$base_branch" ;;
        esac
        return
    fi

    # Default (no -r, no -q): list mine, hint about all
    echo -e "${BOLD}${RED}Conflicting PRs (mine: ${mine_count}/${#conflicting[@]}):${NC}"
    echo ""
    local i=1
    for idx in "${!display_lines[@]}"; do
        local owner_tag="${conflicting[$idx]##*|}"
        if [[ "$owner_tag" == "mine" ]]; then
            echo -e "  ${CYAN}${i})${NC}  ${display_lines[$idx]}"
        else
            echo -e "  ${DIM}${i})  ${display_lines[$idx]}${NC}"
        fi
        ((i++))
    done
    echo ""
    echo -e "${DIM}Total: ${#conflicting[@]} conflicting PR(s)  ◆ = local worktree${NC}"
    echo -e "${DIM}Use -r to interactively resolve${NC}"
}

_pr_conflicts_rebase() {
    local project="$1"
    local branch="$2"
    local wt_path="$3"
    local base_branch="$4"

    if [[ -z "$wt_path" ]]; then
        echo -e "${YELLOW}No local worktree for this branch.${NC}"
        echo -e "Create one first:  ${BOLD}wt create ${branch} -p ${project}${NC}"
        echo -e "Then re-run:       ${BOLD}wt pr conflicts -r${NC}"
        return 1
    fi

    echo ""
    echo -e "${BOLD}Rebasing ${branch} onto ${base_branch}...${NC}"

    git -C "$wt_path" fetch origin "$base_branch" 2>&1 | sed 's/^/  /'

    if ! git -C "$wt_path" rebase "origin/${base_branch}" 2>&1 | sed 's/^/  /'; then
        echo ""
        echo -e "${YELLOW}Conflicts detected. Resolve them in:${NC}"
        echo -e "  ${BOLD}${wt_path}${NC}"
        echo ""
        echo "  After resolving:  git rebase --continue"
        echo "  To abort:         git rebase --abort"
        echo ""

        # Auto-open a terminal window in the worktree for conflict resolution
        load_project_config "$project"
        local window_name
        window_name=$(get_session_name "$project" "$branch")
        attach_session "$window_name" "$PROJECT_CONFIG_FILE"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Rebase complete.${NC} Push with:"
    echo -e "  git -C ${wt_path} push --force-with-lease"
}

_pr_conflicts_merge() {
    local project="$1"
    local branch="$2"
    local wt_path="$3"
    local base_branch="$4"

    if [[ -z "$wt_path" ]]; then
        echo -e "${YELLOW}No local worktree for this branch.${NC}"
        echo -e "Create one first:  ${BOLD}wt create ${branch} -p ${project}${NC}"
        echo -e "Then re-run:       ${BOLD}wt pr conflicts -r${NC}"
        return 1
    fi

    echo ""
    echo -e "${BOLD}Merging ${base_branch} into ${branch}...${NC}"

    git -C "$wt_path" fetch origin "$base_branch" 2>&1 | sed 's/^/  /'

    if ! git -C "$wt_path" merge "origin/${base_branch}" 2>&1 | sed 's/^/  /'; then
        echo ""
        echo -e "${YELLOW}Conflicts detected. Resolve them in:${NC}"
        echo -e "  ${BOLD}${wt_path}${NC}"
        echo ""
        echo "  After resolving:  git merge --continue"
        echo "  To abort:         git merge --abort"
        echo ""

        # Auto-open a terminal window in the worktree for conflict resolution
        load_project_config "$project"
        local window_name
        window_name=$(get_session_name "$project" "$branch")
        attach_session "$window_name" "$PROJECT_CONFIG_FILE"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Merge complete.${NC} Push with:"
    echo -e "  git -C ${wt_path} push"
}
