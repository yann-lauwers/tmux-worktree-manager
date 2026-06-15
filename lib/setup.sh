#!/bin/bash
# lib/setup.sh - Setup step executor with dependency resolution

# Check if a group name is in a comma-separated list
# Usage: _group_in_list "db" "db,test"  → returns 0 (true)
_group_in_list() {
    local group="$1"
    local list="$2"
    local IFS=','
    for item in $list; do
        [[ "$item" == "$group" ]] && return 0
    done
    return 1
}

# Spinner frames for animated progress
_SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Draw the progress bar (2 lines: step label + bar). Overwrites in place.
# Usage: _draw_progress <current> <total> <label> <status> [spinner_index]
#   status: "running", "done", "fail"
_draw_progress() {
    local current="$1" total="$2" label="$3" status="${4:-running}" spin_idx="${5:-0}"
    local bar_width=30
    local filled=$(( current * bar_width / total ))
    local empty=$(( bar_width - filled ))

    # Build bar string
    local bar=""
    for ((b = 0; b < filled; b++)); do bar+="█"; done
    for ((b = 0; b < empty; b++)); do bar+="░"; done

    # Status icon + colors
    local icon color
    case "$status" in
        running) icon="${_SPINNER_FRAMES:$((spin_idx % ${#_SPINNER_FRAMES})):1}" ; color="$CYAN" ;;
        done)    icon="✓" ; color="$GREEN" ;;
        fail)    icon="✗" ; color="$RED" ;;
    esac

    # Move to start of our 2-line region and overwrite
    # \e[2K = clear entire line, \r = carriage return
    printf "\e[2K\r  ${color}${icon}${NC} ${BOLD}[%d/%d]${NC} %s\n" "$current" "$total" "$label" >&2
    printf "\e[2K\r  ${color}%s${NC}\r" "$bar" >&2
    # Move cursor back up to the label line so next draw overwrites both
    printf "\e[1A\r" >&2
}

# Run a command with an animated spinner on the progress bar.
# Usage: _run_with_spinner <current> <total> <label> <log_file> <dir> <cmd>
# Sets _RUN_EXIT_CODE on return.
_run_with_spinner() {
    local current="$1" total="$2" label="$3" log_file="$4" exec_dir="$5"
    shift 5
    local cmd="$*"

    # Run command in background
    (cd "$exec_dir" && eval "$cmd") > "$log_file" 2>&1 &
    local pid=$!

    # Animate spinner while process runs
    local frame=0
    while kill -0 "$pid" 2>/dev/null; do
        _draw_progress "$current" "$total" "$label" "running" "$frame"
        ((frame++))
        sleep 0.08
    done

    # Collect exit code
    wait "$pid"
    _RUN_EXIT_CODE=$?
}

# Finalize progress display — move cursor past the 2-line region
_finish_progress() {
    # Move down past label + bar lines
    printf "\n\n" >&2
}

