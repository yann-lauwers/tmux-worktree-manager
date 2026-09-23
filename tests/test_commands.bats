#!/usr/bin/env bats
# tests/test_commands.bats - Integration tests for wt commands

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"

    source "$WT_SCRIPT_DIR/commands/init.sh"
    source "$WT_SCRIPT_DIR/commands/config.sh"
    source "$WT_SCRIPT_DIR/commands/list.sh"
    source "$WT_SCRIPT_DIR/commands/smartlist.sh"
    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/health.sh"
    source "$WT_SCRIPT_DIR/commands/ports.sh"
    source "$WT_SCRIPT_DIR/commands/run.sh"
    source "$WT_SCRIPT_DIR/commands/exec.sh"
    source "$WT_SCRIPT_DIR/commands/create.sh"
    source "$WT_SCRIPT_DIR/commands/open.sh"
    source "$WT_SCRIPT_DIR/commands/delete.sh"
    source "$WT_SCRIPT_DIR/commands/start.sh"
    source "$WT_SCRIPT_DIR/commands/stop.sh"
    source "$WT_SCRIPT_DIR/commands/db.sh"
    source "$WT_SCRIPT_DIR/commands/pr.sh"
    source "$WT_SCRIPT_DIR/commands/logs.sh"

    # Create a test git repo
    TEST_REPO="$TEST_TMPDIR/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1
}

teardown() {
    tmux kill-session -t "wt-test-cmd" 2>/dev/null || true
    teardown_test_dirs
}

# Helper: create a standard test project config
_create_test_config() {
    local project="${1:-testproj}"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services:
      web: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services:
  - name: web
    command: echo running
    working_dir: .
    port_key: web
setup:
  - name: touch-marker
    command: touch setup-marker.txt
    working_dir: .
tmux:
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web
        - command: echo shell
hooks:
  post_create: echo post-create-hook-ran"
}

# ===== init command =====

@test "init: shows help with --help" {
    run cmd_init --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Initialize"* ]] || [[ "$output" == *"init"* ]]
}

@test "init: -n is refused as unknown option, naming --name" {
    run cmd_init -n x 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt init: unknown option '-n'"* ]]
    [[ "$output" == *"--name"* ]]
}

@test "init: --name still works" {
    cd "$TEST_REPO"
    run cmd_init --name my-project 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$WT_PROJECTS_DIR/my-project.yaml" ]]
}

# ===== config command =====

@test "config: shows help with --help" {
    run cmd_config --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"config"* ]] || [[ "$output" == *"View"* ]]
}

@test "config: --path returns config file path" {
    _create_test_config "testproj"
    run cmd_config --path -p "testproj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testproj.yaml"* ]]
}

@test "config: displays config content" {
    _create_test_config "testproj"
    run cmd_config -p "testproj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testproj"* ]]
}

# ===== list command =====

@test "list: shows help with --help" {
    run cmd_list --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"list"* ]] || [[ "$output" == *"List"* ]]
}

@test "list: --help shows --status with no -s short form" {
    run cmd_list --help
    [[ "$output" == *"--status"* ]]
    [[ "$output" != *"-s,"* ]]
}

@test "list: shows empty state for new project" {
    _create_test_config "testproj"
    run cmd_list -p "testproj" 2>&1
    [[ "$status" -eq 0 ]]
}

@test "list: shows worktrees after creating state" {
    _create_test_config "testproj"
    create_worktree_state "testproj" "feature/test" "$TEST_REPO/.worktrees/feature-test" 0
    run cmd_list -p "testproj" 2>&1
    [[ "$output" == *"feature"* ]]
}

@test "list: --json produces valid output" {
    _create_test_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    run cmd_list -p "testproj" --json 2>&1
    [[ "$status" -eq 0 ]]
    # Should contain JSON array bracket
    [[ "$output" == *"["* ]]
}

@test "list: -s is refused as unknown option, naming --status" {
    run cmd_list -s 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt list: unknown option '-s'"* ]]
    [[ "$output" == *"--status"* ]]
}

@test "list: -s with a value is refused the same way" {
    run cmd_list -s running 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt list: unknown option '-s'"* ]]
    [[ "$output" == *"--status"* ]]
}

