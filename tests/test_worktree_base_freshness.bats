#!/usr/bin/env bats
# tests/test_worktree_base_freshness.bats - Pins _freshest_base_ref.
#
# `git worktree add -b <new> <path> <base>` resolves <base> as a plain local
# ref. That is right for a branch this checkout tracks and pulls, and wrong for
# a long-lived integration branch that only ever receives merges on the forge:
# its local ref stays pinned at whatever commit it held when it was first
# created here, so every worktree cut from it starts days behind.
#
# These tests pin which side wins, in both directions.

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "worktree"

    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" -c commit.gpgsign=false commit -m "initial" >/dev/null 2>&1
}

teardown() {
    teardown_test_dirs
}

# Give TEST_REPO an origin whose base branch is ahead of the local ref —
# the shape a forge merge leaves behind on a branch nobody pulls locally.
_setup_stale_base() {
    REMOTE="$(cd "$TEST_TMPDIR" && pwd -P)/remote.git"
    git init --bare -b main "$REMOTE" >/dev/null 2>&1
    git -C "$TEST_REPO" remote add origin "$REMOTE" >/dev/null 2>&1

    git -C "$TEST_REPO" checkout -b integration >/dev/null 2>&1
    touch "$TEST_REPO/base-old"
    git -C "$TEST_REPO" add base-old
    git -C "$TEST_REPO" -c commit.gpgsign=false commit -m "old base" >/dev/null 2>&1
    git -C "$TEST_REPO" push -u origin integration >/dev/null 2>&1

    # Advance the remote without advancing the local ref.
    CLONE="$(cd "$TEST_TMPDIR" && pwd -P)/clone"
    git clone "$REMOTE" "$CLONE" >/dev/null 2>&1
    git -C "$CLONE" config user.email "test@test.com"
    git -C "$CLONE" config user.name "Test"
    git -C "$CLONE" checkout integration >/dev/null 2>&1
    touch "$CLONE/base-new"
    git -C "$CLONE" add base-new
    git -C "$CLONE" -c commit.gpgsign=false commit -m "new base" >/dev/null 2>&1
    git -C "$CLONE" push origin integration >/dev/null 2>&1

    git -C "$TEST_REPO" checkout main >/dev/null 2>&1
}

# `run` folds stderr into $output and this function logs there, so every
# assertion below reads the resolved ref off stdout alone.
@test "_freshest_base_ref redirects a behind local ref to origin" {
    _setup_stale_base
    resolved=$(_freshest_base_ref "integration" "$TEST_REPO" 2>/dev/null)
    [ "$resolved" = "origin/integration" ]
}

@test "create_worktree branches from origin when the local base is behind" {
    _setup_stale_base
    wt_path=$(create_worktree "feature/fresh" "integration" "$TEST_REPO" 2>/dev/null)
    [ -d "$wt_path" ]
    # The file that exists only on the remote tip must be in the new worktree.
    [ -f "$wt_path/base-new" ]
}

@test "_freshest_base_ref keeps a local ref that is ahead of origin" {
    _setup_stale_base
    # A local-only commit on the base makes it ahead as well as behind.
    git -C "$TEST_REPO" checkout integration >/dev/null 2>&1
    touch "$TEST_REPO/base-local"
    git -C "$TEST_REPO" add base-local
    git -C "$TEST_REPO" -c commit.gpgsign=false commit -m "local base work" >/dev/null 2>&1
    git -C "$TEST_REPO" checkout main >/dev/null 2>&1

    resolved=$(_freshest_base_ref "integration" "$TEST_REPO" 2>/dev/null)
    [ "$resolved" = "integration" ]
}

@test "_freshest_base_ref leaves a base with no remote-tracking ref alone" {
    git -C "$TEST_REPO" branch local-only >/dev/null 2>&1
    resolved=$(_freshest_base_ref "local-only" "$TEST_REPO" 2>/dev/null)
    [ "$resolved" = "local-only" ]
}

@test "_freshest_base_ref leaves a base that is not a local branch alone" {
    resolved=$(_freshest_base_ref "v1.2.3" "$TEST_REPO" 2>/dev/null)
    [ "$resolved" = "v1.2.3" ]
}

@test "create_worktree still works with no remote configured" {
    git -C "$TEST_REPO" checkout -b solo >/dev/null 2>&1
    touch "$TEST_REPO/solo-file"
    git -C "$TEST_REPO" add solo-file
    git -C "$TEST_REPO" -c commit.gpgsign=false commit -m "solo" >/dev/null 2>&1
    git -C "$TEST_REPO" checkout main >/dev/null 2>&1

    wt_path=$(create_worktree "feature/no-remote" "solo" "$TEST_REPO" 2>/dev/null)
    [ -d "$wt_path" ]
    [ -f "$wt_path/solo-file" ]
}
