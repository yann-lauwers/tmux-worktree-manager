#!/usr/bin/env bats
# tests/test_version.bats - Pins `wt --version` deriving from the install
# checkout's own release tags, falling back to the VERSION constant, and the
# release check that keeps that constant equal to the latest tag.
#
# Every scenario builds its own fixture repo under $TEST_TMPDIR, so no test
# runs against, tags, or reads the real repo this checkout lives in. Fixture
# tags (v9.9.9, v8.0.0) and the fixture constant (0.0.0-fixture) match no real
# release, so a value leaking from the real repo shows up as a wrong answer.

load test_helper

setup() {
    setup_test_dirs
}

teardown() {
    teardown_test_dirs
}

# Make $1 a git repository
# Args: $1 directory
# Side: runs git init
_init_repo() {
    git -C "$1" init -b main >/dev/null 2>&1
}

# Commit everything in a fixture repo
# Args: $1 directory, $2 commit message
# Side: stages and commits in $1
_commit_all() {
    git -C "$1" add -A
    git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -m "$2" >/dev/null 2>&1
}

# Tag HEAD of a fixture repo
# Args: $1 directory, $2 tag name
# Side: creates a lightweight tag in $1
_tag() {
    git -C "$1" -c tag.gpgsign=false tag "$2"
}

# Build a wt install at $TEST_TMPDIR/install: a copy of wt.sh with its VERSION
# pinned to the fixture value, and lib/ and commands/ linked from this checkout
# (the version path never reads their contents).
# Side: sets INSTALL
_make_install() {
    INSTALL="$TEST_TMPDIR/install"
    mkdir -p "$INSTALL"
    sed 's/^VERSION="[^"]*"/VERSION="0.0.0-fixture"/' "$WT_SCRIPT_DIR/wt.sh" > "$INSTALL/wt.sh"
    chmod +x "$INSTALL/wt.sh"
    ln -s "$WT_SCRIPT_DIR/lib" "$INSTALL/lib"
    ln -s "$WT_SCRIPT_DIR/commands" "$INSTALL/commands"
}

# Build the install as a git checkout tagged v9.9.9 at HEAD
# Side: sets INSTALL
_make_tagged_install() {
    _make_install
    _init_repo "$INSTALL"
    _commit_all "$INSTALL" "install"
    _tag "$INSTALL" v9.9.9
}

# Build a second, unrelated repository with one commit
# Args: $1 directory
_make_other_repo() {
    mkdir -p "$1"
    _init_repo "$1"
    touch "$1/README.md"
    _commit_all "$1" "other"
}

# Run a wt entry point with no git overrides inherited from whatever runs bats
# Args: $1 path to wt, $2... its arguments
_run_wt() {
    run env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR "$@"
}

@test "version: tagged install prints the bare tag" {
    _make_tagged_install

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 9.9.9" ]
}

@test "version: one commit past the tag prints the describe suffix" {
    _make_tagged_install
    touch "$INSTALL/extra-file"
    _commit_all "$INSTALL" "one more"

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [[ "$output" =~ ^wt\ 9\.9\.9-1-g[0-9a-f]{7,}$ ]]
}

@test "version: a modified tracked file marks -dirty" {
    _make_tagged_install
    echo "changed" >> "$INSTALL/wt.sh"

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 9.9.9-dirty" ]
}

@test "version: an untracked-only file does not mark -dirty" {
    _make_tagged_install
    touch "$INSTALL/untracked-only"

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 9.9.9" ]
}

@test "version: no .git falls back to the VERSION constant" {
    _make_install

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 0.0.0-fixture" ]
}

@test "version: invoked via a symlink from a different tagged repo resolves against the install" {
    _make_tagged_install
    _make_other_repo "$TEST_TMPDIR/other-repo"
    _tag "$TEST_TMPDIR/other-repo" v8.0.0
    mkdir -p "$TEST_TMPDIR/bin"
    ln -s "$INSTALL/wt.sh" "$TEST_TMPDIR/bin/wt"

    cd "$TEST_TMPDIR/other-repo"
    _run_wt "$TEST_TMPDIR/bin/wt" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 9.9.9" ]
}

