#!/bin/bash
# commands/pr.sh - PR management: open in browser, list conflicts, resolve
#
# Usage:
#   wt pr                         # Open PR in browser (auto-detect branch)
#   wt pr <branch>                # Open PR for specific branch
#   wt pr conflicts               # Current project conflicts
#   wt pr conflicts -a            # All projects
#   wt pr conflicts -p nexus      # Specific project
#   wt pr resolve                 # Pick a conflicting PR and resolve it
#   wt pr resolve <branch>        # Resolve a specific branch's conflicting PR

# Dispatch `wt pr` to its `conflicts`/`resolve` subcommands, or to `_pr_open`
# for everything else.
# Args: $1 subcommand-or-branch (optional), plus flags
cmd_pr() {
    case "${1:-}" in
        conflicts|c)
            shift
            cmd_pr_conflicts "$@"
            ;;
        resolve)
            shift
            cmd_pr_resolve "$@"
            ;;
        -h|--help)
            show_pr_help
            ;;
        *)
            _pr_open "$@"
            ;;
    esac
}

# Print the `wt pr` help page.
show_pr_help() {
    cat << 'EOF'
Opens a branch's pull request in the browser, lists conflicting ones, or resolves one.

Usage: wt pr [<branch>] [options]

Subcommands:
  conflicts (c)     List PRs with merge conflicts — see wt pr conflicts --help
  resolve            Rebase or merge a conflicting PR onto its base — see wt pr resolve --help

Options:
  -h, --help        Show this page

Examples:
  wt pr
  wt pr feature/auth
  wt pr conflicts
  wt pr resolve

Exit codes:
  0  success
  1  no branch detected and none given, or no PR found for the branch
  2  usage error: unknown option
EOF
}

# ─── wt pr [branch] — open in browser ──────────────────────────────────────

# Parse `wt pr [branch]` arguments and open that branch's PR in the browser.
# Args: $1 branch (optional; auto-detected from a worktree when omitted), plus flags
_pr_open() {
    local branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_pr_help
                return 0
                ;;
            -*)
                die_unknown_option "pr" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

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

# ─── shared discovery, used by both `pr conflicts` and `pr resolve` ────────

# Resolve the scope filter shared by `pr conflicts` and `pr resolve`: the
# given -p value, or every project under -a, or the current project detected
# from cwd when neither was given.
# Args: $1 filter (possibly empty), $2 all(true|false)
# Out: resolved project filter, empty meaning "every project"
# Side: prints the existing detection-failure warning and returns 1 when
#       neither a filter nor -a was given and detection fails
_pr_scope() {
    local filter="$1"
    local all="$2"

    if [[ -z "$filter" ]] && ! $all; then
        filter=$(smart_detect_project 2>/dev/null || true)
        if [[ -z "$filter" ]]; then
            log_warn "Could not detect project from cwd. Use -a for all projects or -p <project>."
            return 1
        fi
    fi
    printf '%s\n' "$filter"
}

# List every open PR in scope as one pipe-separated record per line. The
# sole source both `pr conflicts` and `pr resolve` read from, so a project's
# PRs are only ever fetched and matched to worktrees in one place.
# Args: $1 project filter (empty = every configured project)
# Out: one "project|branch|number|mergeable|draft|owner_tag|author|repo_nwo|wt_path|title"
#      line per open PR — title is last so a '|' inside it cannot shift an
#      earlier field
_pr_list_records() {
    local filter="$1"
    local gh_user
    gh_user=$(gh api user --jq '.login' 2>/dev/null || true)

    local config
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

        local prs_json
        prs_json=$(gh pr list --repo "$repo_nwo" --state open \
            --json number,headRefName,title,mergeable,isDraft,author 2>/dev/null || true)
        [[ -z "$prs_json" || "$prs_json" == "[]" ]] && continue

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

        while IFS= read -r pr_line; do
            [[ -z "$pr_line" ]] && continue
            local pr_number pr_branch pr_title pr_mergeable pr_draft pr_author
            pr_number=$(echo "$pr_line" | jq -r '.number')
            pr_branch=$(echo "$pr_line" | jq -r '.headRefName')
            pr_title=$(echo "$pr_line" | jq -r '.title')
            pr_mergeable=$(echo "$pr_line" | jq -r '.mergeable')
            pr_draft=$(echo "$pr_line" | jq -r '.isDraft')
            pr_author=$(echo "$pr_line" | jq -r '.author.login')

            local wt_path=""
            local entry
            for entry in ${wt_branches[@]+"${wt_branches[@]}"}; do
                local b="${entry%%|*}"
                if [[ "$b" == "$pr_branch" ]]; then
                    wt_path="${entry#*|}"
                    break
                fi
            done

            local owner_tag="other"
            [[ -n "$gh_user" && "$pr_author" == "$gh_user" ]] && owner_tag="mine"

            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$project" "$pr_branch" "$pr_number" "$pr_mergeable" "$pr_draft" \
                "$owner_tag" "$pr_author" "$repo_nwo" "$wt_path" "$pr_title"
        done < <(echo "$prs_json" | jq -c '.[]')
    done
}