@test "list: --status prints the session and dirty-tree columns" {
    _create_test_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    run cmd_list -p "testproj" --status 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SESSION"* ]]
    [[ "$output" == *"STATUS"* ]]
}

# ===== ls command =====

@test "ls: shows help with --help" {
    run cmd_smartlist --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PR status"* ]]
}

@test "ls: --help shows neither -s nor --status" {
    run cmd_smartlist --help
    [[ "$output" != *"-s,"* ]]
    [[ "$output" != *"--status"* ]]
}

@test "ls: -s is refused as unknown option, naming -q" {
    run cmd_smartlist -s 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt ls: unknown option '-s'"* ]]
    [[ "$output" == *"-q"* ]]
    [[ "$output" == *"PR status"* ]]
}

@test "ls: --status is refused the same way" {
    run cmd_smartlist --status 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt ls: unknown option '--status'"* ]]
    [[ "$output" == *"-q"* ]]
    [[ "$output" == *"PR status"* ]]
}

@test "ls -q: skips the PR-status lookup and exits 0 with no worktrees" {
    run cmd_smartlist -q 2>&1
    [[ "$status" -eq 0 ]]
}

# ===== ports command =====

@test "ports: shows help with --help" {
    run cmd_ports --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"port"* ]] || [[ "$output" == *"Port"* ]]
}

@test "ports: shows port assignments" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    run cmd_ports -p "testproj" "main" 2>&1
    [[ "$output" == *"web"* ]] || [[ "$output" == *"3000"* ]]
}

@test "ports: auto-detects branch from current git branch" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    cd "$TEST_REPO"
    run cmd_ports -p "testproj" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Using current branch"* ]]
    [[ "$output" == *"web"* ]] || [[ "$output" == *"3000"* ]]
}

@test "ports: set subcommand creates override" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    # Subcommand must come before -p flag (cmd_ports checks $1 for subcommand)
    run cmd_ports set -p "testproj" web 9999 main 2>&1
    [[ "$status" -eq 0 ]]
    result=$(get_port_override "testproj" "main" "web")
    [[ "$result" == "9999" ]]
}

@test "ports: clear subcommand removes override" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    set_port_override "testproj" "main" "web" 9999
    # Subcommand must come before -p flag
    run cmd_ports clear -p "testproj" web main 2>&1
    [[ "$status" -eq 0 ]]
    result=$(get_port_override "testproj" "main" "web")
    [[ "$result" == "" ]]
}

# ===== status command =====

@test "status: shows help with --help" {
    run cmd_status --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"status"* ]] || [[ "$output" == *"Status"* ]]
}

@test "status: shows worktree info" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Create actual worktree (cmd_status checks worktree_exists)
    cd "$TEST_REPO"
    local wt_path
    wt_path=$(create_worktree "feature/status-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/status-test" "$wt_path" 0
    claim_slot "testproj" "feature/status-test" 3

    run cmd_status -p "testproj" "feature/status-test" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"feature/status-test"* ]]
}

@test "status: --services is refused, naming the default" {
    run cmd_status --services 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt status: unknown option '--services'"* ]]
    [[ "$output" == *"shown by default"* ]]
}

@test "status: no flag shows the standalone Ports section for a project with no services" {
    create_yaml_fixture "$WT_PROJECTS_DIR/noservicesproj.yaml" "name: noservicesproj
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []
tmux:
  session: wt-test-cmd-noservices
  layout: tiled
  windows:
    - name: shell
      panes:
        - command: echo shell"
    load_project_config "noservicesproj"

    cd "$TEST_REPO"
    local wt_path
    wt_path=$(create_worktree "feature/status-noservices" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "noservicesproj" "feature/status-noservices" "$wt_path" 0
    claim_slot "noservicesproj" "feature/status-noservices" 3

    run cmd_status -p "noservicesproj" "feature/status-noservices" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ports"* ]]
}

@test "status: no flag shows the service table for a project with services" {
    _create_test_config "svcproj"
    load_project_config "svcproj"

    cd "$TEST_REPO"
    local wt_path
    wt_path=$(create_worktree "feature/status-services" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "svcproj" "feature/status-services" "$wt_path" 0
    claim_slot "svcproj" "feature/status-services" 3

    run cmd_status -p "svcproj" "feature/status-services" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"web"* ]]
    [[ "$output" != *"Ports"* ]]
}

