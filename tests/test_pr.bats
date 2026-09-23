#!/usr/bin/env bats
# tests/test_pr.bats - wt pr conflicts (report only) and wt pr resolve (its
# own verb): the -r/--resolve rejection on conflicts, the no-terminal and
# usage-error exits on resolve, and a named branch skipping the PR list.

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "json"
    load_lib "version"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"
    load_lib "smart"
    load_lib "worktree-list"
    source "$WT_SCRIPT_DIR/commands/pr.sh"

    TEST_REPO="$TEST_TMPDIR/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1

    # HOME points at an empty scratch tree, isolated from the real
    # ~/.config/wt/projects — the project fixture itself lives under
    # WT_PROJECTS_DIR, which lib/smart.sh reads.
    HOME_DIR="$TEST_TMPDIR/home"
    mkdir -p "$HOME_DIR"
    export HOME="$HOME_DIR"
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj
repo_path: $TEST_REPO
base_branch: main"

    # A real local remote, so a resolve test that actually runs git fetch/rebase
    # succeeds without reaching the network; smart_get_repo_nwo's output is only
    # ever handed to the stub gh below, which ignores it.
    git init --bare "$TEST_TMPDIR/origin.git" >/dev/null 2>&1
    git -C "$TEST_REPO" remote add origin "$TEST_TMPDIR/origin.git"
    git -C "$TEST_REPO" push origin main >/dev/null 2>&1

    STUB_BIN="$TEST_TMPDIR/stub-bin"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
    FZF_CALL_LOG="$TEST_TMPDIR/fzf-calls.log"
    : > "$FZF_CALL_LOG"
}

teardown() {
    teardown_test_dirs
}

# A stub `gh` answering only the two calls pr.sh makes: the signed-in user
# and the open-PR list (from a fixture file named by GH_PR_LIST_JSON), so a
# resolve/conflicts test never reaches the real network.
# Args: $1 stub bin dir, $2 fixture JSON file (the `gh pr list` body)
_stub_gh() {
    local bin="$1" fixture="$2"
    cat > "$bin/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "api" && "\$2" == "user" ]]; then
    echo "testuser"
elif [[ "\$1" == "pr" && "\$2" == "list" ]]; then
    cat "$fixture"
fi
EOF
    chmod +x "$bin/gh"
}

# A stub `fzf` that always picks the first line of its stdin (the first PR,
# or "rebase" in the strategy list) and counts its own invocations, so a test
# can assert both what was picked and how many times a picker ran.
# Args: $1 stub bin dir, $2 call-log file
_stub_fzf() {
    local bin="$1" log="$2"
    cat > "$bin/fzf" <<EOF
#!/bin/bash
printf 'call\n' >> "$log"
head -1
EOF
    chmod +x "$bin/fzf"
}

_conflicting_pr_fixture() {
    local file="$1"
    cat > "$file" <<'EOF'
[{"number":42,"headRefName":"feature/auth","title":"Add auth","mergeable":"CONFLICTING","isDraft":false,"author":{"login":"testuser"}}]
EOF
}

_mergeable_pr_fixture() {
    local file="$1"
    cat > "$file" <<'EOF'
[{"number":43,"headRefName":"feature/clean","title":"Clean change","mergeable":"MERGEABLE","isDraft":false,"author":{"login":"testuser"}}]
EOF
}

_empty_pr_fixture() {
    local file="$1"
    echo "[]" > "$file"
}

# ─── pr conflicts: -r/--resolve is rejected, never rebases or merges ───────

@test "pr conflicts -r is rejected: exit 2, stderr names wt pr resolve" {
    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts -r
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt pr resolve"* ]]
}

@test "pr conflicts --resolve is rejected: exit 2, stderr names wt pr resolve" {
    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts --resolve
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"wt pr resolve"* ]]
}

@test "pr conflicts with no conflicting PRs prints all clear, exit 0" {
    local fixture="$TEST_TMPDIR/prs.json"
    _mergeable_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"

    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts -p testproj
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"All clear"* ]]
}