# List the records _pr_list_records returns whose PR GitHub reports as
# CONFLICTING — the one definition of "conflicting" both commands read.
# Args: $1 project filter (empty = every configured project)
# Out: the conflicting records, one per line, in _pr_list_records' format
_pr_conflicting_records() {
    local rec project branch pr_number mergeable rest
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r project branch pr_number mergeable rest <<< "$rec"
        [[ "$mergeable" == "CONFLICTING" ]] && printf '%s\n' "$rec"
    done < <(_pr_list_records "$1")
}

# Render one _pr_list_records record as the display text both the plain list
# and the fzf picker show.
# Args: $1 one record
# Out: the formatted display line (no trailing newline)
_pr_display_line() {
    local entry="$1"
    local project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title
    IFS='|' read -r project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title <<< "$entry"

    local draft_label=""
    [[ "$draft" == "true" ]] && draft_label=" draft"

    local local_tag=""
    [[ -n "$wt_path" ]] && local_tag=" ◆"

    local author_display=""
    [[ "$owner_tag" == "other" ]] && author_display="  @${author}"

    printf "%-10s  #%-5s  %-50s  %s%s%s%s" "$project" "$pr_number" "$branch" "$title" "$draft_label" "$local_tag" "$author_display"
}

# Print the conflicting-PR list: header, one row per record (mine highlighted,
# others dimmed), the total, and — only when asked — the closing hint.
# Args: $1 print the closing hint (0|1), $@ the conflicting records
_pr_print_conflicts() {
    local hint="$1"
    shift
    local -a conflicting=("$@")

    if [[ ${#conflicting[@]} -eq 0 ]]; then
        echo -e "${GREEN}No conflicting PRs found. All clear!${NC}"
        return 0
    fi

    local mine_count=0
    local entry project branch pr_number mergeable draft owner_tag rest
    for entry in "${conflicting[@]}"; do
        IFS='|' read -r project branch pr_number mergeable draft owner_tag rest <<< "$entry"
        [[ "$owner_tag" == "mine" ]] && ((mine_count++))
    done

    echo -e "${BOLD}${RED}Conflicting PRs (mine: ${mine_count}/${#conflicting[@]}):${NC}"
    echo ""
    local i=1
    for entry in "${conflicting[@]}"; do
        IFS='|' read -r project branch pr_number mergeable draft owner_tag rest <<< "$entry"
        local line
        line=$(_pr_display_line "$entry")
        if [[ "$owner_tag" == "mine" ]]; then
            echo -e "  ${CYAN}${i})${NC}  ${line}"
        else
            echo -e "  ${DIM}${i})  ${line}${NC}"
        fi
        ((i++))
    done
    echo ""
    echo -e "${DIM}Total: ${#conflicting[@]} conflicting PR(s)  ◆ = local worktree${NC}"
    if [[ "$hint" -eq 1 ]]; then
        echo -e "${DIM}Use wt pr resolve to interactively resolve${NC}"
    fi
}

# Run the fzf picker over a set of conflicting records, greying out any that
# carry no local worktree.
# Args: $@ the conflicting records (must be non-empty)
# Out: the chosen record
# Side: returns 1 when the picker is cancelled
_pr_pick_conflict() {
    local -a conflicting=("$@")

    local fzf_input=""
    local idx
    for idx in "${!conflicting[@]}"; do
        local entry="${conflicting[$idx]}"
        local project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title line
        IFS='|' read -r project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title <<< "$entry"
        line=$(_pr_display_line "$entry")

        if [[ -n "$wt_path" ]]; then
            fzf_input+="${line}§${owner_tag}§${idx}"$'\n'
        else
            fzf_input+="${line}  (no worktree — read only)§${owner_tag}§${idx}"$'\n'
        fi
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf --ansi \
        --header "Pick a PR to resolve  ◆ local  CTRL-A toggle mine/all" \
        --delimiter '§' --with-nth 1 \
        --height "~$((${#conflicting[@]} + 4))" \
        --reverse \
        --prompt "resolve (mine) > " \
        --query "◆" \
        --bind "ctrl-a:transform-query(if [[ {q} == '◆' ]]; then echo ''; else echo '◆'; fi)+transform-prompt(if [[ {q} == '◆' ]]; then echo 'resolve (all) > '; else echo 'resolve (mine) > '; fi)" \
    ) || return 1

    local sel_idx="${selected##*§}"
    printf '%s\n' "${conflicting[$sel_idx]}"
}

# Drive one PR record's resolution: no local worktree → the create-worktree
# hint; otherwise the rebase/merge strategy picker, then the chosen strategy.
# Args: $1 one pr record
# Side: git rebase/merge against the record's worktree; a cancelled strategy
#       pick prints "Cancelled." and returns 0
_pr_resolve_record() {
    local entry="$1"
    local project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title
    IFS='|' read -r project branch pr_number mergeable draft owner_tag author repo_nwo wt_path title <<< "$entry"

    if [[ -z "$wt_path" ]]; then
        echo -e "${YELLOW}No local worktree for #${pr_number} (${branch}).${NC}"
        echo -e "Create one first:  ${BOLD}wt create ${branch} -p ${project}${NC}"
        echo -e "Then re-run:       ${BOLD}wt pr resolve ${branch}${NC}"
        return 1
    fi

    local base_branch
    base_branch=$(smart_read_config "$project" '.base_branch' 'main')

    local strategy
    strategy=$(printf "rebase  Rewrite history onto %s (cleaner)\nmerge   Merge %s into branch (preserves history)" "$base_branch" "$base_branch" \
        | fzf --ansi \
            --header "Strategy for ${branch} (#${pr_number})" \
            --height "~5" \
            --reverse \
            --prompt "strategy > " \
    ) || { echo "Cancelled."; return 0; }

    _pr_resolve_strategy "${strategy%%  *}" "$project" "$branch" "$wt_path" "$base_branch"
}

# ─── wt pr conflicts — list conflicting PRs ────────────────────────────────

# Print the `wt pr conflicts` help page.
show_pr_conflicts_help() {
    cat << 'EOF'
Lists open PRs with merge conflicts. Reporting only — resolving one is wt pr resolve.

Defaults to the current project; -a widens to every configured project.

Usage: wt pr conflicts [options]

Aliases: wt pr c

Options:
  -p, --project <name>   Restrict to one project (default: the current project)
  -a, --all               Search every configured project (default: off)
  -q, --quick             Omit the closing resolve hint (default: off)
  -h, --help              Show this page

Examples:
  wt pr conflicts
  wt pr conflicts -a
  wt pr conflicts -p nexus
  wt pr conflicts -q

Exit codes:
  0  success
  1  no project detected and none given
  2  usage error: unknown option or missing argument
EOF
}

# Parse `wt pr conflicts` arguments and list every conflicting open PR in scope.
# Args: flags only
cmd_pr_conflicts() {
    local filter=""
    local all=false
    local quick=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "pr conflicts" "$1" "${2:-}"
                filter="$2"
                shift 2
                ;;
            -a|--all) all=true; shift ;;
            -q|--quick) quick=true; shift ;;
            -h|--help)
                show_pr_conflicts_help
                return 0
                ;;
            -*)
                [[ "$1" == -r || "$1" == --resolve ]] && die_usage "pr conflicts" \
                    "unknown option '$1' (resolving is 'wt pr resolve')" "wt pr resolve [<branch>] [options]"
                die_unknown_option "pr conflicts" "$1"
                ;;
            *) shift ;;
        esac
    done

    filter=$(_pr_scope "$filter" "$all") || return 1

    local -a conflicting=()
    local rec
    while IFS= read -r rec; do
        conflicting+=("$rec")
    done < <(_pr_conflicting_records "$filter")

    local print_hint=0
    if ! $quick && [[ -t 0 ]]; then
        print_hint=1
    fi
    _pr_print_conflicts "$print_hint" ${conflicting[@]+"${conflicting[@]}"}
}

