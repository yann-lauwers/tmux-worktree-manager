#!/bin/bash
# commands/doctor.sh - Diagnose project health

cmd_doctor() {
    local project=""
    local passed=0
    local failed=0
    local warnings=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_doctor_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_doctor_help
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    echo ""
    echo -e "${BOLD}wt doctor${NC}"
    echo "$(printf '%.0s-' {1..50})"
    echo ""

    # --- 1. Dependencies ---
    echo -e "${BOLD}Dependencies${NC}"

    _doctor_check_cmd "git" "brew install git"
    _doctor_check_cmd "yq" "brew install yq"
    _doctor_check_cmd "tmux" "brew install tmux"
    _doctor_check_cmd "envsubst" "brew install gettext"

    echo ""

    # --- 2. Project config ---
    echo -e "${BOLD}Project Configuration${NC}"

    # Resolve project (soft fail for doctor)
    if [[ -z "$project" ]]; then
        project=$(detect_project)
    fi

    if [[ -z "$project" ]]; then
        _doctor_warn "Could not detect project (not in a git repo with wt config)"
        echo ""
    else
        _doctor_pass "Project detected: $project"

        local config_file
        config_file=$(project_config_path "$project")

        if [[ -f "$config_file" ]]; then
            _doctor_pass "Config file exists: $config_file"

            # Validate YAML syntax
            if yq '.' "$config_file" >/dev/null 2>&1; then
                _doctor_pass "YAML syntax is valid"
            else
                _doctor_fail "YAML syntax error in $config_file"
            fi

            # Check required fields
            local repo_path
            repo_path=$(yaml_get "$config_file" ".repo_path" "")
            if [[ -n "$repo_path" ]]; then
                _doctor_pass "repo_path is set: $repo_path"
                local expanded_path
                expanded_path=$(expand_path "$repo_path")
                if [[ -d "$expanded_path" ]]; then
                    _doctor_pass "repo_path exists on disk"
                else
                    _doctor_fail "repo_path does not exist: $expanded_path"
                fi
            else
                _doctor_fail "repo_path is not set in config"
            fi

            # Check worktree_dir
            local worktree_dir
            worktree_dir=$(yaml_get "$config_file" ".worktree_dir" "")
            if [[ -n "$worktree_dir" ]]; then
                local expanded_wt_dir
                expanded_wt_dir=$(expand_path "$worktree_dir")
                _doctor_pass "worktree_dir configured: $worktree_dir"
                if [[ -d "$expanded_wt_dir" ]]; then
                    _doctor_pass "worktree_dir exists on disk"
                else
                    _doctor_warn "worktree_dir does not exist yet: $expanded_wt_dir (will be created on first wt create)"
                fi
            fi

            # Check port ranges
            local res_min res_max dyn_min dyn_max
            res_min=$(yaml_get "$config_file" ".ports.reserved.range.min" "")
            res_max=$(yaml_get "$config_file" ".ports.reserved.range.max" "")
            dyn_min=$(yaml_get "$config_file" ".ports.dynamic.range.min" "")
            dyn_max=$(yaml_get "$config_file" ".ports.dynamic.range.max" "")

            if [[ -n "$res_min" ]] && [[ -n "$res_max" ]]; then
                if (( res_min < res_max && res_min >= 1 && res_max <= 65535 )); then
                    _doctor_pass "Reserved port range valid: $res_min-$res_max"
                else
                    _doctor_fail "Invalid reserved port range: $res_min-$res_max"
                fi
            fi

            if [[ -n "$dyn_min" ]] && [[ -n "$dyn_max" ]]; then
                if (( dyn_min < dyn_max && dyn_min >= 1 && dyn_max <= 65535 )); then
                    _doctor_pass "Dynamic port range valid: $dyn_min-$dyn_max"
                else
                    _doctor_fail "Invalid dynamic port range: $dyn_min-$dyn_max"
                fi
            fi

            # Check for overlapping port ranges
            if [[ -n "$res_min" ]] && [[ -n "$res_max" ]] && [[ -n "$dyn_min" ]] && [[ -n "$dyn_max" ]]; then
                if (( res_max > dyn_min && dyn_max > res_min )); then
                    _doctor_fail "Reserved and dynamic port ranges overlap"
                else
                    _doctor_pass "Port ranges do not overlap"
                fi
            fi

            # Check services have valid references
            local svc_count
            svc_count=$(yaml_array_length "$config_file" ".services")
            if (( svc_count > 0 )); then
                _doctor_pass "$svc_count service(s) configured"
            else
                _doctor_warn "No services configured"
            fi
        else
            _doctor_fail "Config file not found: $config_file"
        fi

        echo ""

        # --- 3. State consistency ---
        echo -e "${BOLD}State Consistency${NC}"

        local state_f
        state_f=$(state_file "$project")

        if [[ -f "$state_f" ]]; then
            _doctor_pass "State file exists"

            # Check for orphaned worktree entries
            local orphaned=0
            local sanitized_branch wt_path
            while read -r sanitized_branch; do
                [[ -z "$sanitized_branch" ]] && continue
                wt_path=$(yaml_get "$state_f" ".worktrees.\"$sanitized_branch\".path" "")
                local entry_branch entry_ctx
                entry_branch=$(yaml_get "$state_f" ".worktrees.\"$sanitized_branch\".branch" "$sanitized_branch")
                entry_ctx=$(_doctor_port_context "$state_f" "$sanitized_branch" "$entry_branch" "$config_file")
                if [[ -n "$wt_path" ]] && [[ ! -d "$wt_path" ]]; then
                    _doctor_warn "Orphaned worktree state: $sanitized_branch (path $wt_path missing)"
                    orphaned=$((orphaned + 1))
                elif [[ "$entry_ctx" == "none" ]]; then
                    _doctor_warn "Orphaned worktree state: $sanitized_branch (no slot or path recorded)"
                    orphaned=$((orphaned + 1))
                fi
            done < <(list_worktree_states "$project")

            if [[ "$orphaned" -eq 0 ]]; then
                _doctor_pass "No orphaned worktree entries"
            fi

            # Check for stale service PIDs
            local stale_pids=0
            while read -r sanitized_branch; do
                [[ -z "$sanitized_branch" ]] && continue
                local branch_name
                branch_name=$(yaml_get "$state_f" ".worktrees.\"$sanitized_branch\".branch" "$sanitized_branch")

                local svc_name svc_status svc_port svc_pid
                while IFS=: read -r svc_name svc_status svc_port svc_pid; do
                    [[ -z "$svc_name" ]] && continue
                    if [[ "$svc_status" == "running" ]] && [[ -n "$svc_pid" ]] && [[ "$svc_pid" != "null" ]]; then
                        if ! kill -0 "$svc_pid" 2>/dev/null; then
                            _doctor_warn "Stale PID for $svc_name in $branch_name: PID $svc_pid not running"
                            stale_pids=$((stale_pids + 1))
                        fi
                    fi
                done < <(list_service_states "$project" "$branch_name")
            done < <(list_worktree_states "$project")

            if [[ "$stale_pids" -eq 0 ]]; then
                _doctor_pass "No stale service PIDs"
            fi
        else
            _doctor_warn "No state file found (no worktrees created yet?)"
        fi

        echo ""

        # --- 4. Tmux health ---
        echo -e "${BOLD}Tmux Health${NC}"

        if command_exists tmux; then
            if [[ -f "$config_file" ]]; then
                local tmux_session
                tmux_session=$(get_tmux_session_name "$config_file")

                if session_exists "$tmux_session"; then
                    _doctor_pass "Tmux session exists: $tmux_session"

                    # Check if windows match state
                    local tmux_windows
                    tmux_windows=$(list_sessions "$tmux_session")

                    while read -r sanitized_branch; do
                        [[ -z "$sanitized_branch" ]] && continue
                        if echo "$tmux_windows" | grep -q "^${sanitized_branch}$"; then
                            _doctor_pass "Window exists for: $sanitized_branch"
                        else
                            _doctor_warn "Missing tmux window for worktree: $sanitized_branch"
                        fi
                    done < <(list_worktree_states "$project")
                else
                    _doctor_warn "Tmux session not running: $tmux_session"
                fi
            fi
        else
            _doctor_fail "tmux is not installed"
        fi

        echo ""

        # --- 5. Port conflicts ---
        echo -e "${BOLD}Port Conflicts${NC}"

        if [[ -f "$config_file" ]]; then
            local all_ports=""
            local duplicate_ports=0

            while read -r sanitized_branch; do
                [[ -z "$sanitized_branch" ]] && continue
                local branch_name
                branch_name=$(yaml_get "$state_f" ".worktrees.\"$sanitized_branch\".branch" "$sanitized_branch")

                # An entry claims ports as a slot-allocated worktree, as the main repo
                # root (.ports.main), or not at all — reading a slotless entry as slot 0
                # invents a conflict with whichever worktree actually holds slot 0.
                local port_ctx port_data
                port_ctx=$(_doctor_port_context "$state_f" "$sanitized_branch" "$branch_name" "$config_file")
                case "$port_ctx" in
                    none)
                        continue
                        ;;
                    main)
                        port_data=$(WT_MAIN_CONTEXT=1 calculate_worktree_ports "$branch_name" "$config_file" 0 2>/dev/null)
                        ;;
                    slot:*)
                        port_data=$(calculate_worktree_ports "$branch_name" "$config_file" "${port_ctx#slot:}" 2>/dev/null)
                        ;;
                esac

                while IFS=: read -r svc_name svc_port; do
                    [[ -z "$svc_name" ]] && continue
                    # Check for override
                    local override
                    override=$(get_port_override "$project" "$branch_name" "$svc_name" 2>/dev/null)
                    local effective_port="${override:-$svc_port}"

                    if echo "$all_ports" | grep -q ":${effective_port}$"; then
                        _doctor_fail "Duplicate port $effective_port: $svc_name ($branch_name) conflicts with another service"
                        duplicate_ports=$((duplicate_ports + 1))
                    fi
                    all_ports="$all_ports
