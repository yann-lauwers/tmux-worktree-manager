#!/bin/bash
# lib/port.sh - Port hashing and slot management

# Calculate a dynamic port by hashing the branch name (cksum: deterministic, portable).
# Args: $1 branch, $2 port_min (4000), $3 port_max (5000), $4 used_ports (space-separated, optional)
# Out:  the chosen port; linearly probes past any collision with used_ports
calculate_dynamic_port() {
    local branch="$1"
    local port_min="${2:-4000}"
    local port_max="${3:-5000}"
    local used_ports="${4:-}"

    local range=$((port_max - port_min))
    local hash
    hash=$(echo -n "$branch" | cksum | awk '{print $1}')

    local port=$((port_min + (hash % range)))

    # If collision detected, probe linearly for next available port
    if [[ -n "$used_ports" ]]; then
        local attempts=0
        while [[ " $used_ports " == *" $port "* ]] && (( attempts < range )); do
            port=$(( port_min + ((port - port_min + 1) % range) ))
            ((attempts++))
        done
    fi

    echo "$port"
}

# Calculate a slot's reserved port: base + slot*services_per_slot + offset (slot 0 -> 3000/3001, slot 1 -> 3002/3003, …).
# Args: $1 slot, $2 service_offset, $3 base (3000), $4 services_per_slot (2)
# Out:  the reserved port; fails (log_error, return 1) if outside 1-65535
calculate_reserved_port() {
    local slot="$1"
    local service_offset="$2"
    local base="${3:-3000}"
    local services_per_slot="${4:-2}"

    local port=$((base + (slot * services_per_slot) + service_offset))
    if (( port < 1 || port > 65535 )); then
        log_error "Calculated port $port is out of valid range (1-65535). Check port config and slot count."
        return 1
    fi
    echo "$port"
}

# Compute every service port for a worktree — reserved (slot-derived, or .ports.main.<svc> under WT_MAIN_CONTEXT) plus dynamic (hashed, collision-avoided).
# Args: $1 branch, $2 config_file, $3 slot
# Out:  one SERVICE_NAME:PORT line per service
calculate_worktree_ports() {
    local branch="$1"
    local config_file="$2"
    local slot="$3"
    local svc_name offset svc_port  # Declare loop vars local

    local reserved_base
    reserved_base=$(yaml_get "$config_file" ".ports.reserved.range.min" "3000")

    local dynamic_min
    dynamic_min=$(yaml_get "$config_file" ".ports.dynamic.range.min" "4000")

    local dynamic_max
    dynamic_max=$(yaml_get "$config_file" ".ports.dynamic.range.max" "5000")

    # Get reserved services
    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | to_entries | .[] | "\(.key):\(.value)"' "$config_file" 2>/dev/null)

    # Get dynamic services
    local dynamic_services
    dynamic_services=$(yq -r '.ports.dynamic.services // {} | keys | .[]' "$config_file" 2>/dev/null)

    # Output reserved service ports.
    # Main-repo-root context (WT_MAIN_CONTEXT=1): the root runs on each service's
    # conventional default (e.g. FE 3000 / BE 3001), which lives OUTSIDE the
    # worktree reserved range. Read those from `.ports.main.<service>` when set,
    # falling back to the slot-derived reserved port if a project omits the block.
    while IFS=: read -r svc_name offset; do
        [[ -z "$svc_name" ]] && continue
        if [[ "${WT_MAIN_CONTEXT:-}" == "1" ]]; then
            local main_port
            main_port=$(yaml_get "$config_file" ".ports.main.\"$svc_name\"" "")
            if [[ -n "$main_port" ]]; then
                echo "$svc_name:$main_port"
                continue
            fi
        fi
        svc_port=$(calculate_reserved_port "$slot" "$offset" "$reserved_base")
        echo "$svc_name:$svc_port"
    done <<< "$reserved_services"

    # Collect ports already assigned (reserved + other worktrees' dynamic ports)
    local used_dynamic_ports=""

    # Output dynamic service ports (with collision avoidance)
    while read -r svc_name; do
        [[ -z "$svc_name" ]] && continue
        svc_port=$(calculate_dynamic_port "$branch" "$dynamic_min" "$dynamic_max" "$used_dynamic_ports")
        used_dynamic_ports="$used_dynamic_ports $svc_port"
        echo "$svc_name:$svc_port"
    done <<< "$dynamic_services"
}

