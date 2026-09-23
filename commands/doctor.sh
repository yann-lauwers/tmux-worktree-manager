#!/bin/bash
# commands/doctor.sh - Diagnose project health

# Run wt's six diagnostic checks and print a PASS/FAIL/WARN line per check.
# Args: none (reads -p/--project from argv)
# Out: the diagnostic report
# Side: returns 1 when any check failed
cmd_doctor() {
    local project=""
    local passed=0
    local failed=0
    local warnings=0
    local json_output=0
    local section=""
    local check_idx=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "doctor" "$1" "${2:-}" "wt doctor [options]"
                project="$2"
                shift 2
                ;;
            --json) json_output=1; shift ;;
            -h|--help)
                show_doctor_help
                return 0
                ;;
            -*)
                die_unknown_option "doctor" "$1"
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$json_output" -eq 1 ]]; then
        json_begin
        json_set ".project" null
        json_set ".checks" arr
    else
        echo ""
        echo -e "${BOLD}wt doctor${NC}"
        echo "$(printf '%.0s-' {1..50})"
        echo ""
    fi

    # --- 1. Dependencies ---
    _doctor_section "dependencies" "Dependencies"

    _doctor_check_cmd "git" "brew install git"
    _doctor_check_cmd "yq" "brew install yq"
    _doctor_check_cmd "tmux" "brew install tmux"
    _doctor_check_cmd "envsubst" "brew install gettext"

    _doctor_echo ""

    # --- 2. Project config ---
    _doctor_section "project_configuration" "Project Configuration"

    # Resolve project (soft fail for doctor)
    if [[ -z "$project" ]]; then
        project=$(detect_project)
    fi

    if [[ -z "$project" ]]; then
        _doctor_warn "Could not detect project (not in a git repo with wt config)"
        _doctor_echo ""
    else
        _doctor_pass "Project detected: $project"
        [[ "$json_output" -eq 1 ]] && json_set ".project" str "$project"

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

        _doctor_echo ""

        # --- 3. State consistency ---
        _doctor_section "state_consistency" "State Consistency"

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
                    _doctor_warn "Orphaned worktree state: $sanitized_branch (path $wt_path missing) — reclaimed by \`wt delete $entry_branch\` or by the next \`wt create\` that finds every slot taken"
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

        _doctor_echo ""

        # --- 4. Worktree links ---
        _doctor_section "worktree_links" "Worktree Links"
        _doctor_check_links "$(expand_path "$(yaml_get "$config_file" ".repo_path" "")")"

        _doctor_echo ""

        # --- 5. Tmux health ---
        _doctor_section "tmux_health" "Tmux Health"

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

        _doctor_echo ""

        # --- 5. Port conflicts ---
        _doctor_section "port_conflicts" "Port Conflicts"

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
    if [[ "$json_output" -eq 1 ]]; then
        json_set ".summary.passed" int "$passed"
        json_set ".summary.failed" int "$failed"
        json_set ".summary.warnings" int "$warnings"
        json_set ".ok" bool "$([[ "$failed" -eq 0 ]] && echo true || echo false)"
        json_emit
    else
        echo ""
        echo "$(printf '%.0s-' {1..50})"
        echo -e "${BOLD}Summary:${NC} ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$warnings warnings${NC}"
    fi

    if [[ "$failed" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Append one row to the pending --json document's .checks array, under the
# section the caller's section variable currently names.
# Args: $1 section, $2 status (pass|fail|warn), $3 message
# Side: json_set calls against .checks[check_idx]; increments check_idx
_doctor_json_row() {
    local sec="$1"
    local status="$2"
    local message="$3"
    local base=".checks[$check_idx]"

    json_set "${base}.section" str "$sec"
    json_set "${base}.status" str "$status"
    json_set "${base}.message" str "$message"
    check_idx=$((check_idx + 1))
}

# Print a human-report line; prints nothing under --json. The report's only
# echo point outside the check rows, so --json stdout stays the document alone.
# Args: $@ echo -e arguments
_doctor_echo() {
    [[ "${json_output:-0}" -eq 1 ]] || echo -e "$@"
}

# Open one report section: name it for the --json rows that follow, and print
# its header in the human report.
# Args: $1 section key (e.g. dependencies), $2 human header
# Side: sets cmd_doctor's section local
_doctor_section() {
    section="$1"
    _doctor_echo "${BOLD}$2${NC}"
}

# Helper functions for doctor output — the single print point: in JSON mode
# each appends a row instead of echoing (json_output/section/check_idx are the
# caller's locals, visible here through cmd_doctor's own call stack).
_doctor_pass() {
    if [[ "${json_output:-0}" -eq 1 ]]; then
        _doctor_json_row "$section" "pass" "$1"
    else
        echo -e "  ${GREEN}PASS${NC}  $1"
    fi
    passed=$((passed + 1))
}

_doctor_fail() {
    if [[ "${json_output:-0}" -eq 1 ]]; then
        _doctor_json_row "$section" "fail" "$1"
    else
        echo -e "  ${RED}FAIL${NC}  $1"
    fi
    failed=$((failed + 1))
}

_doctor_warn() {
    if [[ "${json_output:-0}" -eq 1 ]]; then
        _doctor_json_row "$section" "warn" "$1"
    else
        echo -e "  ${YELLOW}WARN${NC}  $1"
    fi
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

# Report whether every linked worktree survives a move of either tree.
#
# A worktree is linked by two files that name each other: the worktree's `.git`
# names the repo, and `.git/worktrees/<id>/gitdir` names the worktree back. Both
# are absolute unless worktree.useRelativePaths is set, so renaming or moving
# either tree rots them — and the rot is one-directional. `git worktree list`
# keeps listing the worktree from the repo side while `git status` inside it
# answers "not a git repository", so nothing surfaces until someone happens to
# stand in the worktree. That is the failure this check exists to make visible.
#
# Args: $1 repo path (the main checkout)
# Side: prints pass/warn/fail lines; mutates nothing — every remedy is a command
#       the operator runs, since repairing a link is not a diagnostic's job
_doctor_check_links() {
    local repo_path="$1"

    if [[ -z "$repo_path" ]] || [[ ! -d "$repo_path" ]]; then
        _doctor_warn "No repo_path to check links against"
        return
    fi

    if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
        _doctor_warn "repo_path is not a git repository: $repo_path"
        return
    fi

    local rel
    rel=$(git -C "$repo_path" config --get worktree.useRelativePaths 2>/dev/null || true)
    if [[ "$rel" == "true" ]]; then
        _doctor_pass "worktree.useRelativePaths is set"
    else
        _doctor_warn "worktree.useRelativePaths is not set — new worktrees will link absolutely and break if either tree moves. Fix: git -C '$repo_path' config worktree.useRelativePaths true"
    fi

    local absolute=0 broken=0 checked=0 wt
    while read -r wt; do
        [[ -n "$wt" ]] || continue
        checked=$((checked + 1))

        if [[ ! -e "$wt/.git" ]]; then
            _doctor_fail "Registered worktree has no .git link: $wt"
            broken=$((broken + 1))
            continue
        fi

        # A relative link starts "gitdir: ." — any other prefix is an absolute path.
        if [[ "$(head -c 9 "$wt/.git" 2>/dev/null)" != "gitdir: ." ]]; then
            _doctor_warn "Absolute link: $wt. Fix: git -C '$repo_path' worktree repair '$wt'"
            absolute=$((absolute + 1))
        fi

        # The link resolving is a separate fact from its shape: a relative link
        # can still point at nothing if only one of the two trees was moved.
        if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
            _doctor_fail "Link does not resolve: $wt. Fix: git -C '$repo_path' worktree repair '$wt'"
            broken=$((broken + 1))
        fi
    done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null \
             | awk '/^worktree /{print $2}' | tail -n +2)

    if [[ "$checked" -eq 0 ]]; then
        _doctor_pass "No linked worktrees to check"
    elif [[ "$absolute" -eq 0 ]] && [[ "$broken" -eq 0 ]]; then
        _doctor_pass "All $checked worktree links are relative and resolving"
    fi
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

# Print the 'wt doctor' help page to stdout.
show_doctor_help() {
    cat << 'EOF'
Runs six diagnostic checks against your wt setup and project configuration and prints a
PASS/FAIL/WARN line per check plus a summary count. Reads state only: the state and slots
files are left unchanged.

Usage: wt doctor [options]

Checks performed:
  1. Dependencies       - git, yq, tmux, envsubst (with versions)
  2. Project Configuration - YAML syntax, required fields, port ranges
  3. State Consistency  - orphaned worktree entries, stale service PIDs
  4. Worktree Links     - each linked worktree's .git link is relative and resolves
  5. Tmux Health        - session exists, windows match recorded state
  6. Port Conflicts     - duplicate port assignments, range overlaps

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  --json                  Print one JSON document instead of PASS/FAIL/WARN lines (default: off)
  -h, --help              Show this page

Output (--json):
  { project, checks: [ { section, status, message } ], summary: { passed,
    failed, warnings }, ok }

  project is the detected project name, or null. section is one of
  dependencies, project_configuration, state_consistency, worktree_links,
  tmux_health, port_conflicts. status is "pass", "fail" or "warn". ok is
  true when failed == 0 — the same condition that decides the exit code
  below, so --json exits the same way the PASS/FAIL/WARN form does.

Examples:
  wt doctor
  wt doctor -p myproject
  wt doctor --json

Aliases: wt doc

Exit codes:
  0  no check failed; a warning (an orphaned worktree entry, a stale service PID)
     does not fail the run
  1  at least one check failed (bad config, missing repo_path, overlapping port
     ranges, a broken worktree link, ...)
  2  usage error: unknown option or missing option argument
EOF
}
