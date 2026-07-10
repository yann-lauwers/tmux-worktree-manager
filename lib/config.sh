#!/bin/bash
# lib/config.sh - Configuration loading and YAML parsing

# Configuration directories
WT_CONFIG_DIR="${WT_CONFIG_DIR:-$HOME/.config/wt}"
WT_PROJECTS_DIR="$WT_CONFIG_DIR/projects"
WT_DATA_DIR="${WT_DATA_DIR:-$HOME/.local/share/wt}"
WT_STATE_DIR="$WT_DATA_DIR/state"
WT_LOG_DIR="$WT_DATA_DIR/logs"

# Ensure yq is installed, aborting otherwise.
# Side: dies if yq is not on PATH
ensure_yq() {
    if ! command_exists yq; then
        die "yq is required but not installed. Install with: brew install yq"
    fi
}

# Create the wt config, projects, data, state, and log directories.
# Side: mkdir -p on WT_{CONFIG,PROJECTS,DATA,STATE,LOG} dirs
init_config_dirs() {
    ensure_dir "$WT_CONFIG_DIR"
    ensure_dir "$WT_PROJECTS_DIR"
    ensure_dir "$WT_DATA_DIR"
    ensure_dir "$WT_STATE_DIR"
    ensure_dir "$WT_LOG_DIR"
}

# Print the global config file path.
# Out:  path to config.yaml
global_config_path() {
    echo "$WT_CONFIG_DIR/config.yaml"
}

# Print the config file path for a project.
# Args: $1 project
# Out:  path to <project>.yaml
project_config_path() {
    local project="$1"
    echo "$WT_PROJECTS_DIR/${project}.yaml"
}

# Test whether the global config file exists.
has_global_config() {
    [[ -f "$(global_config_path)" ]]
}

# Test whether a project's config file exists.
# Args: $1 project
has_project_config() {
    local project="$1"
    [[ -f "$(project_config_path "$project")" ]]
}

# Read a single YAML value with yq, falling back to a default.
# Usage: yaml_get "file.yaml" ".path.to.value"
# Args: $1 file, $2 yq path, $3 default (opt)
# Out:  value at path, or the default when missing/null/file absent
yaml_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"

    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(yq -e "$path" "$file" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Read a YAML array, one element per line.
# Usage: yaml_array "file.yaml" ".path.to.array"
# Args: $1 file, $2 yq path
# Out:  array elements, one per line (empty when file absent)
yaml_array() {
    local file="$1"
    local path="$2"

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r "$path // [] | .[]" "$file" 2>/dev/null
}

# Count the elements of a YAML array.
# Args: $1 file, $2 yq path
# Out:  element count (0 when file absent)
yaml_array_length() {
    local file="$1"
    local path="$2"

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    yq "$path | length" "$file" 2>/dev/null || echo "0"
}

# Write a string YAML value, creating the file if needed.
# Usage: yaml_set "file.yaml" ".path.to.value" "new_value"
# Args: $1 file, $2 yq path, $3 value
# Side: yq -i writes the file (creates it as {} first if absent)
yaml_set() {
    local file="$1"
    local path="$2"
    local value="$3"

    # Create file if it doesn't exist
    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi

    yq -i "$path = \"$value\"" "$file"
}

# Write a numeric YAML value, creating the file if needed.
# Args: $1 file, $2 yq path, $3 numeric value
# Side: yq -i writes the file (creates it as {} first if absent)
yaml_set_num() {
    local file="$1"
    local path="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi

    yq -i "$path = $value" "$file"
}

# Delete a YAML path from a file if the file exists.
# Args: $1 file, $2 yq path
# Side: yq -i removes the path from the file
yaml_delete() {
    local file="$1"
    local path="$2"

    if [[ -f "$file" ]]; then
        yq -i "del($path)" "$file"
    fi
}

# Return the given project name, or auto-detect it from the cwd.
# Usage: project=$(require_project "$project" ["custom error message"])
# Args: $1 project ("" = auto-detect), $2 custom error message (opt)
# Out:  resolved project name
# Side: dies if no project can be determined
require_project() {
    local project="$1"
    local error_msg="${2:-Could not detect project. Use --project option.}"

    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "$error_msg"
        fi
    fi

    echo "$project"
}

# Detect the project for the current directory by repo root or configured repo_path.
# Returns empty string if not in a project (does not return error code to avoid set -e issues)
# Out:  project name, or empty string when none matches
detect_project() {
    if ! is_git_repo 2>/dev/null; then
        echo ""
        return 0
    fi

    local repo_root
    repo_root=$(git_root 2>/dev/null) || { echo ""; return 0; }

    # If we're inside a worktree, get the main repo path
    if [[ "$repo_root" == *"/.worktrees/"* ]]; then
        repo_root="${repo_root%/.worktrees/*}"
    else
        # For external worktrees (e.g. conductor), resolve via git-common-dir
        local git_dir git_common_dir
        git_dir=$(git -C "$repo_root" rev-parse --git-dir 2>/dev/null)
        git_common_dir=$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)
        if [[ "$git_dir" != "$git_common_dir" ]]; then
            # Strip trailing /.git to get the main repo root
            repo_root="${git_common_dir%/.git}"
        fi
    fi

    local project_name
    project_name=$(basename "$repo_root")

    # Check if we have a config for this project
    if has_project_config "$project_name"; then
        echo "$project_name"
        return 0
    fi

    # Check all project configs for matching repo_path
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue

        local config_repo_path
        config_repo_path=$(yaml_get "$config_file" ".repo_path" "")
        config_repo_path=$(expand_path "$config_repo_path")

        if [[ "$config_repo_path" == "$repo_root" ]]; then
            basename "$config_file" .yaml
            return 0
        fi
    done

    echo ""
    return 0
}

