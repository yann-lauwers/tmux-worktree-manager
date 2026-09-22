#!/usr/bin/env bats
# tests/test_readonly.bats - `wt list` / `wt status` / `wt health` / `wt doctor`
# read state and leave it byte-identical; `wt create` and `wt delete` are the
# only commands that reclaim a stale entry.

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

    source "$WT_SCRIPT_DIR/commands/list.sh"
    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/health.sh"
    source "$WT_SCRIPT_DIR/commands/doctor.sh"
    source "$WT_SCRIPT_DIR/commands/create.sh"
    source "$WT_SCRIPT_DIR/commands/delete.sh"

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
    teardown_test_dirs
}

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
tmux:
  session: wt-test-readonly
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web"
}

# Seed one stale entry: a slot claimed and a state entry whose directory is
# missing. Any read command must leave both the state file and the slots
# file exactly as this leaves them.
_seed_stale_entry() {
    local project="$1"
    local branch="${2:-feature/gone}"

    load_project_config "$project"
    claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS" "$PROJECT_RESERVED_PORT_MIN" 1
    create_worktree_state "$project" "$branch" "/nonexistent/path/for/$branch" 0
}

_state_hash() {
    local project="$1"
    shasum -a 256 "$(state_file "$project")" 2>/dev/null | awk '{print $1}'
}

_slots_hash() {
    shasum -a 256 "$(slots_file)" 2>/dev/null | awk '{print $1}'
}

# Seed a live worktree beside the stale entry, so status/health have a target.
# Args: $1 project, $2 branch
_seed_live_worktree() {
    local project="$1"
    local branch="$2"

    load_project_config "$project"
    local wt_path slot
    wt_path=$(create_worktree "$branch" "" "$TEST_REPO" 2>/dev/null)
    slot=$(claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS" "$PROJECT_RESERVED_PORT_MIN" 1)
    create_worktree_state "$project" "$branch" "$wt_path" "$slot"
}

# Run a read command and assert it left both files byte-identical and the
# stale entry's slot allocated.
# Args: $@ the command and its arguments
_assert_readonly() {
    local before_state before_slots
    before_state=$(_state_hash "testproj")
    before_slots=$(_slots_hash)

    run "$@"

    [[ "$(_state_hash "testproj")" == "$before_state" ]]
    [[ "$(_slots_hash)" == "$before_slots" ]]
    [[ "$(get_slot_for_worktree "testproj" "feature/gone")" == "0" ]]
}

# ===== C1 / C2: list, status, health, doctor never write =====

@test "list: leaves state and slots byte-identical with a stale entry present" {
    _create_test_config "testproj"
    _seed_stale_entry "testproj"

    _assert_readonly cmd_list -p "testproj"
    [[ "$status" -eq 0 ]]
}

@test "status: leaves state and slots byte-identical, including an unrelated stale entry" {
    _create_test_config "testproj"
    _seed_stale_entry "testproj"
    _seed_live_worktree "testproj" "feature/live"

    _assert_readonly cmd_status -p "testproj" "feature/live"
    [[ "$status" -eq 0 ]]
}

@test "health: leaves state and slots byte-identical, including an unrelated stale entry" {
    _create_test_config "testproj"
    _seed_stale_entry "testproj"
    _seed_live_worktree "testproj" "feature/live"

    _assert_readonly cmd_health -p "testproj" "feature/live"
}

@test "doctor: leaves state and slots byte-identical with a stale entry present" {
    _create_test_config "testproj"
    _seed_stale_entry "testproj"

    _assert_readonly cmd_doctor -p "testproj"
}

# ===== C3: a dead-PID service reads as stopped, and nothing is written =====

@test "status: shows a dead-PID service as stopped without rewriting its record" {
    _create_test_config "testproj"
    _seed_live_worktree "testproj" "feature/live"
    # A PID guaranteed not to be running, recorded as "running".
    set_service_state "testproj" "feature/live" "web" "status" "running"
    set_service_state "testproj" "feature/live" "web" "pid" "999999"

    local before_state
    before_state=$(_state_hash "testproj")

    run cmd_status -p "testproj" "feature/live" --services
    [[ "$output" == *"stopped"* ]]

    # The state file is unchanged — the display computed "stopped" at read time.
    [[ "$(_state_hash "testproj")" == "$before_state" ]]
    [[ "$(get_service_state "testproj" "feature/live" "web" "status")" == "running" ]]
}

# ===== C7: create reclaims a stale entry's slot only on exhaustion =====

@test "claim_slot_reclaiming: reclaims a stale entry's slot when every slot is taken" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Fill every slot (max 3); slot 0 belongs to a worktree whose directory is gone.
    claim_slot "testproj" "feature/a" 3
    create_worktree_state "testproj" "feature/a" "/nonexistent/path/a" 0
    claim_slot "testproj" "feature/b" 3
    create_worktree_state "testproj" "feature/b" "$TEST_REPO" 1
    claim_slot "testproj" "feature/c" 3
    create_worktree_state "testproj" "feature/c" "$TEST_REPO" 2

    run --separate-stderr claim_slot_reclaiming "testproj" "feature/new" 3 "" 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == "0" ]]

    # The stale entry is gone from both state and slots.
    [[ "$(get_slot_for_worktree "testproj" "feature/a")" == "" ]]
    [[ "$(get_worktree_state "testproj" "feature/a" "path")" == "" ]]
}

@test "claim_slot_reclaiming: leaves a stale entry untouched when a free slot exists" {
    _create_test_config "testproj"
    load_project_config "testproj"

    claim_slot "testproj" "feature/a" 3
    create_worktree_state "testproj" "feature/a" "/nonexistent/path/a" 0

    run --separate-stderr claim_slot_reclaiming "testproj" "feature/new" 3 "" 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == "1" ]]

    # The stale entry is untouched — a free slot meant reclaim never ran.
    [[ "$(get_slot_for_worktree "testproj" "feature/a")" == "0" ]]
    [[ "$(get_worktree_state "testproj" "feature/a" "path")" == "/nonexistent/path/a" ]]
}

# ===== C8: each read/write command's --help states whether it writes state =====

@test "help pages state whether the command writes state" {
    run cmd_list --help
    [[ "$output" == *"Reads state only"* ]]

    run cmd_status --help
    [[ "$output" == *"Reads state only"* ]]

    run cmd_health --help
    [[ "$output" == *"Reads state only"* ]]

    run cmd_doctor --help
    [[ "$output" == *"Reads state only"* ]]

    run cmd_create --help
    [[ "$output" == *"Writes state"* ]]

    run cmd_delete --help
    [[ "$output" == *"Writes state"* ]]
}