$svc_name@$sanitized_branch:$effective_port"
                done <<< "$port_data"
            done < <(list_worktree_states "$project")

            if [[ "$duplicate_ports" -eq 0 ]]; then
                _doctor_pass "No port conflicts detected"
            fi
        fi
    fi

    # --- Summary ---
    echo ""
    echo "$(printf '%.0s-' {1..50})"
    echo -e "${BOLD}Summary:${NC} ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$warnings warnings${NC}"

    if [[ "$failed" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Helper functions for doctor output
_doctor_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1"
    passed=$((passed + 1))
}

_doctor_fail() {
    echo -e "  ${RED}FAIL${NC}  $1"
    failed=$((failed + 1))
}

_doctor_warn() {
    echo -e "  ${YELLOW}WARN${NC}  $1"
    warnings=$((warnings + 1))
}

# Classify how a state entry claims ports, so a non-slot entry is not read as slot 0.
# Args: $1 state file, $2 sanitized branch key, $3 branch name, $4 project config file
# Out: "slot:<n>" for a slot-allocated worktree; "main" for the main-repo-root entry,
#      which runs on .ports.main (outside the reserved range) rather than a slot;
#      "none" for an entry that never claimed a slot — a stub left behind by a
#      worktree removed outside `wt delete`.
_doctor_port_context() {
    local state_f="$1"
    local sanitized_branch="$2"
    local branch_name="$3"
    local config_file="$4"

    local slot
    slot=$(yaml_get "$state_f" ".worktrees.\"$sanitized_branch\".slot" "")
    if [[ -n "$slot" ]]; then
        echo "slot:$slot"
        return
    fi

    # No slot recorded. `wt start` at the main repo root synthesizes its own context
    # (WT_MAIN_CONTEXT / WT_ROOT_SLOT in commands/start.sh) and writes a services-only
    # entry keyed by the branch checked out there — so match that branch to tell the
    # root's own entry apart from a leftover stub.
    local repo_path
    repo_path=$(yaml_get "$config_file" ".repo_path" "")
    if [[ -n "$repo_path" ]]; then
        local expanded_repo root_branch
        expanded_repo=$(expand_path "$repo_path")
        if [[ -d "$expanded_repo" ]]; then
            root_branch=$(git -C "$expanded_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
            if [[ -n "$root_branch" ]] && [[ "$(sanitize_branch_name "$root_branch")" == "$sanitized_branch" ]]; then
                echo "main"
                return
            fi
        fi
    fi

    echo "none"
}

_doctor_check_cmd() {
    local cmd="$1"
    local install_hint="$2"

    if command_exists "$cmd"; then
        local version=""
        case "$cmd" in
            git) version=$(git --version 2>/dev/null | head -1) ;;
            yq) version=$(yq --version 2>/dev/null | head -1) ;;
            tmux) version=$(tmux -V 2>/dev/null | head -1) ;;
            envsubst) version="available" ;;
        esac
        _doctor_pass "$cmd ($version)"
    else
        _doctor_fail "$cmd not found (install: $install_hint)"
    fi
}

show_doctor_help() {
    cat << 'EOF'
Usage: wt doctor [options]

Run diagnostic checks on your wt setup and project configuration.

Checks performed:
  1. Dependencies  - git, yq, tmux, envsubst (with versions)
  2. Project config - YAML syntax, required fields, port ranges
  3. State          - orphaned entries, stale PIDs
  4. Tmux health    - session exists, windows match state
  5. Port conflicts - duplicate assignments, range overlaps

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt doctor
  wt doctor -p myproject
EOF
}
