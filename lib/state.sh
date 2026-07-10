#!/bin/bash
# lib/state.sh - State file management for worktrees and services

# Build the state-file path for a project.
# Args: $1 project
# Out:  absolute path to the project's state YAML (may not exist yet)
state_file() {
    local project="$1"
    echo "$WT_STATE_DIR/${project}.state.yaml"
}

# Create the project's state file with an empty worktrees map if it is absent.
# Args: $1 project
# Side: writes a new state YAML when none exists (no-op otherwise)
init_state_file() {
    local project="$1"
    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        cat > "$file" << EOF
# Runtime state for project: $project
worktrees: {}
EOF
    fi
}

# Read one field from a worktree's state entry.
# Args: $1 project, $2 branch, $3 field
# Out:  the field value ("" if the state file or field is absent)
get_worktree_state() {
    local project="$1"
    local branch="$2"
    local field="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".worktrees.\"$sanitized\".$field" ""
}

# Set one field on a worktree's state entry.
# Args: $1 project, $2 branch, $3 field, $4 value
# Side: delegates the locked write to _set_worktree_state_locked under with_file_lock
set_worktree_state() {
    local project="$1"
    local branch="$2"
    local field="$3"
    local value="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_worktree_state_locked "$sanitized" "$field" "$value" "$file"
}

# Write a single worktree field to the state file (numeric bare, else strenv-quoted).
# Args: $1 sanitized branch key, $2 field, $3 value, $4 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_set_worktree_state_locked() {
    local sanitized="$1"
    local field="$2"
    local value="$3"
    local file="$4"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".$field = $value" "$file"
    else
        VALUE="$value" yq -i ".worktrees.\"$sanitized\".$field = strenv(VALUE)" "$file"
    fi
}

# Remove a worktree's entire state entry.
# Args: $1 project, $2 branch
# Side: delegates the locked delete to _delete_worktree_state_locked under with_file_lock
delete_worktree_state() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _delete_worktree_state_locked "$sanitized" "$file" "$branch"
}

# Delete the worktree entry from the state file and log it.
# Args: $1 sanitized branch key, $2 file, $3 branch (for the log line)
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_delete_worktree_state_locked() {
    local sanitized="$1"
    local file="$2"
    local branch="$3"

    yq -i "del(.worktrees.\"$sanitized\")" "$file"
    log_debug "Deleted state for worktree: $branch"
}

# Resolve the state entry key whose stored .path matches a worktree path (stable across renames,
# so it relinks a worktree to its entry when the branch-derived key has drifted).
# Args: $1 project, $2 path
# Out:  the matching worktree state key, or empty if none matches
state_key_for_path() {
    local project="$1"
    local path="$2"

    local file
    file=$(state_file "$project")
    [[ -f "$file" ]] || return 0

    PATH_MATCH="$path" yq -r \
        '.worktrees | to_entries[] | select(.value.path == strenv(PATH_MATCH)) | .key' \
        "$file" 2>/dev/null | head -1
}

# Create a fresh worktree state entry (branch, path, slot, created_at, empty services).
# Args: $1 project, $2 branch, $3 path, $4 slot
# Side: delegates the locked create to _create_worktree_state_locked under with_file_lock
create_worktree_state() {
    local project="$1"
    local branch="$2"
    local path="$3"
    local slot="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local ts
    ts=$(timestamp)

    with_file_lock "$file" _create_worktree_state_locked "$sanitized" "$branch" "$path" "$slot" "$ts" "$file"
}

# Write the new worktree entry's fields to the state file and log it.
# Args: $1 sanitized branch key, $2 branch, $3 path, $4 slot, $5 ts, $6 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_create_worktree_state_locked() {
    local sanitized="$1"
    local branch="$2"
    local path="$3"
    local slot="$4"
    local ts="$5"
    local file="$6"

    BRANCH="$branch" PATH_VAL="$path" TS="$ts" yq -i "
        .worktrees.\"$sanitized\".branch = strenv(BRANCH) |
        .worktrees.\"$sanitized\".path = strenv(PATH_VAL) |
        .worktrees.\"$sanitized\".slot = $slot |
        .worktrees.\"$sanitized\".created_at = strenv(TS) |
        .worktrees.\"$sanitized\".services = {}
    " "$file"

    log_debug "Created state for worktree: $branch"
}

# Read one field from a service's state entry within a worktree.
# Args: $1 project, $2 branch, $3 service, $4 field
# Out:  the field value ("" if the state file or field is absent)
get_service_state() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local field="$4"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".worktrees.\"$sanitized\".services.\"$service\".$field" ""
}