@test "version: an exported GIT_DIR pointing elsewhere does not redirect resolution" {
    _make_tagged_install
    _make_other_repo "$TEST_TMPDIR/other-repo"

    GIT_DIR="$TEST_TMPDIR/other-repo/.git" run "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [ "$output" = "wt 9.9.9" ]
}

@test "version: a nearer non-release tag is ignored in favor of the v-prefixed one" {
    _make_tagged_install
    touch "$INSTALL/after-release"
    _commit_all "$INSTALL" "after release"
    _tag "$INSTALL" stray-base

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [[ "$output" =~ ^wt\ 9\.9\.9-1-g[0-9a-f]{7,}$ ]]
}

@test "version: a tagless repo prints a bare commit hash" {
    _make_install
    _init_repo "$INSTALL"
    _commit_all "$INSTALL" "no tags"

    _run_wt "$INSTALL/wt.sh" --version

    [ "$status" -eq 0 ]
    [[ "$output" =~ ^wt\ [0-9a-f]{7,}$ ]]
}

@test "version: -v, version, and --version all agree" {
    _make_tagged_install

    _run_wt "$INSTALL/wt.sh" --version
    [ "$output" = "wt 9.9.9" ]
    _run_wt "$INSTALL/wt.sh" -v
    [ "$output" = "wt 9.9.9" ]
    _run_wt "$INSTALL/wt.sh" version
    [ "$output" = "wt 9.9.9" ]
}

# Build a release fixture at $RELEASE_REPO: a wt.sh holding one VERSION line,
# committed, and tagged $2 at HEAD when $2 is non-empty
# Args: $1 the whole VERSION line, $2 tag name or ""
# Side: sets RELEASE_REPO
_make_release_fixture() {
    RELEASE_REPO="$TEST_TMPDIR/release-repo"
    mkdir -p "$RELEASE_REPO"
    printf '%s\n' "$1" > "$RELEASE_REPO/wt.sh"
    _init_repo "$RELEASE_REPO"
    _commit_all "$RELEASE_REPO" "release fixture"
    if [[ -n "$2" ]]; then
        _tag "$RELEASE_REPO" "$2"
    fi
}

@test "check-release: VERSION equal to the tag exits 0" {
    _make_release_fixture 'VERSION="9.9.9"' v9.9.9

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 0 ]
    [ "$output" = "ok: VERSION 9.9.9 matches tag v9.9.9" ]
}

@test "check-release: VERSION ahead of the tag exits 1" {
    _make_release_fixture 'VERSION="9.9.10"' v9.9.9

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 1 ]
}

@test "check-release: VERSION behind the tag exits 1" {
    _make_release_fixture 'VERSION="9.9.8"' v9.9.9

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 1 ]
}

@test "check-release: a nearer stray non-v tag is ignored, matching tag still exits 0" {
    _make_release_fixture 'VERSION="9.9.9"' v9.9.9
    touch "$RELEASE_REPO/after-release"
    _commit_all "$RELEASE_REPO" "after release"
    _tag "$RELEASE_REPO" stray-base

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 0 ]
}

@test "check-release: no tag reachable exits 2" {
    _make_release_fixture 'VERSION="9.9.9"' ""

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 2 ]
}

@test "check-release: unparseable VERSION exits 2" {
    _make_release_fixture 'VERSION=unquoted' v9.9.9

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$RELEASE_REPO"

    [ "$status" -eq 2 ]
}

@test "check-release: a directory that is not a git repository exits 2" {
    mkdir -p "$TEST_TMPDIR/not-a-repo"
    printf 'VERSION="9.9.9"\n' > "$TEST_TMPDIR/not-a-repo/wt.sh"

    run "$WT_SCRIPT_DIR/scripts/check-release.sh" "$TEST_TMPDIR/not-a-repo"

    [ "$status" -eq 2 ]
}
