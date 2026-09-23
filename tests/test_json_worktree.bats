#!/usr/bin/env bats
# tests/test_json_worktree.bats - `wt status --json`, `wt ports --json`,
# `wt health --json`

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

    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/ports.sh"
    source "$WT_SCRIPT_DIR/commands/health.sh"

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

# One service, no health_check declared, and a db.url_template — the shared
# fixture for status/ports/health.
_create_json_test_config() {
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
    services:
      worker: {}
services:
  - name: web
    command: echo running
    working_dir: .
    port_key: web
db:
  url_template: \"postgresql://appuser:secret@localhost:\${PORT_WEB}/appdb\""
}

# Same, with no db block and no services — for the null/empty cases.
_create_bare_json_test_config() {
    local project="${1:-bareproj}"
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
services: []"
}

# Create a real worktree and register its state, mirroring test_commands.bats.
# Out: the worktree path
_make_worktree() {
    local project="$1"
    local branch="$2"

    load_project_config "$project"
    cd "$TEST_REPO" || return 1
    local wt_path
    wt_path=$(create_worktree "$branch" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "$project" "$branch" "$wt_path" 0
    claim_slot "$project" "$branch" 3 >/dev/null
    printf '%s' "$wt_path"
}

# ===== status --json =====

@test "status --json: top-level key set" {
    _create_json_test_config "testproj"
    local wt_path
    wt_path=$(_make_worktree "testproj" "feature/status-json")

    run --separate-stderr cmd_status -p "testproj" "feature/status-json" --json
    [[ "$status" -eq 0 ]]
    keys=$(printf '%s' "$output" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"project,branch,path,slot,created_at,created_at_epoch,created_at_local,git,services,ports,database"' ]]
}

@test "status --json: parses as one document and types booleans/ints" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/status-types"

    run --separate-stderr cmd_status -p "testproj" "feature/status-types" --json
    [[ "$status" -eq 0 ]]

    dirty_type=$(printf '%s' "$output" | yq -p json '.git.dirty | type')
    slot_type=$(printf '%s' "$output" | yq -p json '.slot | type')
    [[ "$dirty_type" == "!!bool" ]]
    [[ "$slot_type" == "!!int" ]]
}

@test "status --json: commit is the full 40-char sha, not truncated" {
    _create_json_test_config "testproj"
    local wt_path
    wt_path=$(_make_worktree "testproj" "feature/status-sha")

    local full_sha
    full_sha=$(git -C "$wt_path" rev-parse HEAD)

    run --separate-stderr cmd_status -p "testproj" "feature/status-sha" --json
    [[ "$status" -eq 0 ]]
    commit=$(printf '%s' "$output" | yq -p json '.git.commit')
    [[ "$commit" == "$full_sha" ]]
    [[ "${#commit}" -eq 40 ]]
}

@test "status --json: a branch with no upstream reports upstream, ahead and behind as null" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/status-untracked"

    run --separate-stderr cmd_status -p "testproj" "feature/status-untracked" --json
    [[ "$status" -eq 0 ]]
    tracking=$(printf '%s' "$output" | yq -p json -o json -I0 '[.git.upstream, .git.ahead, .git.behind]')
    [[ "$tracking" == "[null,null,null]" ]]
}

@test "status --json: a tracked branch reports its upstream and ahead/behind as ints" {
    _create_json_test_config "testproj"
    local wt_path
    wt_path=$(_make_worktree "testproj" "feature/status-tracked")
    git -C "$wt_path" branch -q --set-upstream-to=main

    run --separate-stderr cmd_status -p "testproj" "feature/status-tracked" --json
    [[ "$status" -eq 0 ]]
    tracking=$(printf '%s' "$output" | yq -p json -o json -I0 '[.git.upstream, .git.ahead, .git.behind]')
    [[ "$tracking" == '["main",0,0]' ]]
}

@test "status: a branch with no upstream prints no Tracking line" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/status-no-tracking"

    run --separate-stderr cmd_status -p "testproj" "feature/status-no-tracking"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Tracking"* ]]
}

@test "status --json: dirty is true after touching a tracked file's sibling" {
    _create_json_test_config "testproj"
    local wt_path
    wt_path=$(_make_worktree "testproj" "feature/status-dirty")
    echo "untracked" > "$wt_path/new-file.txt"

    run --separate-stderr cmd_status -p "testproj" "feature/status-dirty" --json
    [[ "$status" -eq 0 ]]
    dirty=$(printf '%s' "$output" | yq -p json '.git.dirty')
    [[ "$dirty" == "true" ]]
}

@test "status --json: database is null when none is configured" {
    _create_bare_json_test_config "bareproj"
    _make_worktree "bareproj" "feature/no-db"

    run --separate-stderr cmd_status -p "bareproj" "feature/no-db" --json
    [[ "$status" -eq 0 ]]
    db_type=$(printf '%s' "$output" | yq -p json '.database | type')
    services_len=$(printf '%s' "$output" | yq -p json '.services | length')
    [[ "$db_type" == "!!null" ]]
    [[ "$services_len" -eq 0 ]]
}

@test "status --json: database url is redacted, never the raw password" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/status-db"

    run --separate-stderr cmd_status -p "testproj" "feature/status-db" --json
    [[ "$status" -eq 0 ]]
    redacted=$(printf '%s' "$output" | yq -p json '.database.url_redacted')
    [[ "$redacted" == *'****'* ]]
    [[ "$redacted" != *'secret'* ]]
}

