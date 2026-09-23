#!/usr/bin/env bats
# tests/test_githooks.bats - Drives .githooks/pre-push and scripts/shellcheck.sh
# against a throwaway copy of this repo, so a real shellcheck finding and a
# real bats failure are each proven to refuse the push, not just asserted from
# reading the source. The copy is git-initialized and committed so the hook's
# own `git rev-parse --show-toplevel` resolves inside it, and stub shellcheck
# / bats binaries keep the version-check and clean-case runs hermetic and fast.
# The fixture is built once in setup_file() — untarring and git-init'ing this
# whole repo on every test made this file the slowest in the suite — and each
# test that mutates it (planting a lint finding, writing a stub binary)
# restores its own change in teardown() so tests stay independent.

load test_helper

setup_file() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR

    FIXTURE="$TEST_TMPDIR/repo"
    mkdir -p "$FIXTURE"
    tar -C "$WT_SCRIPT_DIR" --exclude='.git' -cf - . | tar -C "$FIXTURE" -xf -
    ( cd "$FIXTURE" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m fixture )
    export FIXTURE

    STUBS="$TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    export STUBS

    REAL_YQ="$(command -v yq)"
    cat > "$STUBS/yq" <<EOF
#!/bin/bash
exec "$REAL_YQ" "\$@"
EOF
    chmod +x "$STUBS/yq"

    REAL_SHELLCHECK_DIR="$(dirname "$(command -v shellcheck)")"
    export REAL_SHELLCHECK_DIR

    source "$WT_SCRIPT_DIR/scripts/shellcheck.sh"
    PINNED="$(pinned_shellcheck_version)"
    export PINNED
    export PINNED_BARE="${PINNED#v}"

    # Restricted PATH holding only what a hook needs: basic utils, the yq
    # shim (so the real yq answers even once shellcheck's own directory is
    # excluded), and no shellcheck of any kind unless a test adds one.
    export RESTRICTED_PATH="$STUBS:/usr/bin:/bin"
}

teardown_file() {
    if [[ -n "${TEST_TMPDIR:-}" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

teardown() {
    git -C "$FIXTURE" checkout -q -- lib/utils.sh
    rm -f "$STUBS/shellcheck" "$STUBS/bats"
}

# Write a stub `shellcheck` into $STUBS that reports $1 on --version and
# exits $2 on any other invocation (the lint run).
# Args: $1 version string (no leading v), $2 exit code for a lint run
_stub_shellcheck() {
    local version="$1"
    local exit_code="$2"
    cat > "$STUBS/shellcheck" <<EOF
#!/bin/bash
if [[ "\$1" == "--version" ]]; then
    printf 'ShellCheck - shell script analysis tool\nversion: %s\nlicense: GNU General Public License, version 3\n' "$version"
    exit 0
fi
exit $exit_code
EOF
    chmod +x "$STUBS/shellcheck"
}

# Write a stub `bats` into $STUBS that exits $1.
# Args: $1 exit code
_stub_bats() {
    cat > "$STUBS/bats" <<EOF
#!/bin/bash
exit $1
EOF
    chmod +x "$STUBS/bats"
}

@test "scripts/shellcheck.sh refuses when shellcheck is missing" {
    PATH="$RESTRICTED_PATH" run "$FIXTURE/scripts/shellcheck.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$PINNED"* ]]
}

@test "scripts/shellcheck.sh refuses when shellcheck reports a different version" {
    _stub_shellcheck "0.0.1" 0
    PATH="$RESTRICTED_PATH" run "$FIXTURE/scripts/shellcheck.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$PINNED"* ]]
}

@test "scripts/shellcheck.sh finds a planted SC2086 unquoted expansion" {
    printf 'foo="bar baz"\necho $foo\n' >> "$FIXTURE/lib/utils.sh"
    PATH="$RESTRICTED_PATH:$REAL_SHELLCHECK_DIR" run "$FIXTURE/scripts/shellcheck.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SC2086"* ]]
}

@test "scripts/shellcheck.sh exits 0 with the pinned shellcheck and no finding" {
    _stub_shellcheck "$PINNED_BARE" 0
    PATH="$RESTRICTED_PATH" run "$FIXTURE/scripts/shellcheck.sh"
    [ "$status" -eq 0 ]
}

@test "pre-push refuses on a planted SC2086 finding, through the real hook and shellcheck" {
    printf 'foo="bar baz"\necho $foo\n' >> "$FIXTURE/lib/utils.sh"
    _stub_bats 0
    PATH="$RESTRICTED_PATH:$REAL_SHELLCHECK_DIR" run bash -c "cd '$FIXTURE' && PATH='$RESTRICTED_PATH:$REAL_SHELLCHECK_DIR' ./.githooks/pre-push <<< ''"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SC2086"* ]]
}

@test "pre-push refuses on missing shellcheck, naming the gate rather than a finding" {
    _stub_bats 0
    PATH="$RESTRICTED_PATH" run bash -c "cd '$FIXTURE' && PATH='$RESTRICTED_PATH' ./.githooks/pre-push <<< ''"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$PINNED"* ]]
    [[ "$output" == *"refused by scripts/shellcheck.sh"* ]]
    [[ "$output" != *"found a finding"* ]]
}

@test "pre-push refuses when shellcheck reports a different version, naming the gate rather than a finding" {
    _stub_shellcheck "0.0.1" 0
    _stub_bats 0
    PATH="$RESTRICTED_PATH" run bash -c "cd '$FIXTURE' && PATH='$RESTRICTED_PATH' ./.githooks/pre-push <<< ''"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$PINNED"* ]]
    [[ "$output" == *"refused by scripts/shellcheck.sh"* ]]
    [[ "$output" != *"found a finding"* ]]
}

@test "pre-push refuses when bats tests/ fails" {
    _stub_shellcheck "$PINNED_BARE" 0
    _stub_bats 1
    PATH="$RESTRICTED_PATH" run bash -c "cd '$FIXTURE' && PATH='$RESTRICTED_PATH' ./.githooks/pre-push <<< ''"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bats"* ]]
}

@test "pre-push exits 0 when shellcheck and bats both pass" {
    _stub_shellcheck "$PINNED_BARE" 0
    _stub_bats 0
    PATH="$RESTRICTED_PATH" run bash -c "cd '$FIXTURE' && PATH='$RESTRICTED_PATH' ./.githooks/pre-push <<< ''"
    [ "$status" -eq 0 ]
}