# Set one field on a service's state entry within a worktree.
# Args: $1 project, $2 branch, $3 service, $4 field, $5 value
# Side: delegates the locked write to _set_service_state_locked under with_file_lock
set_service_state() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local field="$4"
    local value="$5"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_service_state_locked "$sanitized" "$service" "$field" "$value" "$file"
}

# Write a single service field to the state file (numeric bare, else strenv-quoted).
# Args: $1 sanitized branch key, $2 service, $3 field, $4 value, $5 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_set_service_state_locked() {
    local sanitized="$1"
    local service="$2"
    local field="$3"
    local value="$4"
    local file="$5"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = $value" "$file"
    else
        VALUE="$value" yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = strenv(VALUE)" "$file"
    fi
}

# Update a service's status and optionally its pid/port in one batched write.
# Args: $1 project, $2 branch, $3 service, $4 status, $5 pid (optional), $6 port (optional)
# Side: delegates the locked batched write to _update_service_status_locked under with_file_lock
update_service_status() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local status="$4"
    local pid="${5:-}"
    local port="${6:-}"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local ts
    ts=$(timestamp)

    with_file_lock "$file" _update_service_status_locked "$sanitized" "$service" "$status" "$pid" "$port" "$ts" "$file"
}

# Write the service's status (plus pid, port, and started_at when applicable) in one yq expression.
# Args: $1 sanitized branch key, $2 service, $3 status, $4 pid, $5 port, $6 ts, $7 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_update_service_status_locked() {
    local sanitized="$1"
    local service="$2"
    local status="$3"
    local pid="$4"
    local port="$5"
    local ts="$6"
    local file="$7"

    # Build a single yq expression to batch all updates
    local base=".worktrees.\"$sanitized\".services.\"$service\""
    local expr="${base}.status = strenv(STATUS)"

    if [[ -n "$pid" ]]; then
        expr="$expr | ${base}.pid = $pid"
    else
        expr="$expr | ${base}.pid = null"
    fi

    if [[ -n "$port" ]]; then
        expr="$expr | ${base}.port = $port"
    fi

    if [[ "$status" == "running" ]]; then
        expr="$expr | ${base}.started_at = strenv(TS)"
    fi

    STATUS="$status" TS="$ts" yq -i "$expr" "$file"
}

# List every worktree entry key stored for a project.
# Args: $1 project
# Out:  one sanitized worktree key per line ("" if the state file is absent)
list_worktree_states() {
    local project="$1"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r '.worktrees | keys | .[]' "$file" 2>/dev/null
}

# List every service state for a worktree as colon-delimited records.
# Args: $1 project, $2 branch
# Out:  one "name:status:port:pid" line per service (unknown/empty fields defaulted)
list_service_states() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -r ".worktrees.\"$sanitized\".services | to_entries | .[] | \"\(.key):\(.value.status // \"unknown\"):\(.value.port // \"\"):\(.value.pid // \"\")\"" "$file" 2>/dev/null
}

# Report whether a service's recorded PID is still alive (via kill -0).
# Args: $1 project, $2 branch, $3 service
is_service_running() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local pid
    pid=$(get_service_state "$project" "$branch" "$service" "pid")

    if [[ -z "$pid" ]] || [[ "$pid" == "null" ]]; then
        return 1
    fi

    kill -0 "$pid" 2>/dev/null
}

# Mark any service whose recorded PID is dead as stopped in the state file.
# Args: $1 project, $2 branch
# Side: writes "stopped" status via update_service_status (locked) for each dead service
cleanup_stale_services() {
    local project="$1"
    local branch="$2"
    local svc_name svc_status svc_port svc_pid  # Declare local to avoid clobbering caller's vars

    while IFS=: read -r svc_name svc_status svc_port svc_pid; do
        [[ -z "$svc_name" ]] && continue

        if [[ -n "$svc_pid" ]] && [[ "$svc_pid" != "null" ]]; then
            if ! kill -0 "$svc_pid" 2>/dev/null; then
                log_debug "Cleaning up stale service: $svc_name (PID $svc_pid)"
                update_service_status "$project" "$branch" "$svc_name" "stopped"
            fi
        fi
    done < <(list_service_states "$project" "$branch")
}