# ─── wt pr resolve — resolve one conflicting PR ────────────────────────────

# Print the `wt pr resolve` help page.
show_pr_resolve_help() {
    cat << 'EOF'
Rebases or merges a conflicting PR's branch onto its base, in its local worktree.

With no branch, picks one from an fzf list of conflicting PRs in scope; given a branch,
resolves that branch's PR directly and skips the list. Either way, a second fzf picker
chooses rebase or merge. Defaults to the current project; -a widens to every configured
project.

Usage: wt pr resolve [<branch>] [options]

Arguments:
  [branch]           Branch whose PR to resolve (default: pick from a list of conflicting PRs)

Options:
  -p, --project <name>   Restrict to one project (default: the current project)
  -a, --all               Search every configured project (default: off)
  -h, --help              Show this page

Examples:
  wt pr resolve
  wt pr resolve feature/auth
  wt pr resolve -a
  wt pr resolve -p nexus

Exit codes:
  0  resolved, cancelled, nothing conflicting, or the named PR is already mergeable
  1  no terminal attached, fzf missing, no project detected and none given, the named
     branch has no open PR in scope or is ambiguous under -a, mergeability is still
     unknown, no local worktree for the PR, rebase/merge stopped on conflicts, or the
     base-branch fetch failed
  2  usage error: unknown option, missing option argument, or an extra argument
EOF
}

