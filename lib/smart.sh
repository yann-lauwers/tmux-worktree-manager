#!/bin/bash
# smart.sh - Shared helpers for smart commands (new, open, ls, rm, prune, code, pr)
#
# Depends on: lib/utils.sh (colors, logging, die)

WT_PROJECTS_DIR="$HOME/.config/wt/projects"

# ─── Project detection ───────────────────────────────────────────────────────

# Get repo_path from a project config
smart_get_repo_root() {
    local project="$1"
    local config="$WT_PROJECTS_DIR/${project}.yaml"
    yq -r '.repo_path // ""' "$config" | sed "s|^~|$HOME|"
}

# Read a field from project config with optional default
smart_read_config() {
    local project="$1"
    local field="$2"
    local default="${3:-}"
    local config="$WT_PROJECTS_DIR/${project}.yaml"
    local val
    val=$(yq -r "$field // \"\"" "$config" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Detect project from cwd (works inside worktrees too)
smart_detect_project() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    if [[ "$repo_root" == *"/.worktrees/"* ]]; then
        repo_root="${repo_root%/.worktrees/*}"
    fi

    local name
    name=$(basename "$repo_root")

    # Check by name
    if [[ -f "$WT_PROJECTS_DIR/${name}.yaml" ]]; then
        echo "$name"
        return
    fi

    # Check all configs for matching repo_path
    for f in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        local config_path
        config_path=$(yq -r '.repo_path // ""' "$f" | sed "s|^~|$HOME|")
        if [[ "$config_path" == "$repo_root" ]]; then
            basename "$f" .yaml
            return
        fi
    done

    return 1
}

# List all configured project names
smart_list_projects() {
    for f in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        basename "$f" .yaml
    done
}

# ─── Worktree gathering ─────────────────────────────────────────────────────

# Output lines: project|branch|path — skips main worktree
smart_gather_worktrees() {
    local filter_project="${1:-}"
    local projects=()

    if [[ -n "$filter_project" ]]; then
        projects=("$filter_project")
    else
        while IFS= read -r p; do
            projects+=("$p")
        done < <(smart_list_projects)
    fi

    for project in "${projects[@]}"; do
        local repo_root
        repo_root=$(smart_get_repo_root "$project")
        [[ -d "$repo_root" ]] || continue

        git -C "$repo_root" worktree list --porcelain 2>/dev/null | {
            local wt_path=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^worktree\ (.+) ]]; then
                    wt_path="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
                    local branch="${BASH_REMATCH[1]}"
                    [[ "$wt_path" == "$repo_root" ]] && continue
                    echo "${project}|${branch}|${wt_path}"
                fi
            done
        }
    done
}

# Find worktree by fuzzy match. Returns path or empty.
smart_find_worktree() {
    local query="$1"
    local project="${2:-}"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    smart_gather_worktrees "$project" | while IFS='|' read -r proj branch path; do
        local branch_lower
        branch_lower=$(echo "$branch" | tr '[:upper:]' '[:lower:]')
        local dir_lower
        dir_lower=$(basename "$path" | tr '[:upper:]' '[:lower:]')

        if [[ "$branch_lower" == "$query_lower" || "$dir_lower" == "$query_lower" ]]; then
            echo "$path"
            return
        fi
        if [[ "$branch_lower" == *"$query_lower"* || "$dir_lower" == *"$query_lower"* ]]; then
            echo "$path"
            return
        fi
    done
}