# ===== logs command =====

@test "logs: -n behaves as --lines (unchanged)" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local log_dir="$WT_DATA_DIR/logs/testproj"
    mkdir -p "$log_dir"
    local log_file="$log_dir/feature-logs-test-web.log"
    seq 1 20 > "$log_file"

    run cmd_logs -p "testproj" "feature/logs-test" "web" -n 5
    [[ "$status" -eq 0 ]]
    local n_output="$output"

    run cmd_logs -p "testproj" "feature/logs-test" "web" --lines 5
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$n_output" ]]
    [[ "$output" == *"16"$'\n'"17"$'\n'"18"$'\n'"19"$'\n'"20"* ]]
}

# ===== start command =====

@test "start: shows help with --help" {
    run cmd_start --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"start"* ]] || [[ "$output" == *"Start"* ]]
}

@test "start: -s is still --service, not an unknown option" {
    run cmd_start -s 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt start: option -s requires an argument"* ]]
    [[ "$output" != *"unknown option"* ]]
}

# ===== stop command =====

@test "stop: shows help with --help" {
    run cmd_stop --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stop"* ]] || [[ "$output" == *"Stop"* ]]
}

@test "stop: -s is still --service, not an unknown option" {
    run cmd_stop -s 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt stop: option -s requires an argument"* ]]
    [[ "$output" != *"unknown option"* ]]
}

# ===== run command =====

@test "run: shows help with --help" {
    run cmd_run --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run"* ]] || [[ "$output" == *"Run"* ]]
}

# ===== exec command =====

@test "exec: shows help with --help" {
    run cmd_exec --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"exec"* ]] || [[ "$output" == *"Execute"* ]]
}

@test "exec: runs command in worktree dir" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Create actual worktree
    local wt_path
    wt_path=$(create_worktree "feature/exec-cmd" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/exec-cmd" "$wt_path" 0
    claim_slot "testproj" "feature/exec-cmd" 3

    run cmd_exec -p "testproj" "feature/exec-cmd" pwd 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *".worktrees/feature-exec-cmd"* ]]
}

@test "exec: --help after the branch reaches the wrapped command, not wt's own help" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/exec-help" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/exec-help" "$wt_path" 0
    claim_slot "testproj" "feature/exec-help" 3

    run cmd_exec -p "testproj" "feature/exec-help" echo --help 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == "--help" ]]
}

# ===== create + delete lifecycle =====

@test "create+delete: full lifecycle without tmux" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # We can't fully test create/delete commands as they require tmux,
    # but we can verify the underlying operations work together

    # Simulate create: worktree + state + slot
    local wt_path
    wt_path=$(create_worktree "feature/lifecycle" "" "$TEST_REPO" 2>/dev/null)
    [[ -d "$wt_path" ]]

    local slot
    slot=$(claim_slot "testproj" "feature/lifecycle" 3)
    [[ "$slot" == "0" ]]

    create_worktree_state "testproj" "feature/lifecycle" "$wt_path" "$slot"

    # Verify state
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "path")" == "$wt_path" ]]
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "slot")" == "0" ]]

    # Simulate delete: remove worktree + release slot + delete state
    remove_worktree "feature/lifecycle" 0 0 "$TEST_REPO" >/dev/null 2>&1
    release_slot "testproj" "feature/lifecycle"
    delete_worktree_state "testproj" "feature/lifecycle"

    # Verify cleanup
    ! worktree_exists "feature/lifecycle" "$TEST_REPO"
    [[ "$(get_slot_for_worktree "testproj" "feature/lifecycle")" == "" ]]
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "path")" == "" ]]
}