# Parse `wt pr resolve` arguments and drive a conflicting PR's rebase or merge.
# Args: $1 branch (optional), plus flags
cmd_pr_resolve() {
    local filter=""
    local all=false
    local branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "pr resolve" "$1" "${2:-}"
                filter="$2"
                shift 2
                ;;
            -a|--all) all=true; shift ;;
            -h|--help)
                show_pr_resolve_help
                return 0
                ;;
            -*)
                die_unknown_option "pr resolve" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    die_usage "pr resolve" "unexpected argument '$1'" "wt pr resolve [<branch>] [options]"
                fi
                shift
                ;;
        esac
    done

    if [[ ! -t 0 ]]; then
        log_warn "No terminal attached. Use 'wt pr conflicts' to list conflicting PRs."
        return 1
    fi

    if ! command -v fzf &>/dev/null; then
        die "fzf is required for interactive resolve. Install it, or use 'wt pr conflicts' to list."
    fi

    filter=$(_pr_scope "$filter" "$all") || return 1

    if [[ -n "$branch" ]]; then
        local -a matches=()
        local rec rec_branch rec_mergeable rest
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            IFS='|' read -r _ rec_branch rest <<< "$rec"
            [[ "$rec_branch" == "$branch" ]] && matches+=("$rec")
        done < <(_pr_list_records "$filter")

        if [[ ${#matches[@]} -eq 0 ]]; then
            log_warn "No open PR found for branch: $branch"
            return 1
        fi

        if [[ ${#matches[@]} -gt 1 ]]; then
            local projects="" m
            for m in "${matches[@]}"; do
                projects+="${m%%|*}, "
            done
            log_warn "Branch $branch matches more than one project: ${projects%, }. Use -p <project>."
            return 1
        fi

        local sel_entry="${matches[0]}"
        IFS='|' read -r _ _ _ rec_mergeable rest <<< "$sel_entry"

        case "$rec_mergeable" in
            MERGEABLE)
                echo -e "${GREEN}Nothing to resolve — ${branch} has no merge conflicts.${NC}"
                return 0
                ;;
            UNKNOWN)
                log_warn "Mergeability for ${branch} is still being computed. Re-run shortly."
                return 1
                ;;
        esac

        _pr_resolve_record "$sel_entry"
        return
    fi

    local -a conflicting=()
    local rec
    while IFS= read -r rec; do
        conflicting+=("$rec")
    done < <(_pr_conflicting_records "$filter")

    if [[ ${#conflicting[@]} -eq 0 ]]; then
        _pr_print_conflicts 0
        return 0
    fi

    local picked
    picked=$(_pr_pick_conflict "${conflicting[@]}") || { echo "Cancelled."; return 0; }

    _pr_resolve_record "$picked"
}

# ─── resolution strategies ──────────────────────────────────────────────────

# Fetch the base branch and rebase or merge the worktree's branch onto it; on a
# stop, print how to continue or abort and open the worktree's terminal.
# Args: $1 strategy (rebase|merge), $2 project, $3 branch, $4 worktree path, $5 base branch
# Side: git fetch + rebase/merge in the worktree; attaches its tmux session on a
#       stop; returns 1 on a failed fetch or a stopped rebase/merge
_pr_resolve_strategy() {
    local strategy="$1"
    local project="$2"
    local branch="$3"
    local wt_path="$4"
    local base_branch="$5"

    local banner done_msg push_cmd
    if [[ "$strategy" == "rebase" ]]; then
        banner="Rebasing ${branch} onto ${base_branch}..."
        done_msg="Rebase complete."
        push_cmd="git -C ${wt_path} push --force-with-lease"
    else
        banner="Merging ${base_branch} into ${branch}..."
        done_msg="Merge complete."
        push_cmd="git -C ${wt_path} push"
    fi

    echo ""
    echo -e "${BOLD}${banner}${NC}"

    git -C "$wt_path" fetch origin "$base_branch" 2>&1 | sed 's/^/  /' || return 1

    if ! git -C "$wt_path" "$strategy" "origin/${base_branch}" 2>&1 | sed 's/^/  /'; then
        echo ""
        echo -e "${YELLOW}Conflicts detected. Resolve them in:${NC}"
        echo -e "  ${BOLD}${wt_path}${NC}"
        echo ""
        echo "  After resolving:  git ${strategy} --continue"
        echo "  To abort:         git ${strategy} --abort"
        echo ""

        # Auto-open a terminal window in the worktree for conflict resolution
        load_project_config "$project"
        local window_name
        window_name=$(get_session_name "$project" "$branch")
        attach_session "$window_name" "$PROJECT_CONFIG_FILE"
        return 1
    fi

    echo ""
    echo -e "${GREEN}${done_msg}${NC} Push with:"
    echo -e "  ${push_cmd}"
}