# Load a project's config into PROJECT_* globals and validate its port ranges.
# Args: $1 project
# Side: sets PROJECT_{NAME,REPO_PATH,CONFIG_FILE,RESERVED_PORT_*,DYNAMIC_PORT_*,RESERVED_SLOTS,WORKTREE_DIR}; dies on missing config or invalid port range
load_project_config() {
    local project="$1"

    if ! has_project_config "$project"; then
        die "No configuration found for project: $project"
    fi

    local config_file
    config_file=$(project_config_path "$project")

    PROJECT_NAME=$(yaml_get "$config_file" ".name" "$project")
    PROJECT_REPO_PATH=$(yaml_get "$config_file" ".repo_path")
    PROJECT_REPO_PATH=$(expand_path "$PROJECT_REPO_PATH")
    PROJECT_CONFIG_FILE="$config_file"

    # Port configuration
    PROJECT_RESERVED_PORT_MIN=$(yaml_get "$config_file" ".ports.reserved.range.min" "3000")
    PROJECT_RESERVED_PORT_MAX=$(yaml_get "$config_file" ".ports.reserved.range.max" "3005")
    PROJECT_RESERVED_SLOTS=$(yaml_get "$config_file" ".ports.reserved.slots" "3")
    PROJECT_DYNAMIC_PORT_MIN=$(yaml_get "$config_file" ".ports.dynamic.range.min" "4000")
    PROJECT_DYNAMIC_PORT_MAX=$(yaml_get "$config_file" ".ports.dynamic.range.max" "5000")

    # Validate port ranges
    if ! [[ "$PROJECT_RESERVED_PORT_MIN" =~ ^[0-9]+$ ]] || ! [[ "$PROJECT_RESERVED_PORT_MAX" =~ ^[0-9]+$ ]]; then
        die "Invalid reserved port range: values must be numbers"
    fi
    if ! [[ "$PROJECT_DYNAMIC_PORT_MIN" =~ ^[0-9]+$ ]] || ! [[ "$PROJECT_DYNAMIC_PORT_MAX" =~ ^[0-9]+$ ]]; then
        die "Invalid dynamic port range: values must be numbers"
    fi
    if (( PROJECT_RESERVED_PORT_MIN >= PROJECT_RESERVED_PORT_MAX )); then
        die "Invalid reserved port range: min ($PROJECT_RESERVED_PORT_MIN) must be less than max ($PROJECT_RESERVED_PORT_MAX)"
    fi
    if (( PROJECT_DYNAMIC_PORT_MIN >= PROJECT_DYNAMIC_PORT_MAX )); then
        die "Invalid dynamic port range: min ($PROJECT_DYNAMIC_PORT_MIN) must be less than max ($PROJECT_DYNAMIC_PORT_MAX)"
    fi
    if (( PROJECT_RESERVED_PORT_MIN < 1 || PROJECT_RESERVED_PORT_MAX > 65535 )); then
        die "Reserved port range out of bounds (must be 1-65535)"
    fi
    if (( PROJECT_DYNAMIC_PORT_MIN < 1 || PROJECT_DYNAMIC_PORT_MAX > 65535 )); then
        die "Dynamic port range out of bounds (must be 1-65535)"
    fi

    # External worktree directory (optional — falls back to $repo/.worktrees)
    PROJECT_WORKTREE_DIR=$(yaml_get "$config_file" ".worktree_dir" "")
    if [[ -n "$PROJECT_WORKTREE_DIR" ]]; then
        PROJECT_WORKTREE_DIR=$(expand_path "$PROJECT_WORKTREE_DIR")
    else
        PROJECT_WORKTREE_DIR=""
    fi

    log_debug "Loaded config for project: $PROJECT_NAME"
    log_debug "  Repo path: $PROJECT_REPO_PATH"
    if [[ -n "$PROJECT_WORKTREE_DIR" ]]; then
        log_debug "  Worktree dir: $PROJECT_WORKTREE_DIR"
    fi
    log_debug "  Reserved ports: $PROJECT_RESERVED_PORT_MIN-$PROJECT_RESERVED_PORT_MAX"
    log_debug "  Dynamic ports: $PROJECT_DYNAMIC_PORT_MIN-$PROJECT_DYNAMIC_PORT_MAX"
}