@test "delete: releases slot when worktree directory is missing" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Simulate a worktree that was created but whose directory was removed externally
    local wt_path
    wt_path=$(create_worktree "feature/orphaned" "" "$TEST_REPO" 2>/dev/null)
    local slot
    slot=$(claim_slot "testproj" "feature/orphaned" 3)
    create_worktree_state "testproj" "feature/orphaned" "$wt_path" "$slot"

    # Manually remove the worktree directory (simulating external deletion)
    rm -rf "$wt_path"
    git -C "$TEST_REPO" worktree prune 2>/dev/null

    # Verify slot is still claimed
    [[ "$(get_slot_for_worktree "testproj" "feature/orphaned")" == "$slot" ]]

    # Simulate what cmd_delete does: detect missing dir, still clean up slot + state
    release_slot "testproj" "feature/orphaned"
    delete_worktree_state "testproj" "feature/orphaned"

    # Verify slot is freed and state is cleaned
    [[ "$(get_slot_for_worktree "testproj" "feature/orphaned")" == "" ]]
    [[ "$(get_worktree_state "testproj" "feature/orphaned" "path")" == "" ]]

    # Verify the slot can be reused
    local new_slot
    new_slot=$(claim_slot "testproj" "feature/reuse" 3)
    [[ "$new_slot" == "$slot" ]]
}

@test "delete: dies with no state and no directory" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Branch has no worktree, no state, no slot — should fail
    run bash -c '
        source "$WT_SCRIPT_DIR/lib/utils.sh"
        source "$WT_SCRIPT_DIR/lib/config.sh"
        source "$WT_SCRIPT_DIR/lib/port.sh"
        source "$WT_SCRIPT_DIR/lib/state.sh"
        source "$WT_SCRIPT_DIR/lib/worktree.sh"
        source "$WT_SCRIPT_DIR/lib/setup.sh"
        source "$WT_SCRIPT_DIR/lib/tmux.sh"
        source "$WT_SCRIPT_DIR/lib/service.sh"
        source "$WT_SCRIPT_DIR/commands/delete.sh"
        export WT_STATE_DIR="'"$WT_STATE_DIR"'"
        export WT_PROJECTS_DIR="'"$WT_PROJECTS_DIR"'"
        cmd_delete -f -p testproj "feature/nonexistent"
    '
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no worktree for branch"* ]]
}

@test "delete: cleans up orphaned slot when directory missing" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Claim all slots
    claim_slot "testproj" "feature/a" 2
    claim_slot "testproj" "feature/b" 2
    create_worktree_state "testproj" "feature/a" "/nonexistent/path/a" 0
    create_worktree_state "testproj" "feature/b" "/nonexistent/path/b" 1

    # No more slots available
    run claim_slot "testproj" "feature/c" 2
    [[ "$status" -ne 0 ]]

    # Release one orphaned slot
    release_slot "testproj" "feature/a"
    delete_worktree_state "testproj" "feature/a"

    # Now a slot should be available
    local new_slot
    new_slot=$(claim_slot "testproj" "feature/c" 2)
    [[ "$new_slot" == "0" ]]
}

@test "delete: cmd_delete -f removes both the state entry and the slot for an orphaned worktree" {
    _create_test_config "testproj"
    load_project_config "testproj"

    claim_slot "testproj" "feature/orphan-direct" 3
    create_worktree_state "testproj" "feature/orphan-direct" "/nonexistent/path/orphan-direct" 0

    run cmd_delete -f -p "testproj" "feature/orphan-direct"
    [[ "$status" -eq 0 ]]

    [[ "$(get_worktree_state "testproj" "feature/orphan-direct" "path")" == "" ]]
    [[ "$(get_slot_for_worktree "testproj" "feature/orphan-direct")" == "" ]]
}

# ===== exec with port env vars =====

@test "exec: exports port variables" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/env-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/env-test" "$wt_path" 0
    claim_slot "testproj" "feature/env-test" 3

    run cmd_exec -p "testproj" "feature/env-test" env 2>&1
    [[ "$output" == *"PORT_WEB="* ]]
}

# ===== setup execution =====

@test "run: executes named setup step" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/run-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/run-test" "$wt_path" 0
    claim_slot "testproj" "feature/run-test" 3

    run cmd_run -p "testproj" "feature/run-test" "touch-marker" 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$wt_path/setup-marker.txt" ]]
}

@test "run: fails for nonexistent step" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/run-fail" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/run-fail" "$wt_path" 0
    claim_slot "testproj" "feature/run-fail" 3

    run cmd_run -p "testproj" "feature/run-fail" "nonexistent-step" 2>&1
    [[ "$status" -ne 0 ]]
}

# ===== multiple worktrees =====

