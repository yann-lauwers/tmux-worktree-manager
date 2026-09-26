#!/usr/bin/env bats
# tests/test_delete_safety.bats - Destructive-path safety tests for delete/prune.
#
# The happy-path suite (test_worktree.bats, test_commands.bats) exercises deletion
# only on CLEAN trees. This file pins the DESTRUCTIVE paths the tool actually takes
# when a worktree is dirty, unmerged, or bulk-deleted — because a misread here drops
# the user's only copy of uncommitted work, the branch, the ephemeral DB, and the
# tunnel together.
#
# Gate-first: the dirty-tree refusal (the one real guard) is asserted before anything
# else. The force-by-default bulk path and the teardown-before-guard ordering are
# SHARP EDGES — safe only by construction; the tests pin the CURRENT behavior and the
# CLAUDE.md tracks the fixes as proposals. Everything runs against temp git repos under
# $TEST_TMPDIR; no real worktree, DB, or tunnel is ever touched.

load test_helper

# `run !` asserts a nonzero exit. A bare `! cmd` is ignored by errexit anywhere but a test's
# last line, so it asserts nothing.
bats_require_minimum_version 1.5.0

setup() {
    _ORIG_CWD="$PWD"
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"

    source "$WT_SCRIPT_DIR/commands/delete.sh"

    # Fresh repo on `main` with one committed file (README.md is the tracked file the
    # dirty-tree tests modify).
    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    echo "init" > "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1
}

teardown() {
    # Restore CWD before removing TEST_TMPDIR — some tests cd into $TEST_REPO, and a
    # dangling CWD would break later test files that resolve relative paths.
    cd "$_ORIG_CWD" 2>/dev/null || cd /
    teardown_test_dirs
}

# A minimal project config (ports so export_port_vars resolves; no services, no tmux).
# extra_yaml appends hooks etc.
_write_config() {
    local project="$1"
    local extra_yaml="${2:-}"
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
services: []
${extra_yaml}"
}

# Commit a change INSIDE a worktree so its branch is ahead of main (unmerged) while the
# tree itself stays clean — isolates the branch-guard from the dirty-tree guard.
_commit_in() {
    local wt_path="$1"
    echo "work" > "$wt_path/feature.txt"
    git -C "$wt_path" add -A
    git -C "$wt_path" commit -m "unmerged work" >/dev/null 2>&1
}

# ── GATE: the dirty-tree refusal (the one real guard — asserted first) ─────────

@test "GATE: remove_worktree refuses a modified tree without --force" {
    local wt_path
    wt_path=$(create_worktree "feat/dirty" "" "$TEST_REPO" 2>/dev/null)
    echo "uncommitted change" > "$wt_path/README.md"   # modify a tracked file → dirty

    run remove_worktree "feat/dirty" 0 0 "$TEST_REPO"

    [[ "$status" -ne 0 ]]                               # removal refused
    worktree_exists "feat/dirty" "$TEST_REPO"           # worktree survives
    [[ "$(cat "$wt_path/README.md")" == "uncommitted change" ]]  # work intact
}

@test "GATE: remove_worktree refuses an untracked-file tree without --force" {
    local wt_path
    wt_path=$(create_worktree "feat/untracked" "" "$TEST_REPO" 2>/dev/null)
    echo "scratch" > "$wt_path/scratch.txt"            # untracked file → dirty

    run remove_worktree "feat/untracked" 0 0 "$TEST_REPO"

    [[ "$status" -ne 0 ]]
    worktree_exists "feat/untracked" "$TEST_REPO"
    [[ -f "$wt_path/scratch.txt" ]]
}

# ── --force: the explicit opt-in that drops both guards ───────────────────────

@test "remove_worktree with --force discards a dirty tree (explicit opt-in)" {
    local wt_path
    wt_path=$(create_worktree "feat/forcedirty" "" "$TEST_REPO" 2>/dev/null)
    echo "uncommitted change" > "$wt_path/README.md"

    run remove_worktree "feat/forcedirty" 1 0 "$TEST_REPO"

    [[ "$status" -eq 0 ]]                               # force removes it
    run ! worktree_exists "feat/forcedirty" "$TEST_REPO"
}

