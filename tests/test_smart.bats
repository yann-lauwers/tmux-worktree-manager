#!/usr/bin/env bats
# tests/test_smart.bats - Unit tests for lib/smart.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "smart"

    # Stub gh on PATH so smart_pr_badge never reaches the network: it prints
    # the same JSON shape `gh pr list --json number,state,isDraft` would.
    stub_gh "echo '{\"number\":42,\"state\":\"OPEN\",\"isDraft\":false}'"
}

teardown() {
    teardown_test_dirs
}

# Pins the OSC 8 hyperlink bytes smart_pr_badge wraps the PR number in when
# color is forced on: the ESC ]8;;<url> ESC \ open sequence and the ESC ]8;;
# ESC \ close sequence, built from the _WT_OSC8_OPEN/_WT_OSC8_ST constants
# rather than an inline printf.
@test "smart_pr_badge wraps the PR number in OSC 8 hyperlink bytes when color is forced" {
    WT_COLOR=always
    wt_color_init

    output=$(smart_pr_badge "some-branch" "foo/bar")

    expected_start=$'\e]8;;https://github.com/foo/bar/pull/42\e\\'
    expected_end=$'\e]8;;\e\\'

    [[ "$output" == *"${expected_start}"* ]]
    [[ "$output" == *"${expected_end}"* ]]
}

@test "smart_pr_badge carries no hyperlink bytes when color is off" {
    WT_COLOR=never
    wt_color_init

    output=$(smart_pr_badge "some-branch" "foo/bar")

    [[ "$output" != *$'\e]8;;'* ]]
}
