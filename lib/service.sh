#!/bin/bash
# lib/service.sh - Service lifecycle management

# Find the pane index for a service in the config
# Pane mapping for services-top layout with 5 panes (tmux renumbers by visual position):
#   config 0 (service 1) -> tmux pane 0 (top-left)
#   config 1 (service 2) -> tmux pane 1 (top-middle)
#   config 2 (service 3) -> tmux pane 2 (top-right)
#   config 3 (claude)    -> tmux pane 3 (bottom-left)
#   config 4 (orchestr)  -> tmux pane 4 (bottom-right)
find_service_pane_index() {
    local config_file="$1"
    local service_name="$2"

    # Read all pane services in one yq call
    local pane_services
    pane_services=$(yq -r '.tmux.windows[0].panes[]?.service // ""' "$config_file" 2>/dev/null)

    log_debug "find_service_pane_index: service=$service_name"

    local p=0
    while IFS= read -r svc; do
        if [[ "$svc" == "$service_name" ]]; then
            log_debug "find_service_pane_index: found $service_name at config $p -> tmux pane $p"
            echo "$p"
            return 0
        fi
        ((p++))
    done <<< "$pane_services"

    echo ""
    return 1
}

# Start a service
start_service() {
    local project="$1"
    local branch="$2"
    local service_name="$3"
    local config_file="$4"

    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")

    if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    # Get service configuration (single yq call for all fields)
    local svc_config
    svc_config=$(yq -r ".services[] | select(.name == \"$service_name\") | [.working_dir // \".\", .command // \"\", .port_key // \"\"] | @tsv" "$config_file" 2>/dev/null)

    local svc_dir svc_cmd port_key
    IFS=$'\t' read -r svc_dir svc_cmd port_key <<< "$svc_config"

    if [[ -z "$svc_cmd" ]] || [[ "$svc_cmd" == "null" ]]; then
        log_error "Service not found or has no command: $service_name"
        return 1
    fi

    # Get port for this service
    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        log_error "Could not find slot for worktree '$branch'. State may be corrupted."
        log_error "Try: wt delete $branch && wt create $branch"
        return 1
    fi

    log_debug "Getting port for service=$service_name port_key=$port_key branch=$branch slot=$slot"

    # Calculate all worktree ports once and reuse for both port lookup and export
    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$config_file" "$slot")

    # Check for port override first, then fall back to calculated port
    local port=""
    if [[ -n "$project" ]]; then
        port=$(get_port_override "$project" "$branch" "$port_key")
    fi
    if [[ -z "$port" ]]; then
        port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
    fi

    log_debug "Got port=$port for $service_name"

    if [[ -z "$port" ]]; then
        log_error "Could not determine port for service: $service_name"
        log_error "  port_key=$port_key, slot=$slot, config=$config_file"
        log_error "  Available ports: $(echo "$all_ports" | tr '\n' ' ')"
        return 1
    fi

    # Check if already running
    if is_service_running "$project" "$branch" "$service_name"; then
        log_warn "Service already running: $service_name"
        return 0
    fi

    # Export port variables using cached port data (avoids recalculating)
    export PORT="$port"
    export_port_vars "$branch" "$config_file" "$slot" "$project" "$all_ports"

    # Build environment string for tmux command
    # Start with PORT
    local env_string="PORT=$port"

    # Get service environment and build env string
    local svc_env
    svc_env=$(yq -r ".services[] | select(.name == \"$service_name\") | .env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Expand variables in value (e.g., ${PORT_GAP_INDEXER})
        value=$(echo "$value" | envsubst 2>/dev/null || echo "$value")
        # Add to env string for tmux command
        env_string="$env_string $key=$value"
        # Also export locally for pre_start commands
        export "$key=$value"
    done <<< "$svc_env"

    # Build exec_dir early so pre_start can use it
    local exec_dir="$worktree_path/$svc_dir"

    if [[ ! -d "$exec_dir" ]]; then
        log_error "Service working directory does not exist: $exec_dir"
        log_error "  Check 'working_dir' for service '$service_name' in config"
        return 1
    fi

    # Run pre_start commands in the service's working directory
    local pre_start
    pre_start=$(yq -r ".services[] | select(.name == \"$service_name\") | .pre_start // [] | .[]" "$config_file" 2>/dev/null)

    if [[ -n "$pre_start" ]]; then
        pushd "$exec_dir" > /dev/null 2>&1 || true
        while read -r cmd; do
            [[ -z "$cmd" ]] && continue
            log_debug "Pre-start ($svc_dir): $cmd"
            eval "$cmd" 2>/dev/null || true
        done <<< "$pre_start"
        popd > /dev/null 2>&1 || true
    fi

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$config_file")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Check if port is available before starting
    if ! is_port_available "$port"; then
        log_error "Port $port is already in use (service: $service_name)"
        log_error "Use 'wt ports set $service_name <port>' to assign a different port"
        return 1
    fi

    log_info "Starting $service_name on port $port..."

    # Find pane for this service within the worktree window
    local pane_idx
    pane_idx=$(find_service_pane_index "$config_file" "$service_name") || true

    if [[ -n "$pane_idx" ]]; then
        # Send command to the service pane with all env vars
        tmux send-keys -t "${tmux_session}:${window_name}.${pane_idx}" "cd '$exec_dir' && $env_string $svc_cmd" Enter
    else
        # No pane configured, create a new window for the service
        tmux new-window -t "$tmux_session" -n "${window_name}-${service_name}" -c "$exec_dir"
        tmux send-keys -t "${tmux_session}:${window_name}-${service_name}" "$env_string $svc_cmd" Enter
    fi

    # Update state (we don't have PID directly since it's in tmux)
    update_service_status "$project" "$branch" "$service_name" "running" "" "$port"

    # Run health check if configured
    local health_type
    health_type=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.type // \"\"" "$config_file" 2>/dev/null)

    if [[ -n "$health_type" ]] && [[ "$health_type" != "null" ]]; then
        run_health_check "$service_name" "$port" "$config_file"
    fi

    log_success "Started: $service_name (port $port)"
    return 0
}

# Start services directly in the current terminal (no tmux)
# Runs all services as background processes, waits for Ctrl+C to stop them all
start_services_direct() {
    local project="$1"
    local branch="$2"
    local config_file="$3"
    local service_names="$4"

    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")

    if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        log_error "Could not find slot for worktree '$branch'."
        return 1
    fi

    # Calculate all ports once
    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$config_file" "$slot")

    # Collect service commands
    local -a pids=()
    local -a svc_names=()
    local -a svc_ports=()

    # Trap Ctrl+C to kill all background services
    _direct_cleanup() {
        echo ""
        # Teardown is best-effort: Ctrl-C already SIGINT'd the foreground group, so
        # many of these kills hit already-dead pids and return non-zero. Under the
        # CLI's `set -e` that aborts the trap before the summary — disable it here so
        # every service is reaped and the per-service enumeration below always runs.
        set +e
        log_info "Stopping all services..."
        # Kill the whole process group of each tracked pipe PID — $! is the sed PID,
        # but the node server lives in the subshell's group; PGID kill reaches it.
        for pid in "${pids[@]}"; do
            local pgid
            pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
            if [[ -n "$pgid" ]]; then
                kill -TERM -- "-$pgid" 2>/dev/null
            else
                kill "$pid" 2>/dev/null
            fi
        done
        # Kill any processes still listening on our ports (catches orphaned servers).
        # SIGTERM then escalate to SIGKILL — mirrors stop_service so dev servers
        # that ignore or slow-handle SIGTERM don't leak and keep holding the port.
        for port in "${svc_ports[@]}"; do
            local listen_pid
            listen_pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
            if [[ -n "$listen_pid" ]]; then
                kill -TERM "$listen_pid" 2>/dev/null
            fi
        done
        sleep 1
        for port in "${svc_ports[@]}"; do
            local listen_pid
            listen_pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
            if [[ -n "$listen_pid" ]]; then
                kill -9 "$listen_pid" 2>/dev/null || true
            fi
        done
        wait 2>/dev/null
        # Enumerate each tracked service and confirm its port is actually free,
        # so it's clear every one stopped (not just a blanket "all stopped").
        # svc_names / svc_ports are index-aligned (pushed together at start).
        local _all_clear=1 _i _name _port
        for _i in "${!svc_names[@]}"; do
            _name="${svc_names[$_i]}"
            _port="${svc_ports[$_i]:-}"
            update_service_status "$project" "$branch" "$_name" "stopped" 2>/dev/null
            if [[ -n "$_port" ]] && [[ -n "$(lsof -iTCP:"$_port" -sTCP:LISTEN -t 2>/dev/null)" ]]; then
                log_warn "  ✗ $_name still listening on port $_port"
                _all_clear=0
            else
                log_success "  ✓ stopped $_name${_port:+ (port $_port)}"
            fi
        done
        if [[ "$_all_clear" -eq 1 ]]; then
            log_success "All ${#svc_names[@]} service(s) stopped"
        else
            log_warn "Some services may still be running — see ports above"
        fi
        trap - INT TERM
    }
    trap _direct_cleanup INT TERM

    local failed=0

    # Job control ON for the launches so each backgrounded service pipeline gets
    # its OWN process group. Without it, `&` jobs share wt's group, and the trap's
    # `kill -TERM -- "-$pgid"` would nuke wt itself — aborting teardown before the
    # summary. Restored after the loop (existing jobs keep their groups). Scripts
    # are non-interactive, so this emits no "[1] pid" job-control chatter.
    local _had_monitor=0; [[ -o monitor ]] && _had_monitor=1
    set -m

    while read -r name; do
        [[ -z "$name" ]] && continue

        # Get service config
        local svc_config
        svc_config=$(yq -r ".services[] | select(.name == \"$name\") | [.working_dir // \".\", .command // \"\", .port_key // \"\"] | @tsv" "$config_file" 2>/dev/null)

        local svc_dir svc_cmd port_key
        IFS=$'\t' read -r svc_dir svc_cmd port_key <<< "$svc_config"

        if [[ -z "$svc_cmd" ]] || [[ "$svc_cmd" == "null" ]]; then
            log_error "Service not found or has no command: $name"
            continue
        fi

        # Get port
        local port=""
        if [[ -n "$project" ]]; then
            port=$(get_port_override "$project" "$branch" "$port_key")
        fi
        if [[ -z "$port" ]]; then
            port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
        fi

        if [[ -z "$port" ]]; then
            log_error "Could not determine port for service: $name"
            continue
        fi

        # Check port availability
        if ! is_port_available "$port"; then
            log_error "Port $port is already in use (service: $name)"
            ((failed++))
            continue
        fi

        local exec_dir="$worktree_path/$svc_dir"

        # Build environment string
        local env_string="PORT=$port"
        local svc_env
        svc_env=$(yq -r ".services[] | select(.name == \"$name\") | .env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            value=$(echo "$value" | envsubst 2>/dev/null || echo "$value")
            env_string="$env_string $key=$value"
        done <<< "$svc_env"

        # Export port vars for the env_string expansion
        export_port_vars "$branch" "$config_file" "$slot" "$project" "$all_ports"

        log_info "Starting $name on port $port..."

        # Run in background, prefix output with service name. Direct mode has no
        # tmux pane to capture later, so tee to a per-service file — otherwise the
        # output exists only on this terminal and `wt logs` has nothing to read.
        local log_file
        log_file=$(service_log_file "$project" "$branch" "$name")
        mkdir -p "$(dirname "$log_file")"
        : > "$log_file"
        (
            cd "$exec_dir" || exit 1
            eval "$env_string $svc_cmd"
        ) 2>&1 | sed -u "s/^/[${name}] /" | tee -a "$log_file" &
        pids+=($!)
        svc_names+=("$name")
        svc_ports+=("$port")

        update_service_status "$project" "$branch" "$name" "running" "" "$port"
    done <<< "$service_names"

    [[ "$_had_monitor" -eq 0 ]] && set +m

    if [[ ${#pids[@]} -eq 0 ]]; then
        log_error "No services were started"
        return 1
    fi

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to start (port conflict)"
    fi

    local svc_count=${#pids[@]}
    log_success "$svc_count service(s) running — Ctrl+C to stop all"

    # Run post_start hook
    export BRANCH_NAME="$branch"
    export WORKTREE_PATH="$worktree_path"
    run_hook "$config_file" "post_start"

    # Wait for all background processes
    wait
}

# Stop a service
stop_service() {
    local project="$1"
    local branch="$2"
    local service_name="$3"
    local config_file="$4"

    log_info "Stopping $service_name..."

    # Get tmux session and window names
    local tmux_session
    tmux_session=$(get_tmux_session_name "$config_file")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Find pane for this service within the worktree window
    local pane_idx
    pane_idx=$(find_service_pane_index "$config_file" "$service_name") || true

    if [[ -n "$pane_idx" ]]; then
        # Interrupt the service pane
        interrupt_pane "$tmux_session" "${window_name}.${pane_idx}" 2>/dev/null || true
    else
        # Try service-named window (fallback for services started without pane config)
        if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -q "^${window_name}-${service_name}$"; then
            interrupt_pane "$tmux_session" "${window_name}-${service_name}" 2>/dev/null || true
        fi
    fi

    # Port-based kill fallback — handles direct mode where tmux interrupt is a no-op.
    # Resolve port from state first, then fall back to the computed port from
    # config+slot so orphans from state-less or stale runs are still reachable.
    local svc_port
    svc_port=$(get_service_state "$project" "$branch" "$service_name" "port")
    if [[ -z "$svc_port" ]] || [[ "$svc_port" == "null" ]]; then
        local slot
        slot=$(get_worktree_slot "$project" "$branch")
        if [[ -n "$slot" ]]; then
            local port_key
            port_key=$(yq -r ".services[] | select(.name == \"$service_name\") | .port_key // \"\"" "$config_file" 2>/dev/null)
            if [[ -n "$port_key" ]] && [[ "$port_key" != "null" ]]; then
                svc_port=$(get_service_port "$port_key" "$branch" "$config_file" "$slot" "$project")
            fi
        fi
    fi

    local kill_failed=0
    if [[ -n "$svc_port" ]] && [[ "$svc_port" != "null" ]]; then
        if ! kill_port_listeners "$svc_port"; then
            kill_failed=1
            log_error "Failed to free port $svc_port for service $service_name"
        fi
    fi

    # One service entry can supervise several servers — a monorepo task runner
    # starting an API and a web server under a single command is the normal
    # case. Only its own `port_key` is freed above, so every other port it
    # occupies keeps listening while stop reports success, and the survivor
    # then blocks the next start on a port conflict. `stop_port_keys` names the
    # full set to free.
    local stop_keys stop_slot stop_port
    stop_keys=$(yq -r ".services[] | select(.name == \"$service_name\") | .stop_port_keys // [] | .[]" "$config_file" 2>/dev/null || echo "")
    if [[ -n "$stop_keys" ]]; then
        stop_slot=$(get_worktree_slot "$project" "$branch")
        if [[ -n "$stop_slot" ]]; then
            while read -r key; do
                [[ -z "$key" ]] && continue
                stop_port=$(get_service_port "$key" "$branch" "$config_file" "$stop_slot" "$project")
                [[ -z "$stop_port" || "$stop_port" == "null" ]] && continue
                [[ "$stop_port" == "$svc_port" ]] && continue
                if ! kill_port_listeners "$stop_port"; then
                    kill_failed=1
                    log_error "Failed to free port $stop_port ($key) for service $service_name"
                fi
            done <<< "$stop_keys"
        fi
    fi

    # Update state only when the kill actually freed the port — otherwise the
    # next `wt start` will hit a port conflict that "Stopped: …" would have hidden.
    if [[ "$kill_failed" -eq 0 ]]; then
        update_service_status "$project" "$branch" "$service_name" "stopped"
        log_success "Stopped: $service_name"
        return 0
    fi
    return 1
}

# Kill every process listening on $port, escalating SIGTERM → SIGKILL, then
# verify the port is actually free. Returns non-zero if anything still listens.
kill_port_listeners() {
    local port="$1"
    local term_wait="${2:-3}"
    local kill_wait="${3:-2}"

    local listeners
    listeners=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
    [[ -z "$listeners" ]] && return 0

    # SIGTERM every listener (and its process group — catches parent supervisors
    # like `next dev` / `turbo` that may otherwise respawn the worker).
    while read -r pid; do
        [[ -z "$pid" ]] && continue
        local pgid
        pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$pgid" ]]; then
            kill -TERM -- "-$pgid" 2>/dev/null || true
        fi
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$listeners"

    # Poll for graceful exit — next-server typically needs ~1–3s.
    local waited=0
    while (( waited < term_wait )); do
        if [[ -z "$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)" ]]; then
            return 0
        fi
        sleep 1
        ((waited++))
    done

    # Escalate to SIGKILL on whatever still holds the port.
    listeners=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
    while read -r pid; do
        [[ -z "$pid" ]] && continue
        kill -9 "$pid" 2>/dev/null || true
    done <<< "$listeners"

    waited=0
    while (( waited < kill_wait )); do
        if [[ -z "$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)" ]]; then
            return 0
        fi
        sleep 1
        ((waited++))
    done

    # Port still held — caller decides how to surface.
    return 1
}

# Start all services
start_all_services() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    # Pre-fetch all service names in one yq call
    local service_names
    service_names=$(yq -r '.services[].name' "$config_file" 2>/dev/null)

    if [[ -z "$service_names" ]]; then
        log_info "No services configured"
        return 0
    fi

    local service_count
    service_count=$(echo "$service_names" | wc -l | tr -d ' ')

    log_info "Starting $service_count services..."

    local failed=0

    while read -r name; do
        [[ -z "$name" ]] && continue

        if ! start_service "$project" "$branch" "$name" "$config_file"; then
            ((failed++))
        fi

        # Small delay between service starts
        sleep 1
    done <<< "$service_names"

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to start"
        return 1
    fi

    log_success "All services started"
    return 0
}

# Stop all services
stop_all_services() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    # Pre-fetch all service names in one yq call
    local service_names
    service_names=$(yq -r '.services[].name' "$config_file" 2>/dev/null)

    if [[ -z "$service_names" ]]; then
        return 0
    fi

    local service_count
    service_count=$(echo "$service_names" | wc -l | tr -d ' ')

    log_info "Stopping $service_count services..."

    local failed=0
    while read -r name; do
        [[ -z "$name" ]] && continue
        if ! stop_service "$project" "$branch" "$name" "$config_file"; then
            ((failed++))
        fi
    done <<< "$service_names"

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to stop"
        return 1
    fi

    log_success "All services stopped"
}

# Run health check for a service
run_health_check() {
    local service_name="$1"
    local port="$2"
    local config_file="$3"
    # Optional: override the configured timeout. `wt start` waits for boot and
    # omits it; a one-shot probe passes a short value so a down service fails
    # fast instead of blocking for the configured boot window.
    local timeout_override="${4:-}"

    # Batch health check config (single yq call for all fields)
    local health_config
    health_config=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check | [.type // \"\", .timeout // 30, .interval // 2, .url // \"\"] | @tsv" "$config_file" 2>/dev/null)

    local health_type timeout interval health_url
    IFS=$'\t' read -r health_type timeout interval health_url <<< "$health_config"

    if [[ -n "$timeout_override" ]]; then
        timeout="$timeout_override"
    fi

    log_info "Running health check for $service_name (${health_type}, timeout: ${timeout}s)..."

    local elapsed=0

    case "$health_type" in
        tcp)
            while ! nc -z localhost "$port" 2>/dev/null; do
                if ((elapsed >= timeout)); then
                    log_warn "Health check timed out for $service_name"
                    return 1
                fi
                sleep "$interval"
                ((elapsed += interval))
            done
            ;;
        http)
            # A probe is a url plus an optional body fragment the response must
            # contain. A status code alone cannot identify WHICH service
            # answered: a dev server that has taken a sibling's port serves its
            # SPA fallback on every path, so a code-only check reports the
            # impostor as the service it displaced, and the stack reads healthy
            # while the real one is unreachable. `expect` closes that.
            #
            # `extra` probes let one service assert on more than one endpoint —
            # a single process tree serving both an API and a web server has no
            # other way to report that half of it is down.
            local -a probe_urls=() probe_expects=()
            probe_urls+=("$(echo "$health_url" | envsubst 2>/dev/null || echo "$health_url")")
            probe_expects+=("$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.expect // \"\"" "$config_file" 2>/dev/null || echo "")")

            local extra_count
            extra_count=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.extra // [] | length" "$config_file" 2>/dev/null || echo 0)
            [[ "$extra_count" =~ ^[0-9]+$ ]] || extra_count=0

            local i=0 eu ee
            while [[ $i -lt $extra_count ]]; do
                eu=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.extra[$i].url // \"\"" "$config_file" 2>/dev/null || echo "")
                ee=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.extra[$i].expect // \"\"" "$config_file" 2>/dev/null || echo "")
                probe_urls+=("$(echo "$eu" | envsubst 2>/dev/null || echo "$eu")")
                probe_expects+=("$ee")
                i=$((i + 1))
            done

            # --max-time bounds each attempt. Without it a socket that accepts
            # and never responds blocks the first curl forever, so the elapsed
            # check below is never reached — and an accept-and-hang backend is
            # precisely what an http check exists to catch.
            local all_ok idx body want failed_url
            while true; do
                all_ok=1
                idx=0
                failed_url=""
                for want in "${probe_urls[@]}"; do
                    body=$(curl -sf --max-time "$interval" "${probe_urls[$idx]}" 2>/dev/null || echo "")
                    want="${probe_expects[$idx]}"
                    if [[ -z "$body" ]]; then
                        all_ok=0
                        failed_url="${probe_urls[$idx]} (no response)"
                    elif [[ -n "$want" && "$body" != *"$want"* ]]; then
                        all_ok=0
                        failed_url="${probe_urls[$idx]} (answered, but not by this service)"
                    fi
                    if [[ $all_ok -eq 0 ]]; then
                        break
                    fi
                    idx=$((idx + 1))
                done

                if [[ $all_ok -eq 1 ]]; then
                    break
                fi
                if ((elapsed >= timeout)); then
                    log_warn "Health check timed out for $service_name: $failed_url"
                    return 1
                fi
                sleep "$interval"
                ((elapsed += interval)) || true
            done
            ;;
        *)
            # No health check
            return 0
            ;;
    esac

    log_success "Health check passed for $service_name"
    return 0
}

# Path to a service's direct-mode log file.
# Branch names contain slashes; flatten them so the path stays one level deep.
service_log_file() {
    local project="$1"
    local branch="$2"
    local service_name="$3"

    local safe_branch
    safe_branch=$(echo "$branch" | tr '/' '-')

    echo "$WT_DATA_DIR/logs/${project}/${safe_branch}-${service_name}.log"
}

# Get service status
get_service_status() {
    local project="$1"
    local branch="$2"
    local service_name="$3"

    local status
    status=$(get_service_state "$project" "$branch" "$service_name" "status")

    echo "${status:-unknown}"
}

# List all services with their status
list_services_status() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    local service_count
    service_count=$(get_services "$config_file")

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    # Calculate all ports once for the entire listing
    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$config_file" "$slot")

    printf "\n${BOLD}%-25s %-10s %-8s${NC}\n" "SERVICE" "STATUS" "PORT"
    printf "%s\n" "$(printf '%.0s-' {1..45})"

    for ((i = 0; i < service_count; i++)); do
        local name
        name=$(get_service_by_index "$config_file" "$i" "name")

        local port_key
        port_key=$(get_service_by_index "$config_file" "$i" "port_key")

        # Look up port from cached calculation, with override check
        local port=""
        if [[ -n "$project" ]]; then
            port=$(get_port_override "$project" "$branch" "$port_key")
        fi
        if [[ -z "$port" ]]; then
            port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
        fi

        local status
        status=$(get_service_status "$project" "$branch" "$name")

        local status_color="$YELLOW"
        case "$status" in
            running) status_color="$GREEN" ;;
            stopped) status_color="$RED" ;;
        esac

        printf "%-25s ${status_color}%-10s${NC} %-8s\n" "$name" "$status" "${port:-N/A}"
    done
}