@test "SHARP EDGE: remove_worktree --force on a locked tree falls back to removing the directory" {
    local wt_path
    wt_path=$(create_worktree "feat/force-locked" "" "$TEST_REPO" 2>/dev/null)
    echo "work" > "$wt_path/notes.md"
    git -C "$TEST_REPO" worktree lock --reason "keep: mine" "$wt_path"

    run remove_worktree "feat/force-locked" 1 0 "$TEST_REPO"

    # git refuses a single --force on a locked tree; the fallback then deletes the path, lock
    # and untracked work with it. Why an unattended caller passes -y, never --force.
    [[ "$status" -eq 0 ]]
    [[ ! -d "$wt_path" ]]
}

@test "remove_worktree without --force keeps an unmerged branch" {
    local wt_path
    wt_path=$(create_worktree "feat/unmerged" "" "$TEST_REPO" 2>/dev/null)
    _commit_in "$wt_path"                               # branch ahead of main, tree clean

    # branch_exists checks CWD's repo (as `wt delete` runs from inside the repo).
    cd "$TEST_REPO"
    remove_worktree "feat/unmerged" 0 0 "$TEST_REPO" >/dev/null 2>&1

    run ! worktree_exists "feat/unmerged" "$TEST_REPO"      # clean tree → worktree removed
    git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/unmerged"  # branch kept (-d refused)
}

@test "remove_worktree with --force deletes an unmerged branch (-D)" {
    local wt_path
    wt_path=$(create_worktree "feat/unmerged-force" "" "$TEST_REPO" 2>/dev/null)
    _commit_in "$wt_path"

    cd "$TEST_REPO"
    remove_worktree "feat/unmerged-force" 1 0 "$TEST_REPO" >/dev/null 2>&1

    run ! worktree_exists "feat/unmerged-force" "$TEST_REPO"
    run ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/unmerged-force"  # -D dropped it
}

@test "remove_worktree deletes the branch when invoked from outside the repo" {
    local wt_path
    wt_path=$(create_worktree "feat/from-outside" "" "$TEST_REPO" 2>/dev/null)
    # Branch tip == main: clean and merged, so -d deletes it wherever git is asked from.

    # The cwd is NOT a git repo. Before the fix, branch_exists ran `git show-ref` here,
    # failed with "not a git repository", and the branch survived while the caller
    # reported it deleted.
    cd "$TEST_TMPDIR"
    remove_worktree "feat/from-outside" 0 0 "$TEST_REPO" >/dev/null 2>&1

    run ! worktree_exists "feat/from-outside" "$TEST_REPO"
    run ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/from-outside"  # branch gone
}

@test "cmd_delete reports the branch deleted only when it is gone, from outside the repo" {
    _write_config "outside"
    local wt_path
    wt_path=$(create_worktree "feat/outside-cmd" "" "$TEST_REPO" 2>/dev/null)

    cd "$TEST_TMPDIR"
    run cmd_delete "feat/outside-cmd" -f -p outside
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"branch deleted"* ]]
    run ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/outside-cmd"
}

# ── GATE: -y on a direct delete answers the prompt and keeps both git guards ──
# An unattended caller (the fleet supervisor's worktree reclaimer) has no terminal to answer
# the prompt, and must not reach for --force: --force drops the dirty-tree guard and, when git
# still refuses, falls back to removing the directory by path.

@test "GATE: cmd_delete -y refuses a dirty tree and it stays" {
    _write_config "yesproj"
    local wt_path
    wt_path=$(create_worktree "feat/yes-dirty" "" "$TEST_REPO" 2>/dev/null)
    echo "uncommitted change" > "$wt_path/README.md"
    echo "new work" > "$wt_path/notes.md"

    run cmd_delete "feat/yes-dirty" -y --keep-branch -p yesproj < /dev/null
    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 2 ]]                               # not a declined prompt: -y answered it
    worktree_exists "feat/yes-dirty" "$TEST_REPO"
    [[ "$(cat "$wt_path/README.md")" == "uncommitted change" ]]
    [[ -f "$wt_path/notes.md" ]]
}