# Count the configured setup steps.
# Args: $1 config_file
# Out:  number of entries under .setup
get_setup_steps() {
    local config_file="$1"
    yaml_array_length "$config_file" ".setup"
}

# Read one field of a setup step by index.
# Args: $1 config_file, $2 index, $3 field
# Out:  field value at .setup[index].field
get_setup_step() {
    local config_file="$1"
    local index="$2"
    local field="$3"

    yaml_get "$config_file" ".setup[$index].$field"
}

# Count the configured services.
# Args: $1 config_file
# Out:  number of entries under .services
get_services() {
    local config_file="$1"
    yaml_array_length "$config_file" ".services"
}

# Read one field of a service selected by name.
# Args: $1 config_file, $2 service_name, $3 field
# Out:  the field value of the matching service
get_service_config() {
    local config_file="$1"
    local service_name="$2"
    local field="$3"

    yq ".services[] | select(.name == \"$service_name\") | .$field" "$config_file" 2>/dev/null
}

# Read one field of a service by index.
# Args: $1 config_file, $2 index, $3 field
# Out:  field value at .services[index].field
get_service_by_index() {
    local config_file="$1"
    local index="$2"
    local field="$3"

    yaml_get "$config_file" ".services[$index].$field"
}

# Read the config's env map as KEY=VALUE lines.
# Args: $1 config_file
# Out:  KEY=VALUE lines (empty when file absent)
get_env_vars() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        return
    fi

    yq -r '.env // {} | to_entries | .[] | "\(.key)=\(.value)"' "$config_file" 2>/dev/null
}