@test "lifecycle: multiple worktrees with different slots" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt1 wt2
    wt1=$(create_worktree "feature/multi-a" "" "$TEST_REPO" 2>/dev/null)
    wt2=$(create_worktree "feature/multi-b" "" "$TEST_REPO" 2>/dev/null)

    local slot1 slot2
    slot1=$(claim_slot "testproj" "feature/multi-a" 3)
    slot2=$(claim_slot "testproj" "feature/multi-b" 3)

    [[ "$slot1" == "0" ]]
    [[ "$slot2" == "1" ]]

    create_worktree_state "testproj" "feature/multi-a" "$wt1" "$slot1"
    create_worktree_state "testproj" "feature/multi-b" "$wt2" "$slot2"

    # Different slots = different ports
    local port1 port2
    port1=$(get_service_port "web" "feature/multi-a" "$WT_PROJECTS_DIR/testproj.yaml" "$slot1")
    port2=$(get_service_port "web" "feature/multi-b" "$WT_PROJECTS_DIR/testproj.yaml" "$slot2")

    # services_per_slot defaults to 2, so slot 0 -> 3000, slot 1 -> 3002
    [[ "$port1" == "3000" ]]
    [[ "$port2" == "3002" ]]
    [[ "$port1" != "$port2" ]]
}

# ===== lifecycle hooks =====

# Helper: create config with all hooks that write marker files
_create_hooks_config() {
    local project="${1:-hookproj}"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services:
      web: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services:
  - name: web
    command: echo running
    working_dir: .
    port_key: web
setup: []
tmux:
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web
        - command: echo shell
hooks:
  pre_create: touch $TEST_TMPDIR/pre-create-marker
  post_create: touch $TEST_TMPDIR/post-create-marker
  pre_start: touch $TEST_TMPDIR/pre-start-marker
  post_start: touch $TEST_TMPDIR/post-start-marker
  post_stop: touch $TEST_TMPDIR/post-stop-marker
  pre_delete: touch $TEST_TMPDIR/pre-delete-marker
  post_delete: touch $TEST_TMPDIR/post-delete-marker"
}

@test "hooks: pre_create runs before worktree creation" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    [[ -f "$TEST_TMPDIR/pre-create-marker" ]]
}

@test "hooks: post_create runs after worktree creation" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_create"

    [[ -f "$TEST_TMPDIR/post-create-marker" ]]
}

@test "hooks: pre_start runs before services start" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "pre_start"

    [[ -f "$TEST_TMPDIR/pre-start-marker" ]]
}

@test "hooks: post_start runs after services start" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_start"

    [[ -f "$TEST_TMPDIR/post-start-marker" ]]
}

@test "hooks: post_stop runs after services stop" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    run_hook "$PROJECT_CONFIG_FILE" "post_stop"

    [[ -f "$TEST_TMPDIR/post-stop-marker" ]]
}

@test "hooks: pre_delete runs before worktree deletion" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "pre_delete"

    [[ -f "$TEST_TMPDIR/pre-delete-marker" ]]
}

@test "hooks: post_delete runs after worktree deletion" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_delete"

    [[ -f "$TEST_TMPDIR/post-delete-marker" ]]
}

@test "hooks: pre_create has BRANCH_NAME in environment" {
    local marker="$TEST_TMPDIR/branch-env-marker"
    local project="hookenvproj"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []
setup: []
tmux:
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - command: ''
hooks:
  pre_create: echo \$BRANCH_NAME > $marker"

    load_project_config "$project"
    export BRANCH_NAME="feature/env-check"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    [[ -f "$marker" ]]
    [[ "$(cat "$marker")" == "feature/env-check" ]]
}

# ===== health command =====

@test "health: shows help with --help" {
    run cmd_health --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"health"* ]] || [[ "$output" == *"Health"* ]]
}

@test "health: rejects an unknown option" {
    run cmd_health --nope
    [[ "$status" -eq 2 ]]
}

# Regression: a checkout wt does not manage has no slot and no services, so
# probing it would mean probing another worktree's ports. Must fail, not guess.
@test "health: exits 1 for a branch with no worktree" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run cmd_health -p "testproj" "feature/never-created"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no worktree for branch"* ]]
}