# Remove worktree entries whose recorded path no longer exists on disk.
# Args: $1 project
# Side: releases the slot and deletes the entry (yq under lock) for each vanished worktree
cleanup_stale_worktrees() {
    local project="$1"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized_branch wt_path
    while read -r sanitized_branch; do
        [[ -z "$sanitized_branch" ]] && continue

        wt_path=$(yaml_get "$file" ".worktrees.\"$sanitized_branch\".path" "")
        if [[ -n "$wt_path" ]] && [[ ! -d "$wt_path" ]]; then
            local branch
            branch=$(yaml_get "$file" ".worktrees.\"$sanitized_branch\".branch" "$sanitized_branch")
            log_warn "Cleaning up stale worktree state: $branch (path $wt_path no longer exists)"
            release_slot "$project" "$branch" 2>/dev/null || true
            with_file_lock "$file" yq -i "del(.worktrees.\"$sanitized_branch\")" "$file"
        fi
    done < <(list_worktree_states "$project")
}

# Derive the tmux window name for a worktree (short dirname for Linear, sanitized for others).
# Args: $1 project, $2 branch
# Out:  the worktree's window name
get_session_name() {
    local project="$1"
    local branch="$2"

    worktree_dirname "$branch"
}

# Record a worktree's tmux session name in state.
# Args: $1 project, $2 branch, $3 session
# Side: delegates the locked write via set_worktree_state
set_session_state() {
    local project="$1"
    local branch="$2"
    local session="$3"

    set_worktree_state "$project" "$branch" "session" "$session"
}

# Resolve a worktree's filesystem path from state (or the root override).
# Main-repo-root context (cmd_start/cmd_stop) sets WT_ROOT_WORKTREE_PATH to the
# repo root, which has no state entry — honor it before the state lookup.
# Args: $1 project, $2 branch
# Out:  the worktree path ("" if absent)
get_worktree_path() {
    local project="$1"
    local branch="$2"

    [[ -n "${WT_ROOT_WORKTREE_PATH:-}" ]] && { echo "$WT_ROOT_WORKTREE_PATH"; return 0; }
    get_worktree_state "$project" "$branch" "path"
}

# Resolve a worktree's slot number from state (or the root override).
# Main-repo-root context sets WT_ROOT_SLOT (0) — the root holds no slot in state.
# Args: $1 project, $2 branch
# Out:  the slot number ("" if absent)
get_worktree_slot() {
    local project="$1"
    local branch="$2"

    [[ -n "${WT_ROOT_SLOT:-}" ]] && { echo "$WT_ROOT_SLOT"; return 0; }
    get_worktree_state "$project" "$branch" "slot"
}

# Set a port override for a service in a worktree.
# Args: $1 project, $2 branch, $3 service, $4 port
# Side: delegates the locked write to _set_port_override_locked under with_file_lock
set_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local port="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_port_override_locked "$sanitized" "$service" "$port" "$file"
}

# Write a service's port override to the state file.
# Args: $1 sanitized branch key, $2 service, $3 port, $4 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_set_port_override_locked() {
    local sanitized="$1"
    local service="$2"
    local port="$3"
    local file="$4"

    yq -i ".worktrees.\"$sanitized\".port_overrides.\"$service\" = $port" "$file"
    log_debug "Set port override for $service: $port"
}

# Read a service's port override for a worktree.
# Args: $1 project, $2 branch, $3 service
# Out:  the override port ("" if unset or null)
get_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local override
    override=$(yaml_get "$file" ".worktrees.\"$sanitized\".port_overrides.\"$service\"" "")

    # Return empty if null or not set
    if [[ "$override" == "null" ]] || [[ -z "$override" ]]; then
        echo ""
    else
        echo "$override"
    fi
}

# Clear a service's port override in a worktree.
# Args: $1 project, $2 branch, $3 service
# Side: delegates the locked delete to _clear_port_override_locked under with_file_lock
clear_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _clear_port_override_locked "$sanitized" "$service" "$file"
}

# Delete a service's port override from the state file.
# Args: $1 sanitized branch key, $2 service, $3 file
# Side: mutates the state YAML in place via yq (runs under with_file_lock)
_clear_port_override_locked() {
    local sanitized="$1"
    local service="$2"
    local file="$3"

    yq -i "del(.worktrees.\"$sanitized\".port_overrides.\"$service\")" "$file"
    log_debug "Cleared port override for $service"
}

# List every port override for a worktree as colon-delimited records.
# Args: $1 project, $2 branch
# Out:  one "service:port" line per override ("" if none)
list_port_overrides() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -r ".worktrees.\"$sanitized\".port_overrides // {} | to_entries | .[] | \"\(.key):\(.value)\"" "$file" 2>/dev/null
}