# Export KEY=VALUE lines with variable expansion via envsubst
# Usage: export_env_string "$key_value_lines"
# Args: $1 newline-separated KEY=VALUE lines
# Side: exports each KEY into the environment
export_env_string() {
    local key value
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        value=$(echo "$value" | envsubst 2>/dev/null || echo "$value")
        export "$key=$value"
    done <<< "$1"
}

# Export the config's env map into the environment.
# Args: $1 config_file
# Side: exports each configured env var
export_env_vars() {
    local config_file="$1"
    export_env_string "$(get_env_vars "$config_file")"
}

# Run a named hook command from config if one is defined.
# Export environment variables before calling this function
# Usage: run_hook <config_file> <hook_name>
# Args: $1 config_file, $2 hook_name
# Side: eval's the hook command; warns on non-zero exit
run_hook() {
    local config_file="$1"
    local hook_name="$2"

    local hook_cmd
    hook_cmd=$(yaml_get "$config_file" ".hooks.$hook_name" "")

    if [[ -n "$hook_cmd" ]] && [[ "$hook_cmd" != "null" ]]; then
        if ! eval "$hook_cmd"; then
            log_warn "$hook_name hook exited with errors"
        fi
    fi
}

# Resolve the worktree's DB URL from its env file, else the config template.
# Requires PORT_* vars to be in scope (via export_port_vars or manual export)
# Usage: resolve_db_url <config_file> [worktree_path]
# Args: $1 config_file, $2 worktree_path (opt)
# Out:  resolved DB URL (returns non-zero when no template configured)
resolve_db_url() {
    local config_file="$1"
    local worktree_path="${2:-}"

    # The worktree's own env file is the source of truth for the DB the app connects to:
    # it reflects an own ephemeral instance (--db), a borrowed parent instance (--stack-on),
    # or a remote shared DB (--no-db) alike. The slot-derived template below cannot tell
    # these apart, so prefer the env file whenever the worktree exists and one is configured.
    local src_file src_var
    src_file=$(yaml_get "$config_file" ".db.url_source.file" "")
    src_var=$(yaml_get "$config_file" ".db.url_source.var" "")
    if [[ -n "$worktree_path" && -n "$src_file" && -n "$src_var" && -f "$worktree_path/$src_file" ]]; then
        local val
        val=$(grep -E "^${src_var}=" "$worktree_path/$src_file" | head -1 | cut -d= -f2-)
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # Pre-create preview (no worktree yet) or no url_source configured: derive from the template.
    local template
    template=$(yaml_get "$config_file" ".db.url_template" "")
    [[ -z "$template" ]] && return 1
    eval echo "$template" 2>/dev/null
}

# Mask the password in a postgres URL for display: user:pass@host -> user:****@host.
# URLs with no password (postgresql://user@host) are returned unchanged.
# Args: $1 db_url
# Out:  the URL with its password masked
redact_db_url() {
    echo "$1" | sed -E 's|(://[^:/@]+):[^@]*@|\1:****@|'
}

# Parse a postgres URL into its components for display.
# Args: $1 db_url (postgresql://user[:pass]@host:port/dbname[?params])
# Out:  tab-separated "user\thost\tport\tname"
parse_db_url() {
    local url="$1"
    local db_user db_host db_port db_name
    db_user=$(echo "$url" | sed -n 's|.*://\([^@]*\)@.*|\1|p')
    db_user="${db_user%%:*}"
    db_host=$(echo "$url" | sed -n 's|.*@\([^:]*\):.*|\1|p')
    db_port=$(echo "$url" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
    db_name=$(echo "$url" | sed -n 's|.*/\([^?]*\).*|\1|p')
    printf '%s\t%s\t%s\t%s\n' "$db_user" "$db_host" "$db_port" "$db_name"
}

# List all configured project names.
# Out:  project names, one per line
list_projects() {
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        basename "$config_file" .yaml
    done
}
