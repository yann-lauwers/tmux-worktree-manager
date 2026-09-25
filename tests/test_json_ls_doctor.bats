#!/usr/bin/env bats
# tests/test_json_ls_doctor.bats - `wt ls --json` and `wt doctor --json`

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "json"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"
    load_lib "smart"
    source "$WT_SCRIPT_DIR/commands/smartlist.sh"
    source "$WT_SCRIPT_DIR/commands/doctor.sh"

    # Resolve through the tmp dir's real path: git worktree list reports the
    # physical path, and comparing that against a symlinked $TEST_TMPDIR/...
    # (macOS's /var -> /private/var) makes the main checkout look like an
    # extra worktree entry to every path-string comparison below it.
    TEST_REPO="$(cd -P "$TEST_TMPDIR" && pwd)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q -b main
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -q -m initial
}

teardown() {
    teardown_test_dirs
}

_ls_config() {
    local project="${1:-testproj}"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $TEST_REPO
services: []"
}

# ===== wt ls --json =====

@test "ls --json: no projects configured prints projects:[] and total:0" {
    run cmd_smartlist --json
    [[ "$status" -eq 0 ]]
    projects=$(printf '%s' "$output" | yq -p json -o json '.projects')
    total=$(printf '%s' "$output" | yq -p json '.total')
    [[ "$projects" == "[]" ]]
    [[ "$total" == "0" ]]
}

@test "wt.sh ls --json under /bin/bash lists a project with no worktrees" {
    # The shipped entry point runs under /bin/bash (3.2 on macOS) with set -u,
    # where expanding an empty array aborts; bats itself may run a newer bash.
    _ls_config "testproj"
    run --separate-stderr env WT_WARN_DEPS=false /bin/bash "$WT_SCRIPT_DIR/wt.sh" ls -q -p testproj --json
    [[ "$status" -eq 0 ]]
    worktrees=$(printf '%s' "$output" | yq -p json -o json -I0 '.projects[0].worktrees')
    [[ "$worktrees" == "[]" ]]
}

@test "wt.sh doctor --json under /bin/bash prints one document" {
    _ls_config "testproj"
    run --separate-stderr env WT_WARN_DEPS=false /bin/bash "$WT_SCRIPT_DIR/wt.sh" doctor -p testproj --json
    keys=$(printf '%s' "$output" | yq -p json -o json -I0 'keys')
    [[ "$keys" == '["project","checks","summary","ok"]' ]]
}

@test "ls --json: top-level key set is projects,total" {
    _ls_config "testproj"
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    keys=$(printf '%s' "$output" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"projects,total"' ]]
}

@test "ls --json: a project with no worktrees is still listed, with worktrees: []" {
    _ls_config "testproj"
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    project=$(printf '%s' "$output" | yq -p json '.projects[0].project')
    wt_type=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees | type')
    wt_len=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees | length')
    total=$(printf '%s' "$output" | yq -p json '.total')
    [[ "$project" == "testproj" ]]
    [[ "$wt_type" == "!!seq" ]]
    [[ "$wt_len" == "0" ]]
    [[ "$total" == "0" ]]
}

@test "ls --json: project object key set is project,repo_path,repo,pr_lookup,slots,worktrees" {
    _ls_config "testproj"
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    keys=$(printf '%s' "$output" | yq -p json -o json '.projects[0] | keys | join(",")')
    [[ "$keys" == '"project,repo_path,repo,pr_lookup,slots,worktrees"' ]]
}

@test "ls --json: -q sets pr_lookup to skipped and pr to null" {
    _ls_config "testproj"
    git -C "$TEST_REPO" worktree add -q "$(dirname "$TEST_REPO")/wt-one" -b feature/one
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    pr_lookup=$(printf '%s' "$output" | yq -p json '.projects[0].pr_lookup')
    pr_type=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].pr | type')
    [[ "$pr_lookup" == "skipped" ]]
    [[ "$pr_type" == "!!null" ]]
}

@test "ls --json: a repo with no remote reports pr_lookup unavailable and pr null, with no network call" {
    _ls_config "testproj"
    git -C "$TEST_REPO" worktree add -q "$(dirname "$TEST_REPO")/wt-one" -b feature/one
    run cmd_smartlist --json
    [[ "$status" -eq 0 ]]
    pr_lookup=$(printf '%s' "$output" | yq -p json '.projects[0].pr_lookup')
    repo=$(printf '%s' "$output" | yq -p json '.projects[0].repo | type')
    pr_type=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].pr | type')
    [[ "$pr_lookup" == "unavailable" ]]
    [[ "$repo" == "!!null" ]]
    [[ "$pr_type" == "!!null" ]]
}

