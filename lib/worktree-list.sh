#!/bin/bash
# lib/worktree-list.sh - Shared annotated worktree enumeration for `wt rm`.
#
# Single source of truth for "list every worktree, enriched with its PR state and
# dirty count". Both the `wt rm` picker and its `--merged` mode consume this, so the
# query/annotate logic lives in one place instead of drifting across two commands.
#
# Emits one TSV row per worktree (each repo's main checkout excluded):
#   project \t branch \t path \t pr_label \t dirty_count
#
# pr_label is "" or "#<n> merged|closed|open|draft". Rows whose PR is merged/closed
# are emitted first so the picker surfaces the safe-to-delete ones at the top.

build_worktree_rows() {
    local filter="${1:-}"
    local merged_only="${2:-0}"

    local merged_rows="" other_rows=""

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

        # One batched query per repo (newest-first), looked up locally per branch —
        # one network call per repo instead of one per worktree. TSV: branch \t number \t state \t isDraft.
        local pr_map=""
        if [[ -n "$repo_nwo" ]]; then
            pr_map=$(gh pr list --repo "$repo_nwo" --state all --limit 500 \
                --json number,state,isDraft,headRefName \
                --jq '.[] | [.headRefName, (.number|tostring), .state, (.isDraft|tostring)] | @tsv' 2>/dev/null || true)
        fi

        while IFS=$'\t' read -r branch path; do
            [[ -z "$branch" ]] && continue

            # PR label — first match = newest PR (gh returns newest-first).
            local pr_label="" pr_state=""
            if [[ -n "$pr_map" ]]; then
                local pr_line
                pr_line=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$branch" '$1==b {print; exit}')
                if [[ -n "$pr_line" ]]; then
                    local number state draft
                    number=$(printf '%s' "$pr_line" | cut -f2)
                    state=$(printf '%s' "$pr_line" | cut -f3)
                    draft=$(printf '%s' "$pr_line" | cut -f4)
                    pr_state="$state"
                    if [[ "$state" == "MERGED" ]]; then pr_label="#${number} merged"
                    elif [[ "$state" == "CLOSED" ]]; then pr_label="#${number} closed"
                    elif [[ "$draft" == "true" ]]; then pr_label="#${number} draft"
                    elif [[ "$state" == "OPEN" ]]; then pr_label="#${number} open"
                    fi
                fi
            fi

            local is_merged=0
            [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]] && is_merged=1
            [[ "$merged_only" == "1" && "$is_merged" == "0" ]] && continue

            local dirty
            dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            [[ -z "$dirty" ]] && dirty=0

            local row
            printf -v row '%s\t%s\t%s\t%s\t%s' "$project" "$branch" "$path" "$pr_label" "$dirty"
            if [[ "$is_merged" == "1" ]]; then
                merged_rows+="${row}"$'\n'
            else
                other_rows+="${row}"$'\n'
            fi
        done < <(
            git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk -v root="$repo_root" '
                /^worktree / { p = substr($0, 10) }
                $1 == "branch" { sub("refs/heads/", "", $2); if (p != root) printf "%s\t%s\n", $2, p }
            '
        )
    done

    printf '%s%s' "$merged_rows" "$other_rows"
}
