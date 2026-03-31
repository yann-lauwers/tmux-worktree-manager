#!/bin/bash
# commands/smartdelete.sh - Smart delete with fzf multi-select
#
# Usage:
#   wt rm                    # fzf picker (multi-select)
#   wt rm -p nexus           # fzf picker, one project
#   wt rm <branch>           # direct delete (pass-through to core)

cmd_smartdelete() {
    # If first arg is not a flag, treat as direct branch delete
    if [[ $# -gt 0 && "$1" != -* ]]; then
        cmd_delete "$@"
        return
    fi

    local filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project) filter="$2"; shift 2 ;;
            -h|--help)
                echo -e "${BOLD}wt rm${NC} - Smart worktree delete"
                echo ""
                echo "Usage:"
                echo "  wt rm                    # fzf picker (multi-select)"
                echo "  wt rm -p nexus           # fzf picker, one project"
                echo "  wt rm <branch>           # direct delete (pass-through)"
                return 0
                ;;
            *) shift ;;
        esac
    done

    if ! command -v fzf &>/dev/null; then
        die "fzf is required for interactive delete. Install: brew install fzf"
    fi

    # Build worktree list with PR status
    local fzf_input=""

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

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local branch="${line%%|*}"
            local path="${line#*|}"

            # PR status label
            local pr_label=""
            if [[ -n "$repo_nwo" ]]; then
                local pr_json
                pr_json=$(gh pr list --repo "$repo_nwo" \
                    --head "$branch" --state all --json number,state,isDraft --jq '.[0] // empty' 2>/dev/null || true)
                if [[ -n "$pr_json" ]]; then
                    local number state draft
                    number=$(echo "$pr_json" | jq -r '.number')
                    state=$(echo "$pr_json" | jq -r '.state')
                    draft=$(echo "$pr_json" | jq -r '.isDraft')
                    if [[ "$state" == "MERGED" ]]; then
                        pr_label="#${number} merged"
                    elif [[ "$draft" == "true" ]]; then
                        pr_label="#${number} draft"
                    elif [[ "$state" == "OPEN" ]]; then
                        pr_label="#${number} open"
                    elif [[ "$state" == "CLOSED" ]]; then
                        pr_label="#${number} closed"
                    fi
                fi
            fi

            local display="${project}  ${branch}"
            [[ -n "$pr_label" ]] && display="${display}  ${pr_label}"
            fzf_input+="${display}|${project}|${branch}|${path}"$'\n'
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
    done

    if [[ -z "$fzf_input" ]]; then
        echo "No worktrees found."
        return 0
    fi

    local selected=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        selected+=("$line")
    done < <(
        echo -n "$fzf_input" | fzf --multi --ansi \
            --header "TAB select | CTRL-A all | ENTER confirm | ESC cancel" \
            --delimiter '|' --with-nth 1 \
            --preview-window hidden \
            --bind 'ctrl-a:toggle-all' \
            --height "~20" || true
    )

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "Nothing selected."
        return 0
    fi

    echo ""
    local deleted=0
    for entry in "${selected[@]}"; do
        local _display project branch path
        IFS='|' read -r _display project branch path <<< "$entry"
        echo -e "Deleting ${CYAN}${project}${NC} / ${branch}..."
        if ! cmd_delete "$branch" -p "$project" 2>/dev/null; then
            git worktree remove "$path" --force 2>/dev/null || true
            git branch -d "$branch" 2>/dev/null || true
        fi
        deleted=$((deleted + 1))
    done

    echo ""
    echo -e "${BOLD}Done.${NC} Deleted ${deleted} worktree(s)."
}