@test "ls --json: one worktree carries branch, path, slot, managed as typed fields" {
    _ls_config "testproj"
    git -C "$TEST_REPO" worktree add -q "$(dirname "$TEST_REPO")/wt-one" -b feature/one
    create_worktree_state "testproj" "feature/one" "$(dirname "$TEST_REPO")/wt-one" 0

    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    branch=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].branch')
    path=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].path')
    slot=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].slot')
    managed=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].managed')
    managed_type=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].managed | type')
    total=$(printf '%s' "$output" | yq -p json '.total')
    [[ "$branch" == "feature/one" ]]
    [[ "$path" == "$(dirname "$TEST_REPO")/wt-one" ]]
    [[ "$slot" == "0" ]]
    [[ "$managed" == "true" ]]
    [[ "$managed_type" == "!!bool" ]]
    [[ "$total" == "1" ]]
}

@test "ls --json: a worktree with no recorded slot is managed:false, slot:null" {
    _ls_config "testproj"
    git -C "$TEST_REPO" worktree add -q "$(dirname "$TEST_REPO")/wt-one" -b feature/one

    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    slot_type=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].slot | type')
    managed=$(printf '%s' "$output" | yq -p json '.projects[0].worktrees[0].managed')
    [[ "$slot_type" == "!!null" ]]
    [[ "$managed" == "false" ]]
}

@test "ls --json: -p filters to one project" {
    _ls_config "testproj"
    _ls_config "otherproj"
    run cmd_smartlist -q --json -p testproj
    [[ "$status" -eq 0 ]]
    count=$(printf '%s' "$output" | yq -p json '.projects | length')
    name=$(printf '%s' "$output" | yq -p json '.projects[0].project')
    [[ "$count" == "1" ]]
    [[ "$name" == "testproj" ]]
}

@test "ls --json: stdout carries only the JSON document, nothing else" {
    _ls_config "testproj"
    git -C "$TEST_REPO" worktree add -q "$(dirname "$TEST_REPO")/wt-one" -b feature/one
    run --separate-stderr cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    run bash -c "printf '%s' \"\$1\" | yq -p json '.'" -- "$output"
    [[ "$status" -eq 0 ]]
}

@test "ls --json: an unknown option exits 2 with no stdout and today's usage error" {
    run --separate-stderr cmd_smartlist --bogus-flag --json
    [[ "$status" -eq 2 ]]
    [[ "$output" == "" ]]
    [[ "$stderr" == *"bogus-flag"* ]] || [[ "$stderr" == *"Unknown"* ]] || [[ "$stderr" == *"unknown"* ]]
}

@test "wt ls --help documents --json and its Output block" {
    run cmd_smartlist --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--json"* ]]
    [[ "$output" == *"Output (--json):"* ]]
}

# ===== wt doctor --json =====