@test "status --json: not-found branch exits 1 with empty stdout" {
    _create_json_test_config "testproj"
    load_project_config "testproj"

    run --separate-stderr cmd_status -p "testproj" "feature/never-created" --json
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == *"no worktree for branch"* ]]
}

@test "status --json: unknown option still exits 2" {
    run cmd_status --bogus --json
    [[ "$status" -eq 2 ]]
}

# ===== ports --json =====

@test "ports --json: top-level key set" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/ports-json"

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-json" --json
    [[ "$status" -eq 0 ]]
    keys=$(printf '%s' "$output" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"project,branch,slot,projected,reserved,dynamic,env,database"' ]]
}

@test "ports --json: reserved carries the web service with an effective_port int and no override" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/ports-reserved"

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-reserved" --json
    [[ "$status" -eq 0 ]]
    service=$(printf '%s' "$output" | yq -p json '.reserved[0].service')
    override_type=$(printf '%s' "$output" | yq -p json '.reserved[0].override | type')
    port_type=$(printf '%s' "$output" | yq -p json '.reserved[0].effective_port | type')
    [[ "$service" == "web" ]]
    [[ "$override_type" == "!!null" ]]
    [[ "$port_type" == "!!int" ]]
}

@test "ports --json: without --check, in_use is null" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/ports-nocheck"

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-nocheck" --json
    [[ "$status" -eq 0 ]]
    in_use_type=$(printf '%s' "$output" | yq -p json '.reserved[0].in_use | type')
    [[ "$in_use_type" == "!!null" ]]
}

@test "ports --json: with --check, in_use is a bool" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/ports-check"

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-check" --check --json
    [[ "$status" -eq 0 ]]
    in_use_type=$(printf '%s' "$output" | yq -p json '.reserved[0].in_use | type')
    [[ "$in_use_type" == "!!bool" ]]
}

@test "ports --json: projected is true for a worktree with no slot yet" {
    _create_json_test_config "testproj"
    load_project_config "testproj"
    cd "$TEST_REPO"
    local wt_path
    wt_path=$(create_worktree "feature/ports-projected" "" "$TEST_REPO" 2>/dev/null)

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-projected" --json
    [[ "$status" -eq 0 ]]
    projected=$(printf '%s' "$output" | yq -p json '.projected')
    [[ "$projected" == "true" ]]
}

@test "ports --json: env carries PORT_WEB as an effective int" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/ports-env"

    run --separate-stderr cmd_ports -p "testproj" "feature/ports-env" --json
    [[ "$status" -eq 0 ]]
    port_web_type=$(printf '%s' "$output" | yq -p json '.env.PORT_WEB | type')
    [[ "$port_web_type" == "!!int" ]]
}

@test "ports --json: not-found branch exits 1 with empty stdout" {
    _create_json_test_config "testproj"
    load_project_config "testproj"

    run --separate-stderr cmd_ports -p "testproj" "feature/never-created" --json
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == *"no worktree for branch"* ]]
}

@test "ports --json: unknown option still exits 2" {
    run cmd_ports --bogus --json
    [[ "$status" -eq 2 ]]
}

# ===== health --json =====

@test "health --json: top-level key set" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/health-json"

    run --separate-stderr cmd_health -p "testproj" "feature/health-json" --json
    keys=$(printf '%s' "$output" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"project,branch,slot,services,healthy,summary"' ]]
}

@test "health --json: a declared-less service with nothing listening reports down, matching the human exit code" {
    _create_json_test_config "testproj"
    _make_worktree "testproj" "feature/health-down"
    load_project_config "testproj"

    run --separate-stderr cmd_health -p "testproj" "feature/health-down"
    human_status="$status"

    run --separate-stderr cmd_health -p "testproj" "feature/health-down" --json
    json_status="$status"

    verdict=$(printf '%s' "$output" | yq -p json '.services[0].verdict')
    check_declared=$(printf '%s' "$output" | yq -p json '.services[0].check_declared')
    check_declared_type=$(printf '%s' "$output" | yq -p json '.services[0].check_declared | type')
    healthy=$(printf '%s' "$output" | yq -p json '.healthy')

    [[ "$verdict" == "down" ]]
    [[ "$check_declared" == "false" ]]
    [[ "$check_declared_type" == "!!bool" ]]
    [[ "$healthy" == "false" ]]
    [[ "$json_status" -eq "$human_status" ]]
    [[ "$json_status" -eq 1 ]]
}

@test "health --json: no services configured reports an empty array and exits 0" {
    _create_bare_json_test_config "bareproj"
    _make_worktree "bareproj" "feature/health-none"

    run --separate-stderr cmd_health -p "bareproj" "feature/health-none" --json
    [[ "$status" -eq 0 ]]
    services_len=$(printf '%s' "$output" | yq -p json '.services | length')
    healthy=$(printf '%s' "$output" | yq -p json '.healthy')
    total=$(printf '%s' "$output" | yq -p json '.summary.total')
    [[ "$services_len" -eq 0 ]]
    [[ "$healthy" == "true" ]]
    [[ "$total" -eq 0 ]]
    [[ "$stderr" == *"No services configured"* ]]
}

@test "health --json: not-found branch exits 1 with empty stdout" {
    _create_json_test_config "testproj"
    load_project_config "testproj"

    run --separate-stderr cmd_health -p "testproj" "feature/never-created" --json
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == *"no worktree for branch"* ]]
}

@test "health --json: unknown option still exits 2" {
    run cmd_health --bogus --json
    [[ "$status" -eq 2 ]]
}
