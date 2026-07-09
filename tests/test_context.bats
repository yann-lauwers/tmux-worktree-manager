#!/usr/bin/env bats
# tests/test_context.bats - Unit tests for lib/context.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "tmux"
    load_lib "context"

    # Test git repo
    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1

    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj
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
env:
  API_TOKEN: secret-123"

    # A real worktree + its slot-0 state, so resolution has something to find
    create_worktree "feature/ctx" "" "$TEST_REPO" >/dev/null 2>&1
    create_worktree_state "testproj" "feature/ctx" "$TEST_REPO/.worktrees/feature-ctx" 0
}

teardown() {
    teardown_test_dirs
}

# --- resolve_worktree_context ---

@test "resolve_worktree_context sets WT_CTX_* for an existing worktree" {
    resolve_worktree_context "feature/ctx" "testproj"
    [[ "$WT_CTX_PROJECT" == "testproj" ]]
    [[ "$WT_CTX_BRANCH" == "feature/ctx" ]]
    [[ "$WT_CTX_PATH" == *".worktrees/feature-ctx" ]]
    [[ "$WT_CTX_SLOT" == "0" ]]
}

@test "resolve_worktree_context loads PROJECT_* globals" {
    resolve_worktree_context "feature/ctx" "testproj"
    [[ "$PROJECT_NAME" == "testproj" ]]
    [[ "$PROJECT_REPO_PATH" == "$TEST_REPO" ]]
    [[ "$PROJECT_CONFIG_FILE" == *"testproj.yaml" ]]
}

@test "resolve_worktree_context dies for a missing worktree" {
    run resolve_worktree_context "feature/does-not-exist" "testproj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Worktree not found"* ]]
}

# --- export_worktree_env ---

@test "export_worktree_env exports PORT_<service> for the slot" {
    resolve_worktree_context "feature/ctx" "testproj"
    export_worktree_env
    # slot 0, web offset 0, base 3000 -> 3000
    [[ "$PORT_WEB" == "3000" ]]
}

@test "export_worktree_env exports WORKTREE_PATH and BRANCH_NAME" {
    resolve_worktree_context "feature/ctx" "testproj"
    export_worktree_env
    [[ "$WORKTREE_PATH" == *".worktrees/feature-ctx" ]]
    [[ "$BRANCH_NAME" == "feature/ctx" ]]
}

@test "export_worktree_env exports project env vars" {
    resolve_worktree_context "feature/ctx" "testproj"
    export_worktree_env
    [[ "$API_TOKEN" == "secret-123" ]]
}

@test "export_worktree_env honors a per-worktree port override" {
    # This is the behavior that changed: exec/run now pass the project arg, so an
    # override wins over the calculated port (was silently skipped before).
    set_port_override "testproj" "feature/ctx" "web" "9999"
    resolve_worktree_context "feature/ctx" "testproj"
    export_worktree_env
    [[ "$PORT_WEB" == "9999" ]]
}

# --- resolve_tmux_context ---
# Happy path needs a live tmux server (session + window created); it is exercised
# by the command-level e2e/panes/logs/send suites. Here we cover the die path.

@test "resolve_tmux_context dies when the tmux session/window does not exist" {
    run resolve_tmux_context "feature/ctx" "testproj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

# --- synth_main_root_context ---

@test "synth_main_root_context sets a slot-0 main context" {
    cd "$TEST_REPO"
    synth_main_root_context
    [[ "$WT_CTX_SLOT" == "0" ]]
    [[ "$WT_CTX_MAIN" == "1" ]]
    [[ "$WT_CTX_PATH" == "$TEST_REPO" ]]
    [[ "$WT_CTX_BRANCH" == "main" ]]
    [[ "$WT_MAIN_CONTEXT" == "1" ]]
    [[ "$WT_ROOT_WORKTREE_PATH" == "$TEST_REPO" ]]
    [[ "$WT_ROOT_SLOT" == "0" ]]
}