# Export PORT_<SERVICE> env vars for every service (project overrides applied when given).
# Args: $1 branch, $2 config_file, $3 slot, $4 project ("" = no overrides), $5 cached_ports (pre-computed SERVICE:PORT lines, optional)
# Side: exports PORT_<SERVICE> (uppercased, dashes->underscores) into the environment
export_port_vars() {
    local branch="$1"
    local config_file="$2"
    local slot="$3"
    local project="${4:-}"
    local cached_ports="${5:-}"
    local svc_name svc_port  # Declare loop vars local to avoid clobbering caller's vars

    # Use cached ports if provided, otherwise calculate
    local port_data
    if [[ -n "$cached_ports" ]]; then
        port_data="$cached_ports"
    else
        port_data=$(calculate_worktree_ports "$branch" "$config_file" "$slot")
    fi

    while IFS=: read -r svc_name svc_port; do
        [[ -z "$svc_name" ]] && continue

        # Check for port override if project is provided
        local effective_port="$svc_port"
        if [[ -n "$project" ]]; then
            local override
            override=$(get_port_override "$project" "$branch" "$svc_name")
            if [[ -n "$override" ]]; then
                effective_port="$override"
                log_debug "Using port override for $svc_name: $override"
            fi
        fi

        # Export PORT_<SERVICE_NAME> (uppercase, dashes to underscores)
        local var_name
        var_name="PORT_$(echo "$svc_name" | tr '[:lower:]-' '[:upper:]_')"
        export "$var_name=$effective_port"
        log_debug "Exported port: $var_name=$effective_port"
    done <<< "$port_data"
}

# Get the port for one service (checks project overrides first when project given).
# Args: $1 service, $2 branch, $3 config_file, $4 slot, $5 project ("" = no overrides)
# Out:  the service's port
get_service_port() {
    local service="$1"
    local branch="$2"
    local config_file="$3"
    local slot="$4"
    local project="${5:-}"

    # Check for port override if project is provided
    if [[ -n "$project" ]]; then
        local override
        override=$(get_port_override "$project" "$branch" "$service")
        if [[ -n "$override" ]]; then
            log_debug "Using port override for $service: $override"
            echo "$override"
            return 0
        fi
    fi

    calculate_worktree_ports "$branch" "$config_file" "$slot" | grep "^$service:" | cut -d: -f2
}

# Print the path to the slot-assignments file.
# Out:  $WT_STATE_DIR/slots.yaml
slots_file() {
    echo "$WT_STATE_DIR/slots.yaml"
}

# Create the slots file with an empty slots map if it does not already exist.
# Side: writes $WT_STATE_DIR/slots.yaml when absent
init_slots_file() {
    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        cat > "$file" << 'EOF'
# Slot assignments for reserved ports
# Each slot maps to a set of ports for Privy-dependent services
slots: {}
EOF
    fi
}

# Look up the slot already assigned to a worktree.
# Args: $1 project, $2 branch
# Out:  the slot number, or empty if none assigned
get_slot_for_worktree() {
    local project="$1"
    local branch="$2"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".slots.\"$project\".\"$sanitized\"" ""
}

# Claim a slot for a worktree under a file lock (idempotent if already assigned).
# Args: $1 project, $2 branch, $3 max_slots (3), $4 port_base ("" skips system port checks), $5 services_per_slot (2)
# Out:  the claimed slot number
# Side: writes slots.yaml under lock (via _claim_slot_locked); returns non-zero if no slot free
claim_slot() {
    local project="$1"
    local branch="$2"
    local max_slots="${3:-3}"
    local port_base="${4:-}"
    local services_per_slot="${5:-2}"

    init_slots_file
    local file
    file=$(slots_file)

    with_file_lock "$file" _claim_slot_locked "$project" "$branch" "$max_slots" "$file" "$port_base" "$services_per_slot"
}