# Interactive fzf picker. Returns path or dies.
smart_pick_worktree() {
    local project="${1:-}"
    local entries
    entries=$(smart_gather_worktrees "$project")

    if [[ -z "$entries" ]]; then
        die "No worktrees found. Create one with: wt new <branch>"
    fi

    local count
    count=$(echo "$entries" | wc -l | tr -d ' ')

    # Single worktree -> return directly
    if [[ "$count" -eq 1 ]]; then
        echo "$entries" | cut -d'|' -f3
        return
    fi

    # Build display lines
    local display_lines=""
    while IFS='|' read -r proj branch path; do
        display_lines+="$(printf "%-12s  %-40s  %s" "$proj" "$branch" "$path")"$'\n'
    done <<< "$entries"
    display_lines="${display_lines%$'\n'}"

    # fzf available + interactive terminal
    if command -v fzf &>/dev/null && [[ -t 0 ]]; then
        local header="PROJECT       BRANCH                                    PATH"
        local selected
        selected=$(echo "$display_lines" | fzf \
            --header="$header" \
            --height=~20 \
            --reverse \
            --prompt="worktree > " \
            --ansi \
        ) || die "Cancelled"
        echo "$selected" | awk '{print $NF}'
        return
    fi

    # No fzf or non-interactive
    if [[ ! -t 0 ]]; then
        echo -e "${BOLD}Worktrees:${NC}" >&2
        echo "$display_lines" >&2
        die "Multiple worktrees — pass a name: wt open <branch>"
    fi

    echo -e "${BOLD}Worktrees:${NC}"
    echo ""
    local i=1
    while IFS='|' read -r proj branch path; do
        echo -e "  ${CYAN}${i}${NC}  ${BOLD}${proj}${NC} -> $branch"
        echo -e "     ${DIM}${path}${NC}"
        ((i++))
    done <<< "$entries"
    echo ""

    read -r -p "Pick (number): " choice
    local selected_path
    selected_path=$(echo "$entries" | sed -n "${choice}p" | cut -d'|' -f3)

    [[ -n "$selected_path" ]] || die "Invalid choice"
    echo "$selected_path"
}

# ─── GitHub / PR helpers ─────────────────────────────────────────────────────

# Get owner/repo string from a repo root directory
smart_get_repo_nwo() {
    local repo_root="$1"
    git -C "$repo_root" remote get-url origin 2>/dev/null \
        | sed -E 's|.*github\.com[:/]||; s|\.git$||' || true
}

# PR status badge (colored). Pass branch + owner/repo. Set smart_quick=true to skip.
smart_pr_badge() {
    local branch="$1"
    local repo_nwo="$2"

    if [[ "${smart_quick:-false}" == "true" ]]; then
        echo ""
        return
    fi

    local pr_json
    pr_json=$(gh pr list --repo "$repo_nwo" \
        --head "$branch" --state all --json number,state,isDraft --jq '.[0] // empty' 2>/dev/null || true)

    if [[ -z "$pr_json" ]]; then
        echo ""
        return
    fi

    local number state draft
    number=$(echo "$pr_json" | jq -r '.number')
    state=$(echo "$pr_json" | jq -r '.state')
    draft=$(echo "$pr_json" | jq -r '.isDraft')

    local url="https://github.com/${repo_nwo}/pull/${number}"
    local link_start link_end
    link_start=$(printf '\e]8;;%s\e\\' "$url")
    link_end=$(printf '\e]8;;\e\\')

    if [[ "$state" == "MERGED" ]]; then
        printf '%b%s#%s%s merged%b' "$MAGENTA" "$link_start" "$number" "$link_end" "$NC"
    elif [[ "$draft" == "true" ]]; then
        printf '%b%s#%s%s draft%b' "$DIM" "$link_start" "$number" "$link_end" "$NC"
    elif [[ "$state" == "OPEN" ]]; then
        printf '%b%s#%s%s open%b' "$GREEN" "$link_start" "$number" "$link_end" "$NC"
    elif [[ "$state" == "CLOSED" ]]; then
        printf '%b%s#%s%s closed%b' "$RED" "$link_start" "$number" "$link_end" "$NC"
    else
        printf '%b%s#%s%s%b' "$DIM" "$link_start" "$number" "$link_end" "$NC"
    fi
}

# ─── Linear helpers ──────────────────────────────────────────────────────────

# Slugify a string for branch names
smart_slugify() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//' \
        | cut -c1-50
}

# Is this a Linear-style issue ID? (e.g., NEX-1500, PROJ-123)
smart_is_linear_id() {
    [[ "$1" =~ ^[A-Za-z]+-[0-9]+$ ]]
}