# ===== ports: unmanaged-branch regression =====

# Regression: `wt ports` used to fall back to slot 0 — a real, in-use slot — for
# any branch it did not know, printing another worktree's ports and exiting 0.
@test "ports: exits 1 for a branch with no worktree" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run cmd_ports -p "testproj" "feature/never-created"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no worktree for branch"* ]]
}

# ===== create/open/db: canonical naming and usage-error contract =====

@test "create: unknown option stderr names 'wt create:', not 'wt c:'" {
    run cmd_create --bogus 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt create: unknown option"* ]]
    [[ "$output" != *"wt c:"* ]]
}

@test "open: unknown option stderr names 'wt open:', not 'wt o:'" {
    run cmd_open --bogus 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt open: unknown option"* ]]
    [[ "$output" != *"wt o:"* ]]
}

@test "open: -a is refused, naming the default" {
    run cmd_open -a 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt open: unknown option '-a'"* ]]
    [[ "$output" == *"omit it"* ]]
}

@test "open: --all is refused the same way" {
    run cmd_open --all 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt open: unknown option '--all'"* ]]
    [[ "$output" == *"omit it"* ]]
}

@test "delete -p with no value: standard usage line, exit 2, names 'wt delete:'" {
    run cmd_delete -p 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt delete: option -p requires an argument"* ]]
    [[ "$output" == *"see 'wt delete --help'"* ]]
}

@test "rm --project with no value: standard usage line, exit 2, names 'wt rm:'" {
    WT_CMD_NAME="rm" run cmd_delete --project 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt rm: option --project requires an argument"* ]]
    [[ "$output" == *"see 'wt rm --help'"* ]]
}

@test "prune -p with no value: standard usage line, exit 2, names 'wt prune:'" {
    WT_CMD_NAME="prune" run cmd_delete -p 2>&1
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt prune: option -p requires an argument"* ]]
    [[ "$output" == *"see 'wt prune --help'"* ]]
}

@test "db url: --help prints no URL and exits 0" {
    run cmd_db_url --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Prints the database connection URL"* ]]
    [[ "$output" != *"postgres://"* ]]
}

@test "db: no subcommand exits 2" {
    run cmd_db
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt db: missing subcommand"* ]]
}

# ===== wt help <command> ================================================
# 'wt help <command>' opens that command's own --help page through the
# existing help path (main() rewrites it to '<command> --help' before
# dispatch), so every assertion below runs the real wt.sh entry point.

@test "help: every dispatched command word (canonical and alias), create and delete among them, matches 'wt <word> --help' byte for byte (C1, C2)" {
    load help_surface
    local checked=0 seen=""
    while IFS='|' read -r kind _invoke display _flags _subwords; do
        [[ "$kind" != "COMMAND" ]] && continue
        local word
        IFS=',' read -ra words <<< "$display"
        for word in "${words[@]}"; do
            run "$WT_SCRIPT_DIR/wt.sh" help "$word"
            local help_status="$status" help_output="$output"
            run "$WT_SCRIPT_DIR/wt.sh" "$word" --help
            [[ "$help_status" -eq 0 ]]
            [[ "$status" -eq 0 ]]
            [[ "$help_output" == "$output" ]]
            checked=$((checked + 1))
            seen+=" $word"
        done
    done < <(_wt_build_units "$WT_SCRIPT_DIR")
    [[ "$checked" -gt 0 ]]
    # The ticket names create and delete; the sweep has to have reached both.
    [[ "$seen " == *" create "* && "$seen " == *" delete "* ]]
}

@test "help: 'wt help <command>' works with yq and tmux absent, like --help (C3)" {
    load help_surface
    local shim home_dir
    shim="$TEST_TMPDIR/help-shim"
    home_dir="$TEST_TMPDIR/help-home"
    mkdir -p "$home_dir"
    _wt_build_help_shim "$shim"

    local out="$TEST_TMPDIR/help-out.txt"
    _wt_run_help_probe "$WT_SCRIPT_DIR" "$shim" "$home_dir" "$out" help create
    [[ "$?" -eq 0 ]]
    run cat "$out"
    [[ "$output" == *"Usage: wt create"* ]]

    local created
    created=$(find "$home_dir" -mindepth 1 2>/dev/null | wc -l)
    [[ "$created" -eq 0 ]]
}