@test "pr conflicts with an empty open-PR list prints all clear, exit 0" {
    local fixture="$TEST_TMPDIR/prs.json"
    _empty_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"

    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts -p testproj
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"All clear"* ]]
}

@test "pr conflicts with open PRs but no linked worktrees prints all clear, exit 0" {
    local fixture="$TEST_TMPDIR/prs.json"
    _mergeable_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"

    # git worktree list reports the main checkout's path already resolved
    # (e.g. /private/var, not /var, on macOS), so repo_path has to match
    # that resolved form for wt_path == repo_root to hold and the main
    # worktree to be skipped — leaving _pr_list_records' wt_branches loop
    # reachable with zero entries.
    local real_repo
    real_repo=$(cd "$TEST_REPO" && pwd -P)
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj
repo_path: $real_repo
base_branch: main"

    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts -p testproj
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"All clear"* ]]
}

@test "pr conflicts lists a conflicting PR and never rebases or merges" {
    local fixture="$TEST_TMPDIR/prs.json"
    _conflicting_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"

    run "$WT_SCRIPT_DIR/wt.sh" pr conflicts -p testproj
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"#42"* ]]
    [[ "$output" == *"feature/auth"* ]]
    [[ "$output" != *"Rebasing"* ]]
    [[ "$output" != *"Merging"* ]]
}

# ─── pr resolve: usage, no terminal, help ──────────────────────────────────

@test "pr resolve --help exits 0 with Exit codes" {
    run "$WT_SCRIPT_DIR/wt.sh" pr resolve --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Exit codes:"* ]]
}

@test "pr resolve --bogus is an unknown option: exit 2" {
    run "$WT_SCRIPT_DIR/wt.sh" pr resolve --bogus
    [[ "$status" -eq 2 ]]
}

@test "pr resolve with no terminal attached exits 1 naming wt pr conflicts" {
    run "$WT_SCRIPT_DIR/wt.sh" pr resolve </dev/null
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"wt pr conflicts"* ]]
}

@test "pr resolve refuses through its own seam, naming wt pr conflicts, with no real tty involved" {
    stdin_is_tty() { return 1; }

    run cmd_pr_resolve
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"wt pr conflicts"* ]]
}

# ─── pr resolve <branch>: skips the PR list, only the strategy picker runs ─

@test "pr resolve <branch> not conflicting reports nothing to resolve, exit 0" {
    local fixture="$TEST_TMPDIR/prs.json"
    _mergeable_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"
    _stub_fzf "$STUB_BIN" "$FZF_CALL_LOG"
    stdin_is_tty() { return 0; }

    run cmd_pr_resolve feature/clean -p testproj

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing to resolve"* ]]
    local calls
    calls=$(wc -l < "$FZF_CALL_LOG" | tr -d ' ')
    [[ "$calls" -eq 0 ]]
}

@test "pr resolve <branch> absent from scope exits 1" {
    local fixture="$TEST_TMPDIR/prs.json"
    _conflicting_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"
    _stub_fzf "$STUB_BIN" "$FZF_CALL_LOG"
    stdin_is_tty() { return 0; }

    run cmd_pr_resolve no-such-branch -p testproj

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"No open PR found for branch: no-such-branch"* ]]
}

@test "pr resolve <branch> skips the PR list and invokes fzf once, for the strategy only" {
    local fixture="$TEST_TMPDIR/prs.json"
    _conflicting_pr_fixture "$fixture"
    _stub_gh "$STUB_BIN" "$fixture"
    _stub_fzf "$STUB_BIN" "$FZF_CALL_LOG"
    stdin_is_tty() { return 0; }

    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-auth" -b feature/auth >/dev/null 2>&1

    run cmd_pr_resolve feature/auth -p testproj

    [[ "$output" != *"Pick a PR to resolve"* ]]
    local calls
    calls=$(wc -l < "$FZF_CALL_LOG" | tr -d ' ')
    [[ "$calls" -eq 1 ]]
}