# Find Linear API key from multiple sources
# Priority: WT_LINEAR_API_KEY env > ~/.config/wt/config.yaml > me/config.json > ~/.claude/me/config.json
smart_find_linear_key() {
    # 1. Environment variable
    if [[ -n "${WT_LINEAR_API_KEY:-}" ]]; then
        echo "$WT_LINEAR_API_KEY"
        return
    fi

    # 2. Global wt config
    local global_config="$HOME/.config/wt/config.yaml"
    if [[ -f "$global_config" ]]; then
        local key
        key=$(yq -r '.linear.api_key // empty' "$global_config" 2>/dev/null || true)
        if [[ -n "$key" ]]; then
            echo "$key"
            return
        fi
    fi

    # 3. Project-level me/config.json (Claude Code convention)
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ "$repo_root" == *"/.worktrees/"* ]]; then
        repo_root="${repo_root%/.worktrees/*}"
    fi

    if [[ -n "$repo_root" && -f "$repo_root/me/config.json" ]]; then
        local key
        key=$(jq -r '.apiKeys.linear // empty' "$repo_root/me/config.json" 2>/dev/null || true)
        if [[ -n "$key" ]]; then
            echo "$key"
            return
        fi
    fi

    # 4. Global me/config.json
    if [[ -f "$HOME/.claude/me/config.json" ]]; then
        local key
        key=$(jq -r '.apiKeys.linear // empty' "$HOME/.claude/me/config.json" 2>/dev/null || true)
        if [[ -n "$key" ]]; then
            echo "$key"
            return
        fi
    fi
}

# Fetch issue title from Linear GraphQL API
smart_fetch_linear_issue() {
    local issue_id="$1"
    local api_key="$2"

    local response
    response=$(curl -s https://api.linear.app/graphql \
        -H "Authorization: $api_key" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"{ issue(id: \\\"$issue_id\\\") { identifier title } }\"}" 2>/dev/null)

    local title
    title=$(echo "$response" | jq -r '.data.issue.title // empty' 2>/dev/null)

    if [[ -z "$title" ]]; then
        die "Could not fetch Linear issue: $issue_id"
    fi

    echo "$title"
}

# ─── Editor / opener helpers ────────────────────────────────────────────────

# Resolve the opener command for wt open (cmux, tmux attach, or just cd)
smart_resolve_opener() {
    # 1. Config override
    local global_config="$HOME/.config/wt/config.yaml"
    if [[ -f "$global_config" ]]; then
        local opener
        opener=$(yq -r '.opener // empty' "$global_config" 2>/dev/null || true)
        if [[ -n "$opener" ]] && command -v "$opener" &>/dev/null; then
            echo "$opener"
            return
        fi
    fi

    # 2. Auto-detect
    if command -v cmux &>/dev/null; then
        echo "cmux"
    elif command -v tmux &>/dev/null; then
        echo "tmux"
    else
        echo "cd"
    fi
}

# Resolve editor command (for wt code)
smart_resolve_editor() {
    local global_config="$HOME/.config/wt/config.yaml"

    # 1. Config override
    local editor_cmd=""
    if [[ -f "$global_config" ]]; then
        editor_cmd=$(yq -r '.editor // ""' "$global_config" 2>/dev/null || true)
    fi

    # 2. Env vars
    if [[ -z "$editor_cmd" ]]; then
        editor_cmd="${VISUAL:-${EDITOR:-open}}"
    fi

    # 3. Resolve command
    if ! command -v "$editor_cmd" &>/dev/null; then
        # macOS /Applications fallback
        local app_name
        app_name="$(tr '[:lower:]' '[:upper:]' <<< "${editor_cmd:0:1}")${editor_cmd:1}"
        local mac_bin="/Applications/${app_name}.app/Contents/Resources/app/bin/${editor_cmd}"
        if [[ -x "$mac_bin" ]]; then
            echo "$mac_bin"
            return
        fi
        die "Editor '${editor_cmd}' not found. Set 'editor' in ~/.config/wt/config.yaml"
    fi

    echo "$editor_cmd"
}

# Resolve worktree path from branch name (state files → git worktree list)
smart_resolve_worktree_path() {
    local branch="$1"

    # Try state files
    for state_file in "$HOME/.local/share/wt/state"/*.state.yaml; do
        [[ -f "$state_file" ]] || continue
        local sanitized
        sanitized=$(echo "$branch" | sed 's|/|-|g; s|[^a-zA-Z0-9_-]||g')
        local found
        found=$(yq -r ".worktrees.\"$sanitized\".path // empty" "$state_file" 2>/dev/null || true)
        if [[ -n "$found" ]] && [[ -d "$found" ]]; then
            echo "$found"
            return
        fi
    done

    # Fallback: git worktree list
    git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
        /^worktree / { path = substr($0, 10) }
        /^branch / && substr($0, 8) == b { print path; exit }
    '
}