@test "doctor --json: top-level key set is project,checks,summary,ok" {
    run cmd_doctor -p nonexistent --json
    keys=$(printf '%s' "$output" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"project,checks,summary,ok"' ]]
}

@test "doctor --json: ok is typed as a boolean" {
    run cmd_doctor -p nonexistent --json
    ok_type=$(printf '%s' "$output" | yq -p json '.ok | type')
    [[ "$ok_type" == "!!bool" ]]
}

@test "doctor --json: each check carries section, status, message" {
    run cmd_doctor -p nonexistent --json
    keys=$(printf '%s' "$output" | yq -p json -o json '.checks[0] | keys | join(",")')
    [[ "$keys" == '"section,status,message"' ]]
    section=$(printf '%s' "$output" | yq -p json '.checks[0].section')
    [[ "$section" == "dependencies" ]]
}

@test "doctor --json: checks is never empty — stdout is never empty" {
    run cmd_doctor -p nonexistent --json
    [[ -n "$output" ]]
    len=$(printf '%s' "$output" | yq -p json '.checks | length')
    [[ "$len" -gt 0 ]]
}

@test "doctor --json: project is set once a project is detected" {
    _ls_config "healthyproj"
    run cmd_doctor -p "healthyproj" --json
    project=$(printf '%s' "$output" | yq -p json '.project')
    [[ "$project" == "healthyproj" ]]
}

@test "doctor --json: project is null when none is detected" {
    # No -p, and setup_test_dirs left cwd in a non-git tmp dir — detect_project
    # finds nothing, unlike "-p <name>", which sets project from the flag alone.
    run cmd_doctor --json
    project_type=$(printf '%s' "$output" | yq -p json '.project | type')
    [[ "$project_type" == "!!null" ]]
}

@test "doctor --json: exit code matches the human form on a failing config" {
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

    run cmd_doctor -p "$project"
    human_status="$status"
    run cmd_doctor -p "$project" --json
    json_status="$status"
    ok=$(printf '%s' "$output" | yq -p json '.ok')

    [[ "$human_status" -eq 1 ]]
    [[ "$json_status" -eq "$human_status" ]]
    [[ "$ok" == "false" ]]
}

@test "doctor --json: exit code matches the human form on a passing config" {
    _ls_config "healthyproj"
    run cmd_doctor -p "healthyproj"
    human_status="$status"
    run cmd_doctor -p "healthyproj" --json
    json_status="$status"
    ok=$(printf '%s' "$output" | yq -p json '.ok')

    [[ "$human_status" -eq 0 ]]
    [[ "$json_status" -eq "$human_status" ]]
    [[ "$ok" == "true" ]]
}

@test "doctor --json: summary counts match checks array counts by status" {
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
    run cmd_doctor -p "$project" --json
    summary_failed=$(printf '%s' "$output" | yq -p json '.summary.failed')
    counted_failed=$(printf '%s' "$output" | yq -p json '[.checks[] | select(.status == "fail")] | length')
    [[ "$summary_failed" -gt 0 ]]
    [[ "$summary_failed" == "$counted_failed" ]]
}

@test "doctor --json: stdout carries only the JSON document, nothing else" {
    _ls_config "healthyproj"
    run --separate-stderr cmd_doctor -p "healthyproj" --json
    run bash -c "printf '%s' \"\$1\" | yq -p json '.'" -- "$output"
    [[ "$status" -eq 0 ]]
}

@test "doctor --json: an unknown option exits 2 with no stdout" {
    run --separate-stderr cmd_doctor --bogus-flag --json
    [[ "$status" -eq 2 ]]
    [[ "$output" == "" ]]
}

@test "wt doctor --help documents --json, its Output block, and exit-code parity" {
    run cmd_doctor --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--json"* ]]
    [[ "$output" == *"Output (--json):"* ]]
    [[ "$output" == *"same"* ]]
}

# ===== slots: what `wt create` can claim, counted by the claim code =====

_slots_config() {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj
repo_path: $TEST_REPO
ports:
  reserved:
    slots: 3
services: []"
}

@test "ls --json: slots reports max, claimed, stale and free for an empty project" {
    _slots_config
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    slots=$(printf '%s' "$output" | yq -p json -o json -I0 '.projects[0].slots')
    [[ "$slots" == '{"max":3,"claimed":0,"stale":0,"free":3}' ]]
}

@test "ls --json: a claimed slot is not free, and a stale one counts as free" {
    _slots_config
    local live_dir; live_dir="$(dirname "$TEST_REPO")/wt-live"
    mkdir -p "$live_dir"
    claim_slot "testproj" "feature/live" 3
    create_worktree_state "testproj" "feature/live" "$live_dir" 0
    claim_slot "testproj" "feature/gone" 3
    create_worktree_state "testproj" "feature/gone" "/nonexistent/wt-gone" 1
    run cmd_smartlist -q --json
    [[ "$status" -eq 0 ]]
    slots=$(printf '%s' "$output" | yq -p json -o json -I0 '.projects[0].slots')
    [[ "$slots" == '{"max":3,"claimed":2,"stale":1,"free":2}' ]]
}

@test "ls --json: a slot recorded above max is neither claimed nor free" {
    _slots_config
    yq -i '.slots.testproj.old = 7' "$(slots_file)" 2>/dev/null || { init_slots_file; yq -i '.slots.testproj.old = 7' "$(slots_file)"; }
    run cmd_smartlist -q --json
    free=$(printf '%s' "$output" | yq -p json '.projects[0].slots.free')
    claimed=$(printf '%s' "$output" | yq -p json '.projects[0].slots.claimed')
    [[ "$claimed" == "0" && "$free" == "3" ]]
}

@test "slot_capacity agrees with claim_slot: free 0 means the next claim fails" {
    _slots_config
    claim_slot "testproj" "feature/a" 3
    claim_slot "testproj" "feature/b" 3
    claim_slot "testproj" "feature/c" 3
    local cap; cap=$(slot_capacity "testproj" 3)
    [[ "$cap" == "3 3 0 0" ]]
    run claim_slot "testproj" "feature/d" 3
    [[ "$status" -ne 0 ]]
}