@test "help: 'wt help bogus' exits 2, empty stdout, one stderr line naming the unknown command (C4)" {
    run --separate-stderr "$WT_SCRIPT_DIR/wt.sh" help bogus
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt: unknown command 'bogus' — see 'wt --help'" ]]
}

@test "help: 'wt help' alone prints the top-level page, exit 0 (C5)" {
    run "$WT_SCRIPT_DIR/wt.sh" help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage: wt <command>"* ]]
    [[ "$output" == *"Commands:"* ]]
}

@test "help: 'wt help help' and 'wt help --help' land on the top-level page (C5)" {
    run "$WT_SCRIPT_DIR/wt.sh" help help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage: wt <command>"* ]]

    run "$WT_SCRIPT_DIR/wt.sh" help --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Usage: wt <command>"* ]]
}

@test "help: 'wt help db reset' (extra words) exits 2, empty stdout, die_usage line on stderr" {
    run --separate-stderr "$WT_SCRIPT_DIR/wt.sh" help db reset
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt help: takes one command name — for a subcommand's page run 'wt <command> <subcommand> --help' — see 'wt help --help'"$'\n'"usage: wt help <command>" ]]
}

@test "wt --help lists 'help <command>' as opening one command's page (C6)" {
    run "$WT_SCRIPT_DIR/wt.sh" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"  help <command>   Show one command's page"* ]]
}

@test "bare 'wt' short usage mentions 'wt help <command>' (C7)" {
    run "$WT_SCRIPT_DIR/wt.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"wt help <command>"* ]]
}

# ===== C8: already-shipped usage errors keep their wording end to end =====

@test "wt bogus: unknown command, exit 2, empty stdout, one stderr line, nothing written to disk, holds with fzf absent from PATH (C8)" {
    local shim home_dir
    shim="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    build_no_fzf_shim "$shim"

    run --separate-stderr env -i HOME="$home_dir" PATH="$shim" \
        WT_CONFIG_DIR="$home_dir/config" WT_DATA_DIR="$home_dir/data" \
        "$WT_SCRIPT_DIR/wt.sh" bogus
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt: unknown command 'bogus' — see 'wt --help'" ]]
    [[ ! -e "$home_dir/config" ]]
    [[ ! -e "$home_dir/data" ]]
}

@test "wt db bogus: unknown subcommand, exit 2, empty stdout, stderr names 'wt db --help' (C8)" {
    WT_WARN_DEPS=false run --separate-stderr "$WT_SCRIPT_DIR/wt.sh" db bogus
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt db: unknown subcommand 'bogus' — see 'wt db --help'" ]]
}

@test "bare wt db: missing subcommand, exit 2, empty stdout, usage line on stderr (C8)" {
    WT_WARN_DEPS=false run --separate-stderr "$WT_SCRIPT_DIR/wt.sh" db
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt db: missing subcommand — see 'wt db --help'"$'\n'"usage: wt db <reset|url|dump|use-remote> [options]" ]]
}

@test "wt create --bogus: unknown option, exit 2, empty stdout, stderr names 'wt create:' (C8)" {
    run --separate-stderr "$WT_SCRIPT_DIR/wt.sh" create --bogus
    [[ "$status" -eq 2 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == *"wt create: unknown option '--bogus'"* ]]
    [[ "$stderr" == *"see 'wt create --help'"* ]]
}

# ===== C9: 'wt ports <word>' / 'wt pr <word>' still read a bogus word as a
# branch name, never as an unknown subcommand — the help routing above only
# fires on the literal command word 'help'. =====

@test "ports: a bogus word is read as a branch name, not an unknown subcommand (C9)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run cmd_ports -p "testproj" "nosuchbranch" 2>&1
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no worktree for branch 'nosuchbranch'"* ]]
    [[ "$output" != *"unknown subcommand"* ]]
}

@test "pr: a bogus word is read as a branch name, not an unknown subcommand (C9)" {
    stub_gh "exit 1"

    run cmd_pr "nosuchbranch" 2>&1
    [[ "$output" == *"No PR found for branch: nosuchbranch"* ]]
    [[ "$output" != *"unknown subcommand"* ]]
}
