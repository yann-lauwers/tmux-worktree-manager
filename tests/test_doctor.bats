#!/usr/bin/env bats
# tests/test_doctor.bats - Integration tests for wt doctor command

load test_helper

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
    source "$WT_SCRIPT_DIR/commands/doctor.sh"
}

teardown() {
    teardown_test_dirs
}

# --- Dependency checks ---

@test "doctor passes dependency checks" {
    run cmd_doctor -p nonexistent 2>&1
    # Should at least check dependencies without crashing
    [[ "$output" == *"Dependencies"* ]]
}

@test "doctor detects git" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"git"* ]]
    [[ "$output" == *"PASS"* ]]
}

@test "doctor detects yq" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"yq"* ]]
}

# --- Config validation ---

@test "doctor validates valid YAML config" {
    local project="testproj"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: testproj
repo_path: /tmp/fake-repo
ports:
  reserved:
    range:
      min: 3000
      max: 3010
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    mkdir -p /tmp/fake-repo

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"YAML syntax is valid"* ]]
    [[ "$output" == *"repo_path is set"* ]]

    rmdir /tmp/fake-repo 2>/dev/null || true
}

@test "doctor detects invalid port range" {
    local project="badports"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: badports
repo_path: /tmp
ports:
  reserved:
    range:
      min: 5000
      max: 3000
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"Invalid"* ]]
}

@test "doctor detects overlapping port ranges" {
    local project="overlap"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: overlap
repo_path: /tmp
ports:
  reserved:
    range:
      min: 3000
      max: 4500
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"overlap"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "doctor detects missing config" {
    run cmd_doctor -p "nonexistent_project_xyz" 2>&1
    [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"WARN"* ]]
}

# --- State consistency ---

@test "doctor detects orphaned worktree state" {
    local project="statetest"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: statetest
repo_path: /tmp
services: []"

    create_worktree_state "$project" "feature/gone" "/tmp/nonexistent-path-xyz" 0

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"Orphaned"* ]] || [[ "$output" == *"WARN"* ]]
}

@test "doctor flags a slotless, pathless state entry as orphaned" {
    local project="stubstate"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: stubstate
repo_path: $TEST_TMPDIR
services: []"

    # The shape a manually removed worktree leaves behind: services, nothing else.
    create_yaml_fixture "$WT_STATE_DIR/${project}.state.yaml" "worktrees:
  feat-gone:
    services:
      frontend:
        status: stopped
        pid: null"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"Orphaned worktree state: feat-gone"* ]]
}

# --- Port conflicts: a non-slot entry must not be scored as slot 0 ---

@test "doctor does not read a slotless state entry as slot 0" {
    local project="slotless"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: slotless
repo_path: $TEST_TMPDIR
ports:
  reserved:
    range: { min: 3100, max: 3299 }
    slots: 100
    services:
      frontend: 0
      backend: 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []"

    # A real slot-0 worktree plus a leftover stub. The stub owns no ports at all,
    # so the only claim on 3100/3101 is the worktree's.
    create_worktree_state "$project" "feature/real" "$TEST_TMPDIR" 0
    yq -i '.worktrees["feat-gone"].services.frontend.status = "stopped"' "$WT_STATE_DIR/${project}.state.yaml"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" != *"Duplicate port"* ]]
    [[ "$output" == *"No port conflicts detected"* ]]
}

@test "doctor scores the main-repo-root entry on ports.main, not slot 0" {
    local project="mainroot"
    local repo="$TEST_TMPDIR/repo"

    mkdir -p "$repo"
    git -C "$repo" init -q -b trunk
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: mainroot
repo_path: $repo
ports:
  main:
    frontend: 3000
    backend: 3001
  reserved:
    range: { min: 3100, max: 3299 }
    slots: 100
    services:
      frontend: 0
      backend: 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []"

    # `wt start` at the repo root writes a services-only entry keyed by the branch
    # checked out there; it runs on ports.main, so it never contends for slot 0.
    create_worktree_state "$project" "feature/slot-zero" "$TEST_TMPDIR" 0
    yq -i '.worktrees["trunk"].services.frontend.status = "stopped"' "$WT_STATE_DIR/${project}.state.yaml"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" != *"Duplicate port"* ]]
    # The root's own entry is live state, not a leftover.
    [[ "$output" != *"Orphaned worktree state: trunk"* ]]
}

# --- Summary line ---

@test "doctor shows summary" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"Summary"* ]]
    [[ "$output" == *"passed"* ]]
}

# --- Regression: survives set -e through every section ---
#
# wt.sh runs under `set -euo pipefail`. Post-increment `((counter++))` returns
# the pre-increment value as its exit status, so `((passed++))` at passed==0
# exits 1 and errexit aborts doctor right after the first check. bats's own
# `run` disables errexit, so the bug only surfaces in a subshell that re-enables
# it — which is what this test does.
@test "doctor runs to completion under set -e (counter regression)" {
    local project="healthy"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: healthy
repo_path: $TEST_TMPDIR
ports:
  reserved:
    range:
      min: 3000
      max: 3010
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run bash -c "set -euo pipefail
        for l in utils config port state worktree setup tmux service; do
            source '$WT_SCRIPT_DIR/lib/'\$l'.sh'
        done
        source '$WT_SCRIPT_DIR/commands/doctor.sh'
        cmd_doctor -p '$project' 2>&1"

    # Healthy fixture: no FAILs, so doctor exits 0 rather than aborting mid-run.
    [ "$status" -eq 0 ]
    # All five sections plus the summary must appear — the buggy version died
    # after "Dependencies" and never reached the rest.
    [[ "$output" == *"Dependencies"* ]]
    [[ "$output" == *"Project Configuration"* ]]
    [[ "$output" == *"State Consistency"* ]]
    [[ "$output" == *"Tmux Health"* ]]
    [[ "$output" == *"Port Conflicts"* ]]
    [[ "$output" == *"Summary"* ]]
}