# Execute all setup steps for a worktree
# Usage: execute_setup <worktree_path> <config_file> [step_filter] [skip_groups]
#   skip_groups: comma-separated list of groups to skip (e.g. "db,test")
execute_setup() {
    local worktree_path="$1"
    local config_file="$2"
    local step_filter="${3:-}"  # Optional: run only specific step
    local skip_groups="${4:-}"  # Optional: comma-separated groups to skip

    local step_count
    step_count=$(get_setup_steps "$config_file")

    if [[ "$step_count" -eq 0 ]]; then
        log_info "No setup steps configured"
        return 0
    fi

    # Count effective steps (excluding skipped groups)
    local effective_count=0
    if [[ -n "$skip_groups" ]]; then
        for ((i = 0; i < step_count; i++)); do
            local grp
            grp=$(get_setup_step "$config_file" "$i" "group")
            if [[ -z "$grp" || "$grp" == "null" ]] || ! _group_in_list "$grp" "$skip_groups"; then
                ((effective_count++))
            fi
        done
    else
        effective_count=$step_count
    fi

    if [[ "$effective_count" -eq 0 ]]; then
        log_info "No setup steps to run (all skipped)"
        return 0
    fi

    log_info "Running setup with $effective_count steps..."
    echo "" >&2  # blank line before progress

    local completed=()
    local failed=()
    local skipped=()
    local log_file
    log_file=$(mktemp)

    # Reserve 2 lines for the progress display
    printf "\n" >&2

    local progress_idx=0

    for ((i = 0; i < step_count; i++)); do
        local step_name
        step_name=$(get_setup_step "$config_file" "$i" "name")

        local step_desc
        step_desc=$(get_setup_step "$config_file" "$i" "description")
        step_desc="${step_desc:-$step_name}"

        local step_cmd
        step_cmd=$(get_setup_step "$config_file" "$i" "command")

        local step_dir
        step_dir=$(get_setup_step "$config_file" "$i" "working_dir")
        step_dir="${step_dir:-.}"

        local on_failure
        on_failure=$(get_setup_step "$config_file" "$i" "on_failure")
        on_failure="${on_failure:-abort}"

        local condition
        condition=$(get_setup_step "$config_file" "$i" "condition")

        # Skip if group is in skip list
        local step_group
        step_group=$(get_setup_step "$config_file" "$i" "group")
        if [[ -n "$skip_groups" ]] && [[ -n "$step_group" ]] && [[ "$step_group" != "null" ]]; then
            if _group_in_list "$step_group" "$skip_groups"; then
                continue
            fi
        fi

        ((progress_idx++))

        # Skip if filter provided and doesn't match
        if [[ -n "$step_filter" ]] && [[ "$step_name" != "$step_filter" ]]; then
            continue
        fi

        # Check dependencies
        local deps_met=true
        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | .[]" "$config_file" 2>/dev/null)

        while read -r dep; do
            [[ -z "$dep" ]] && continue
            local found=false
            for c in "${completed[@]}"; do
                if [[ "$c" == "$dep" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                deps_met=false
                break
            fi
        done <<< "$deps"

        if [[ "$deps_met" == "false" ]]; then
            skipped+=("$step_name")
            continue
        fi

        # Check condition (restricted to test/file-check commands)
        if [[ -n "$condition" ]] && [[ "$condition" != "null" ]]; then
            if [[ "$condition" =~ ^(test |!\ test |\[|\[\[) ]]; then
                if ! (cd "$worktree_path" && eval "$condition" &>/dev/null); then
                    skipped+=("$step_name")
                    continue
                fi
            else
                skipped+=("$step_name")
                continue
            fi
        fi

        # Load step-specific environment
        local step_env
        step_env=$(yq -r ".setup[$i].env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

        # Export step environment
        export_env_string "$step_env"

        # Execute command with animated spinner
        local exec_dir="$worktree_path/$step_dir"
        local exit_code=0

        if [[ ! -d "$exec_dir" ]]; then
            echo "Directory not found: $exec_dir" > "$log_file"
            exit_code=1
            _draw_progress "$progress_idx" "$effective_count" "$step_desc..." "running"
        else
            _run_with_spinner "$progress_idx" "$effective_count" "$step_desc..." "$log_file" "$exec_dir" "$step_cmd"
            exit_code=$_RUN_EXIT_CODE
        fi

        if [[ $exit_code -eq 0 ]]; then
            completed+=("$step_name")
            _draw_progress "$progress_idx" "$effective_count" "$step_desc" "done"
        else
            failed+=("$step_name")
            _draw_progress "$progress_idx" "$effective_count" "$step_desc" "fail"
            _finish_progress

            # Dump captured output on failure
            echo "" >&2
            echo -e "${RED}── output from '$step_name' ──${NC}" >&2
            cat "$log_file" >&2
            echo -e "${RED}── end output ──${NC}" >&2

            case "$on_failure" in
                abort)
                    rm -f "$log_file"
                    return 1
                    ;;
                continue)
                    log_warn "Continuing despite failure"
                    # Re-reserve 2 lines for next step
                    printf "\n" >&2
                    ;;
                retry)
                    log_info "Retrying '$step_name'..."
                    # Re-reserve 2 lines
                    printf "\n" >&2
                    _run_with_spinner "$progress_idx" "$effective_count" "$step_desc (retry)..." "$log_file" "$exec_dir" "$step_cmd"
                    if [[ $_RUN_EXIT_CODE -eq 0 ]]; then
                        failed=("${failed[@]/$step_name}")
                        completed+=("$step_name")
                        _draw_progress "$progress_idx" "$effective_count" "$step_desc (retry)" "done"
                    else
                        _draw_progress "$progress_idx" "$effective_count" "$step_desc (retry)" "fail"
                        _finish_progress
                        echo "" >&2
                        echo -e "${RED}── output from '$step_name' (retry) ──${NC}" >&2
                        cat "$log_file" >&2
                        echo -e "${RED}── end output ──${NC}" >&2
                        rm -f "$log_file"
                        return 1
                    fi
                    ;;
            esac
        fi
    done

    # Final state: show completed
    _draw_progress "$effective_count" "$effective_count" "Done" "done"
    _finish_progress

    rm -f "$log_file"

    # Summary
    log_info "Setup: ${#completed[@]} completed${skipped:+, ${#skipped[@]} skipped}${failed:+, ${#failed[@]} failed}"

    if [[ ${#failed[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Run a single setup step by name
run_setup_step() {
    local worktree_path="$1"
    local config_file="$2"
    local step_name="$3"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        if [[ "$name" == "$step_name" ]]; then
            local step_desc
            step_desc=$(get_setup_step "$config_file" "$i" "description")

            local step_cmd
            step_cmd=$(get_setup_step "$config_file" "$i" "command")

            local step_dir
            step_dir=$(get_setup_step "$config_file" "$i" "working_dir")
            step_dir="${step_dir:-.}"

            log_info "Running: $step_desc"

            local exec_dir="$worktree_path/$step_dir"

            if [[ ! -d "$exec_dir" ]]; then
                log_error "Directory not found: $exec_dir"
                return 1
            fi

            # Load step environment
            local step_env
            step_env=$(yq -r ".setup[$i].env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

            export_env_string "$step_env"

            (cd "$exec_dir" && eval "$step_cmd")
            return $?
        fi
    done

    log_error "Setup step not found: $step_name"
    return 1
}

# List all setup steps
list_setup_steps() {
    local config_file="$1"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    echo "Setup steps:"
    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        local desc
        desc=$(get_setup_step "$config_file" "$i" "description")

        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | join(\", \")" "$config_file" 2>/dev/null)

        printf "  %d. ${BOLD}%s${NC}" "$((i + 1))" "$name"
        [[ -n "$desc" ]] && printf " - %s" "$desc"
        [[ -n "$deps" ]] && printf " ${DIM}(depends: %s)${NC}" "$deps"
        echo ""
    done
}

# Validate setup configuration
validate_setup_config() {
    local config_file="$1"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    local errors=0

    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        local cmd
        cmd=$(get_setup_step "$config_file" "$i" "command")

        if [[ -z "$name" ]] || [[ "$name" == "null" ]]; then
            log_error "Setup step $i: missing 'name'"
            ((errors++))
        fi

        if [[ -z "$cmd" ]] || [[ "$cmd" == "null" ]]; then
            log_error "Setup step $i ($name): missing 'command'"
            ((errors++))
        fi

        # Check dependencies exist
        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | .[]" "$config_file" 2>/dev/null)

        while read -r dep; do
            [[ -z "$dep" ]] && continue
            local found=false
            for ((j = 0; j < i; j++)); do
                local other_name
                other_name=$(get_setup_step "$config_file" "$j" "name")
                if [[ "$other_name" == "$dep" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                log_error "Setup step '$name': dependency '$dep' not found or defined after this step"
                ((errors++))
            fi
        done <<< "$deps"
    done

    return $errors
}
