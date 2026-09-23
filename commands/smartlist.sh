#!/bin/bash
# commands/smartlist.sh - List worktrees across all projects with PR status
#
# Usage:
#   wt ls                # All projects, with PR status
#   wt ls -q             # Quick (no PR status)
#   wt ls -p nexus       # One project

# Print every project's worktrees, with each one's PR status fetched in parallel.
# Args: flags only
# Out: one section per project to stdout, plus a total count
cmd_smartlist() {
    local filter=""
    local smart_quick=false
    local json_output=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "ls" "$1" "${2:-}"
                filter="$2"
                shift 2
                ;;
            -q|--quick) smart_quick=true; shift ;;
            -s|--status) smart_quick=false; shift ;;
            --json) json_output=1; shift ;;
            -h|--help)
                show_ls_help
                return 0
                ;;
            -*)
                die_unknown_option "ls" "$1"
                ;;
            *) shift ;;
        esac
    done

    if [[ "$json_output" -eq 1 ]]; then
        _smartlist_json "$filter" "$smart_quick"
        return
    fi

    local total=0

    for config in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config" ]] || continue
        local project
        project=$(basename "$config" .yaml)

        [[ -n "$filter" && "$project" != "$filter" ]] && continue

        local repo_root
        repo_root=$(yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|")
        [[ -d "$repo_root" ]] || continue

        # Get repo name with owner for PR links
        local repo_nwo=""
        if [[ "$smart_quick" != "true" ]]; then
            repo_nwo=$(smart_get_repo_nwo "$repo_root")
        fi

        local entries=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && entries+=("$line")
        done < <(_smartlist_entries "$repo_root")

        [[ ${#entries[@]} -eq 0 ]] && continue

        echo -e "${BOLD}${CYAN}${project}${NC}  ${DIM}(${#entries[@]} worktrees)${NC}"

        local local_state="$HOME/.local/share/wt/state/${project}.state.yaml"

        # Fan out PR-status lookups concurrently — one gh call per worktree, fired in
        # parallel into a temp file each, then collected before rendering. Serial lookups
        # made `wt ls` scale linearly with worktree count (N network round-trips); this
        # caps wall time at the slowest single call instead of their sum.
        local badge_dir=""
        if [[ "$smart_quick" != "true" && -n "$repo_nwo" ]]; then
            badge_dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-badges.XXXXXX")
            local bidx=0
            for entry in "${entries[@]}"; do
                smart_pr_badge "${entry%%|*}" "$repo_nwo" > "$badge_dir/$bidx" &
                bidx=$((bidx + 1))
            done
            wait
        fi

        local idx=0
        for entry in "${entries[@]}"; do
            local branch="${entry%%|*}"
            local path="${entry#*|}"

            # Check if managed by wt-core (has slot)
            local managed=""
            if [[ -f "$local_state" ]]; then
                local slot
                slot=$(yq -r ".worktrees.\"$branch\".slot // empty" "$local_state" 2>/dev/null || true)
                if [[ -n "$slot" ]]; then
                    managed=" ${DIM}[slot $slot]${NC}"
                fi
            fi

            # PR status (precomputed in parallel above; empty file = no PR)
            local pr_display=""
            if [[ -n "$badge_dir" && -s "$badge_dir/$idx" ]]; then
                pr_display="  $(cat "$badge_dir/$idx")"
            fi
            idx=$((idx + 1))

            echo -e "  $branch${managed}${pr_display}"
            echo -e "  ${DIM}${path}${NC}"
        done
        [[ -n "$badge_dir" ]] && rm -rf "$badge_dir"
        echo ""
        total=$((total + ${#entries[@]}))
    done

    if [[ $total -eq 0 ]]; then
        echo "No worktrees found across any project."
    else
        echo -e "${DIM}Total: ${total} worktree(s)${NC}"
    fi
}

# List a repo's linked worktrees (the main checkout excluded) from
# `git worktree list --porcelain`. Shared by wt ls's human and --json paths.
# Args: $1 repo root
# Out: one "<branch>|<path>" line per worktree on a branch
_smartlist_entries() {
    local repo_root="$1"
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
}

# Print every configured project (whose repo_path exists) and its worktrees as
# one JSON document, including a project with none. Unlike the human form,
# which skips a project with no worktrees, every match of the filter is
# listed so a caller's project count does not depend on worktree count.
# Args: $1 project filter (empty for all), $2 "true" to skip PR lookups
# Out: one JSON document on stdout ({projects:[...], total:<int>})
_smartlist_json() {
    local filter="$1"
    local smart_quick="$2"

    json_begin
    json_set ".projects" arr

    local total=0
    local pidx=0

    for config in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config" ]] || continue
        local project
        project=$(basename "$config" .yaml)

        [[ -n "$filter" && "$project" != "$filter" ]] && continue

        local repo_root
        repo_root=$(yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|")
        [[ -d "$repo_root" ]] || continue

        local repo_nwo=""
        local pr_lookup="skipped"
        if [[ "$smart_quick" != "true" ]]; then
            repo_nwo=$(smart_get_repo_nwo "$repo_root")
            if [[ -n "$repo_nwo" ]] && command_exists gh; then
                pr_lookup="done"
            else
                pr_lookup="unavailable"
            fi
        fi

        local base=".projects[$pidx]"
        json_set "${base}.project" str "$project"
        json_set "${base}.repo_path" str "$repo_root"
        if [[ -n "$repo_nwo" ]]; then
            json_set "${base}.repo" str "$repo_nwo"
        else
            json_set "${base}.repo" null
        fi
        json_set "${base}.pr_lookup" str "$pr_lookup"
        json_set "${base}.worktrees" arr

        local entries=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && entries+=("$line")
        done < <(_smartlist_entries "$repo_root")

        # Fan out PR lookups in parallel, one gh call per worktree into its own
        # temp file, mirroring the human path's concurrency (smart_pr_badge above).
        local pr_dir=""
        if [[ "$pr_lookup" == "done" && ${#entries[@]} -gt 0 ]]; then
            pr_dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-json-pr.XXXXXX")
            local bidx=0
            for entry in "${entries[@]}"; do
                smart_pr_json "${entry%%|*}" "$repo_nwo" > "$pr_dir/$bidx" &
                bidx=$((bidx + 1))
            done
            wait
        fi

        local widx=0
        for entry in ${entries[@]+"${entries[@]}"}; do
            local branch="${entry%%|*}"
            local path="${entry#*|}"
            local wbase="${base}.worktrees[$widx]"

            json_set "${wbase}.branch" str "$branch"
            json_set "${wbase}.path" str "$path"

            local slot
            slot=$(get_worktree_state "$project" "$branch" "slot")
            if [[ -n "$slot" && "$slot" != "null" ]]; then
                json_set "${wbase}.slot" int "$slot"
                json_set "${wbase}.managed" bool true
            else
                json_set "${wbase}.slot" null
                json_set "${wbase}.managed" bool false
            fi

            local pr_line=""
            [[ -n "$pr_dir" && -s "$pr_dir/$widx" ]] && pr_line=$(cat "$pr_dir/$widx")

            if [[ -n "$pr_line" ]]; then
                local pr_number pr_state pr_draft pr_url
                IFS=$'\t' read -r pr_number pr_state pr_draft pr_url <<< "$pr_line"
                json_set "${wbase}.pr.number" int "$pr_number"
                json_set "${wbase}.pr.state" str "$pr_state"
                json_set "${wbase}.pr.draft" bool "$pr_draft"
                json_set "${wbase}.pr.url" str "$pr_url"
            else
                json_set "${wbase}.pr" null
            fi

            widx=$((widx + 1))
        done
        [[ -n "$pr_dir" ]] && rm -rf "$pr_dir"

        total=$((total + widx))
        pidx=$((pidx + 1))
    done

    json_set ".total" int "$total"
    json_emit
}

# Print the `wt ls` help page.
show_ls_help() {
    cat << 'EOF'
Lists every project's worktrees, one section per project.

Each worktree's PR status is fetched with `gh`, in parallel, unless -q is given.

Usage: wt ls [options]

Options:
  -p, --project <name>   Restrict to one project (default: all projects)
  -q, --quick             Skip the PR-status lookup (default: off)
  -s, --status            Fetch PR status (default: on — cancels an earlier -q)
  --json                  Print one JSON document instead of the table (default: off)
  -h, --help              Show this page

Output (--json):
  { projects: [ { project, repo_path, repo, pr_lookup, worktrees: [ { branch,
    path, slot, managed, pr } ] } ], total }

  Every configured project whose repo_path exists is listed, including one
  with no worktrees (worktrees: []). repo is the owner/name string, or null
  when it cannot be resolved. pr_lookup is "skipped" under -q, "unavailable"
  when repo or gh cannot be resolved, else "done". slot is an int or null;
  managed is true once a slot is recorded. pr is null or
  { number, state, draft, url } (state is gh's own OPEN/MERGED/CLOSED).

Examples:
  wt ls
  wt ls -q
  wt ls -p nexus
  wt ls --json

Exit codes:
  0  success
  2  usage error: unknown option or missing argument
EOF
}
