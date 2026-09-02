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

setup() {
    # bats runs test bodies with `set -e` and leaks the option to the next test. These
    # tests drive delete paths that legitimately return nonzero (refusals, `die`), and a
    # leaked errexit trips latent `((i++))` bugs in later suites (e.g. execute_setup).
    # Reset from setup — the only point bats lets the change reach the body and leak out.
    set +e
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
    ! worktree_exists "feat/forcedirty" "$TEST_REPO"
}

@test "remove_worktree without --force keeps an unmerged branch" {
    local wt_path
    wt_path=$(create_worktree "feat/unmerged" "" "$TEST_REPO" 2>/dev/null)
    _commit_in "$wt_path"                               # branch ahead of main, tree clean

    # branch_exists checks CWD's repo (as `wt delete` runs from inside the repo).
    cd "$TEST_REPO"
    remove_worktree "feat/unmerged" 0 0 "$TEST_REPO" >/dev/null 2>&1

    ! worktree_exists "feat/unmerged" "$TEST_REPO"      # clean tree → worktree removed
    git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/unmerged"  # branch kept (-d refused)
}

@test "remove_worktree with --force deletes an unmerged branch (-D)" {
    local wt_path
    wt_path=$(create_worktree "feat/unmerged-force" "" "$TEST_REPO" 2>/dev/null)
    _commit_in "$wt_path"

    cd "$TEST_REPO"
    remove_worktree "feat/unmerged-force" 1 0 "$TEST_REPO" >/dev/null 2>&1

    ! worktree_exists "feat/unmerged-force" "$TEST_REPO"
    ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/unmerged-force"  # -D dropped it
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

    ! worktree_exists "feat/from-outside" "$TEST_REPO"
    ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/from-outside"  # branch gone
}

@test "cmd_delete reports the branch deleted only when it is gone, from outside the repo" {
    _write_config "outside"
    local wt_path
    wt_path=$(create_worktree "feat/outside-cmd" "" "$TEST_REPO" 2>/dev/null)

    cd "$TEST_TMPDIR"
    run cmd_delete "feat/outside-cmd" -f -p outside
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"branch deleted"* ]]
    ! git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feat/outside-cmd"
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
    ! worktree_exists "feat/bulk" "$TEST_REPO"
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