@test "GATE: cmd_delete -y refuses a locked tree and it stays" {
    _write_config "yesproj"
    local wt_path
    wt_path=$(create_worktree "feat/yes-locked" "" "$TEST_REPO" 2>/dev/null)
    git -C "$TEST_REPO" worktree lock --reason "keep: mine" "$wt_path"

    run cmd_delete "feat/yes-locked" -y --keep-branch -p yesproj < /dev/null
    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 2 ]]
    [[ -d "$wt_path" ]]
    worktree_exists "feat/yes-locked" "$TEST_REPO"
}

@test "cmd_delete -y removes a clean tree with no stdin, and --keep-branch keeps the branch" {
    _write_config "yesproj"
    local wt_path
    wt_path=$(create_worktree "feat/yes-clean" "" "$TEST_REPO" 2>/dev/null)

    run cmd_delete "feat/yes-clean" -y --keep-branch -p yesproj < /dev/null
    [[ "$status" -eq 0 ]]
    [[ ! -d "$wt_path" ]]
    git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/yes-clean"
}

# ── SHARP EDGE: the bulk (picker/prune) path is force-by-default ──────────────

@test "SHARP EDGE: _delete_batch force-deletes a dirty worktree — no guard on the bulk path" {
    _write_config "testproj"
    load_project_config "testproj"

    local wt_path slot
    wt_path=$(create_worktree "feat/bulk" "" "$TEST_REPO" 2>/dev/null)
    slot=$(claim_slot "testproj" "feat/bulk" 3)
    create_worktree_state "testproj" "feat/bulk" "$wt_path" "$slot"
    echo "uncommitted change" > "$wt_path/README.md"   # dirty — only LABELLED, never refused

    cd "$TEST_REPO"
    _delete_batch "testproj|feat/bulk|$wt_path" >/dev/null 2>&1

    # Pins the missing guard: the picker / `wt prune -y` path discards uncommitted work.
    run ! worktree_exists "feat/bulk" "$TEST_REPO"
    [[ "$(get_worktree_state "testproj" "feat/bulk" "path")" == "" ]]
}

# ── SHARP EDGE: teardown runs before the removal guard ────────────────────────

@test "SHARP EDGE: pre_delete teardown fires before a non-force removal refuses" {
    local marker="$TEST_TMPDIR/teardown-ran"
    _write_config "testproj" "hooks:
  pre_delete: touch $marker"
    load_project_config "testproj"

    local wt_path slot
    wt_path=$(create_worktree "feat/order" "" "$TEST_REPO" 2>/dev/null)
    slot=$(claim_slot "testproj" "feat/order" 3)
    create_worktree_state "testproj" "feat/order" "$wt_path" "$slot"
    echo "uncommitted change" > "$wt_path/README.md"   # dirty → non-force removal will refuse

    # Direct non-force delete; answer the confirm with `y`. The pipeline subshell
    # isolates cmd_delete's `die` so the refusal can't abort the test.
    cd "$TEST_REPO"
    printf 'y\n' | cmd_delete feat/order -p testproj >/dev/null 2>&1 || true

    # The removal refused, so the checkout survives...
    worktree_exists "feat/order" "$TEST_REPO"
    # ...but the pre_delete teardown ALREADY ran — the irreversible partial-teardown window.
    [[ -f "$marker" ]]
}

# ── wt db reset: confirms before it stops or deletes anything ─────────────────