# Find and claim the first free slot for a worktree (called under with_file_lock).
# Args: $1 project, $2 branch, $3 max_slots, $4 file, $5 port_base ("" skips system port checks), $6 services_per_slot (2)
# Out:  the claimed slot number; returns non-zero if no slot is free
# Side: writes slots.yaml (yq -i) when a slot is claimed
_claim_slot_locked() {
    local project="$1"
    local branch="$2"
    local max_slots="$3"
    local file="$4"
    local port_base="${5:-}"
    local services_per_slot="${6:-2}"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    # Check if already has a slot
    local existing_slot
    existing_slot=$(yq -r ".slots.\"$project\".\"$sanitized\" // \"\"" "$file" 2>/dev/null)

    if [[ -n "$existing_slot" ]]; then
        echo "$existing_slot"
        return 0
    fi

    # Find available slot
    local used_slots=()
    for ((i = 0; i < max_slots; i++)); do
        used_slots[$i]=0
    done

    # Mark used slots
    local assignments
    assignments=$(yq -r ".slots.\"$project\" // {} | to_entries | .[] | .value" "$file" 2>/dev/null)

    while read -r slot; do
        [[ -z "$slot" ]] && continue
        if [[ "$slot" =~ ^[0-9]+$ ]] && (( slot < max_slots )); then
            used_slots[$slot]=1
        fi
    done <<< "$assignments"

    # Find first available (not claimed by another worktree AND ports free on system)
    for ((i = 0; i < max_slots; i++)); do
        if [[ "${used_slots[$i]}" == "0" ]]; then
            # If port_base provided, verify all ports for this slot are free
            if [[ -n "$port_base" ]]; then
                local ports_ok=true
                for ((j = 0; j < services_per_slot; j++)); do
                    local candidate_port=$((port_base + (i * services_per_slot) + j))
                    if port_in_use "$candidate_port"; then
                        log_warn "Slot $i skipped: port $candidate_port already in use on system"
                        ports_ok=false
                        break
                    fi
                done
                if [[ "$ports_ok" != "true" ]]; then
                    continue
                fi
            fi

            # Claim this slot
            yq -i ".slots.\"$project\".\"$sanitized\" = $i" "$file"
            echo "$i"
            return 0
        fi
    done

    # No slots available
    return 1
}

# Release the slot a worktree holds, under a file lock.
# Args: $1 project, $2 branch
# Side: deletes the worktree's slot from slots.yaml under lock (via _release_slot_locked)
release_slot() {
    local project="$1"
    local branch="$2"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        return
    fi

    with_file_lock "$file" _release_slot_locked "$project" "$branch" "$file"
}

# Delete a worktree's slot entry from slots.yaml (called under with_file_lock).
# Args: $1 project, $2 branch, $3 file
# Side: writes slots.yaml (yq -i del)
_release_slot_locked() {
    local project="$1"
    local branch="$2"
    local file="$3"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -i "del(.slots.\"$project\".\"$sanitized\")" "$file"
    log_debug "Released slot for $project/$branch"
}

# List every slot assignment for a project.
# Args: $1 project
# Out:  one branch:slot line per assigned worktree
list_slots() {
    local project="$1"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r ".slots.\"$project\" // {} | to_entries | .[] | .key + \":\" + (.value | tostring)" "$file" 2>/dev/null
}

# Count how many slots a project currently holds.
# Args: $1 project
# Out:  the number of assigned slots (0 if none)
slots_in_use() {
    local project="$1"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    yq ".slots.\"$project\" // {} | length" "$file" 2>/dev/null || echo "0"
}

# Report whether a port is free, via exit status.
# Args: $1 port
is_port_available() {
    local port="$1"
    ! port_in_use "$port"
}

# Find a free port in a range, trying a preferred port first.
# Args: $1 min, $2 max, $3 preferred (optional), $4 exclude (space-separated, optional)
# Out:  the first available port; returns non-zero if none free
find_available_port() {
    local min="$1"
    local max="$2"
    local preferred="${3:-}"
    local exclude="${4:-}"

    # Try preferred port first
    if [[ -n "$preferred" ]] && is_port_available "$preferred" && [[ " $exclude " != *" $preferred "* ]]; then
        echo "$preferred"
        return 0
    fi

    # Scan range
    for ((port = min; port <= max; port++)); do
        if is_port_available "$port" && [[ " $exclude " != *" $port "* ]]; then
            echo "$port"
            return 0
        fi
    done

    return 1
}
