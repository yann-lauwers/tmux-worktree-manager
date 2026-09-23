#!/usr/bin/env bats
# tests/test_ci_shellcheck_pin.bats - Pins the shellcheck release CI, the
# pre-push hook and scripts/shellcheck.sh all lint against: the workflow names
# it once, as env.SHELLCHECK_VERSION, CONTRIBUTING.md names that same release,
# and scripts/shellcheck.sh reads the pin from ci.yml rather than hardcoding
# its own copy. Reads source text only — nothing is downloaded or executed.

load test_helper

CI_YML="$WT_SCRIPT_DIR/.github/workflows/ci.yml"
CONTRIBUTING="$WT_SCRIPT_DIR/CONTRIBUTING.md"
SHELLCHECK_SH="$WT_SCRIPT_DIR/scripts/shellcheck.sh"

source "$SHELLCHECK_SH"

@test "ci.yml pins shellcheck to one exact release, in one place" {
    local pinned
    pinned="$(pinned_shellcheck_version)"
    [[ "$pinned" =~ ^v0\.[0-9]+\.[0-9]+$ ]]

    run grep -oE 'v0\.[0-9]+\.[0-9]+' "$CI_YML"
    [ "$status" -eq 0 ]
    [ "$output" = "$pinned" ]
}

@test "ci.yml installs shellcheck only from the pinned release" {
    run grep -nE 'releases/latest|brew install[^#]*\bshellcheck\b|apt-get install[^#]*\bshellcheck\b|apt install[^#]*\bshellcheck\b' "$CI_YML"
    [ "$status" -eq 1 ]
}

@test "ci.yml downloads shellcheck from the pinned release via the variable" {
    run grep -nE 'releases/download/\$\{SHELLCHECK_VERSION\}' "$CI_YML"
    [ "$status" -eq 0 ]
}

@test "CONTRIBUTING.md names exactly the release ci.yml pins" {
    local pinned
    pinned="$(pinned_shellcheck_version)"

    run grep -oE 'v0\.[0-9]+\.[0-9]+' "$CONTRIBUTING"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sort -u)" = "$pinned" ]
}

@test "scripts/shellcheck.sh reads the pin from ci.yml rather than hardcoding it" {
    run grep -nE 'v0\.[0-9]+\.[0-9]+' "$SHELLCHECK_SH"
    [ "$status" -eq 1 ]
}

@test "scripts/shellcheck.sh's lint invocation fixes severity at info" {
    run grep -nE 'shellcheck[^#]*-S[[:space:]]+info' "$SHELLCHECK_SH"
    [ "$status" -eq 0 ]
}

@test ".shellcheckrc carries no severity key — shellcheck's rc format takes none" {
    SHELLCHECKRC="$WT_SCRIPT_DIR/.shellcheckrc"
    run grep -nE '^severity=' "$SHELLCHECKRC"
    [ "$status" -eq 1 ]
}
