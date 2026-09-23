#!/usr/bin/env bats
# tests/test_ci_yq_pin.bats - Pins the yq release CI tests against: the
# workflow names it once, as env.YQ_VERSION, and CONTRIBUTING.md names that
# same release, so bumping one without the other fails the suite on both legs.
# Scoped to yq's own v4.x.y pins — ci.yml also pins shellcheck (v0.x.y, guarded
# by tests/test_ci_shellcheck_pin.bats), which a bare semver grep would count here too.
# Reads source text only — nothing is downloaded or executed.

load test_helper

CI_YML="$WT_SCRIPT_DIR/.github/workflows/ci.yml"
CONTRIBUTING="$WT_SCRIPT_DIR/CONTRIBUTING.md"

# Print the pinned release, read the way the workflow reads it.
# Out: the YQ_VERSION value, e.g. v4.53.6
_pinned_yq() {
    yq '.env.YQ_VERSION' "$CI_YML"
}

@test "ci.yml pins yq to one exact release, in one place" {
    local pinned
    pinned="$(_pinned_yq)"
    [[ "$pinned" =~ ^v4\.[0-9]+\.[0-9]+$ ]]

    run grep -oE 'v4\.[0-9]+\.[0-9]+' "$CI_YML"
    [ "$status" -eq 0 ]
    [ "$output" = "$pinned" ]
}

@test "ci.yml installs yq only from the pinned release" {
    run grep -nE 'releases/latest|brew install[^#]*\byq\b|apt-get install[^#]*\byq\b' "$CI_YML"
    [ "$status" -eq 1 ]
}

@test "CONTRIBUTING.md names exactly the release ci.yml pins" {
    local pinned
    pinned="$(_pinned_yq)"

    run grep -oE 'v4\.[0-9]+\.[0-9]+' "$CONTRIBUTING"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sort -u)" = "$pinned" ]
}