# Stubs pg_ctl/initdb/pg_isready/pnpm on PATH ahead of any real Postgres, and
# points HOME inside $TEST_TMPDIR so cmd_db_reset's pg_dir
# ($HOME/.local/share/nexus-pg/<slug>) never leaves the temp tree. Each stub
# appends its own argv to $TEST_TMPDIR/stub.log; initdb additionally mkdirs
# its -D target so pg_dir "exists" the way a real reset would leave it.
#
# Negative assertions count matches rather than using `! grep`, which errexit ignores.
_db_reset_setup() {
    source "$WT_SCRIPT_DIR/commands/db.sh"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME" "$TEST_TMPDIR/bin"
    STUB_LOG="$TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"

    printf '#!/bin/bash\necho "pg_ctl $*" >> "%s"\nexit 0\n' "$STUB_LOG" > "$TEST_TMPDIR/bin/pg_ctl"
    printf '#!/bin/bash\necho "initdb $*" >> "%s"\nwhile [[ $# -gt 0 ]]; do [[ "$1" == "-D" ]] && mkdir -p "$2"; shift; done\nexit 0\n' "$STUB_LOG" > "$TEST_TMPDIR/bin/initdb"
    printf '#!/bin/bash\necho "pg_isready $*" >> "%s"\nexit 0\n' "$STUB_LOG" > "$TEST_TMPDIR/bin/pg_isready"
    printf '#!/bin/bash\necho "pnpm $*" >> "%s"\nexit 0\n' "$STUB_LOG" > "$TEST_TMPDIR/bin/pnpm"
    chmod +x "$TEST_TMPDIR/bin/pg_ctl" "$TEST_TMPDIR/bin/initdb" "$TEST_TMPDIR/bin/pg_isready" "$TEST_TMPDIR/bin/pnpm"
    PATH="$TEST_TMPDIR/bin:$PATH"

    require_project() { echo "testproj"; }
    load_project_config() { :; }
    get_slot_for_worktree() { echo "0"; }
    get_service_port() { echo "3000"; }
    get_worktree_path() { echo ""; }

    DB_RESET_MARKER="$HOME/.local/share/nexus-pg/dbreset-branch/marker"
    mkdir -p "$(dirname "$DB_RESET_MARKER")"
    touch "$DB_RESET_MARKER"
}

@test "T1: cmd_db_reset on a terminal declining the prompt refuses without wiping" {
    _db_reset_setup
    stdin_is_tty() { return 0; }

    run cmd_db_reset dbreset-branch <<< "n"
    [[ "$status" -eq 2 ]]
    [[ -f "$DB_RESET_MARKER" ]]
    [[ "$(grep -c "pg_ctl.*stop" "$STUB_LOG")" -eq 0 ]]
    [[ "$(grep -c "^initdb" "$STUB_LOG")" -eq 0 ]]
}

@test "T1: cmd_db_reset on a terminal accepting the prompt resets" {
    _db_reset_setup
    stdin_is_tty() { return 0; }

    run cmd_db_reset dbreset-branch <<< "y"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$DB_RESET_MARKER" ]]
    grep -q "pg_ctl.*stop" "$STUB_LOG"
}

@test "T3: cmd_db_reset -y and --yes each reset without reading stdin or prompting" {
    local flag
    for flag in -y --yes; do
        _db_reset_setup
        stdin_is_tty() { return 1; }

        run cmd_db_reset dbreset-branch "$flag" < /dev/null
        [[ "$status" -eq 0 ]]
        [[ ! -f "$DB_RESET_MARKER" ]]
        grep -q "pg_ctl.*stop" "$STUB_LOG"
        [[ "$output" != *"[y/N]"* ]]
    done
}

@test "T4: cmd_db_reset with a real non-terminal stdin and no --yes refuses, naming --yes" {
    _db_reset_setup

    run cmd_db_reset dbreset-branch < /dev/null
    [[ "$status" -ne 0 ]]
    [[ -f "$DB_RESET_MARKER" ]]
    [[ "$(grep -c "pg_ctl.*stop" "$STUB_LOG")" -eq 0 ]]
    [[ "$output" == *"wt db reset: stdin is not a terminal and --yes was not given, so nothing was wiped"* ]]
    [[ "$output" == *"usage: wt db reset [branch] --yes"* ]]
}

@test "wt db reset --help mentions --yes and the declined exit code 2" {
    run "$WT_SCRIPT_DIR/wt.sh" db reset --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--yes"* ]]
    [[ "$output" == *"declining exits 2, the same as \`wt delete\`"* ]]
    [[ "$output" == *"the confirmation"*"was declined"* ]]
}
