#!/usr/bin/env bats
# tests/test_completions_bash.bats - Pins bash-completion behaviour for wt
#
# Sources completions/wt.bash, drives _wt_completions the way bash's
# programmable-completion machinery does (COMP_WORDS/COMP_CWORD/COMP_LINE
# set, function called directly, COMPREPLY read back), and asserts on the
# resulting candidates. Guards against a refactor of the compgen/COMPREPLY
# wiring changing what a user sees at the prompt.

load test_helper

setup() {
    setup_test_dirs
    # The real bash-completion package (source of _init_completion) is not
    # guaranteed to be loaded in a test shell. _wt_completions only relies
    # on it succeeding — it recomputes cur/prev itself right after the call
    # — so a stub that returns 0 exercises wt's own completion logic without
    # depending on bash-completion being installed on the machine running
    # the suite.
    _init_completion() { return 0; }
    source "$WT_SCRIPT_DIR/completions/wt.bash"
}

teardown() {
    teardown_test_dirs
}

# Drives _wt_completions for a given command line, splitting it on spaces
# into COMP_WORDS the way bash itself does. A trailing space in $1 means the
# last word is empty (completion just after a space), matching bash's own
# COMP_WORDS behaviour.
# Args: $1 the command line typed so far, e.g. "wt cr"
run_completion() {
    local line="$1"
    COMP_LINE="$line"
    COMP_POINT="${#line}"
    read -r -a COMP_WORDS <<< "$line"
    if [[ "$line" == *" " ]]; then
        COMP_WORDS+=("")
    fi
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    # bash's own completion machinery calls this function and reads
    # COMPREPLY back regardless of what it returns, so a nonzero exit here
    # (compgen itself exits 1 on zero matches) is not a completion failure —
    # only an empty COMPREPLY would be. `|| true` keeps that distinction
    # instead of letting bats treat the exit code as the test's own verdict.
    _wt_completions || true
}

@test "completion: top-level command prefix lists matching subcommands" {
    run_completion "wt cr"
    [[ " ${COMPREPLY[*]} " == *" create "* ]]
    [[ " ${COMPREPLY[*]} " != *" ls "* ]]
}

@test "completion: top-level dash prefix lists only the top-level flags" {
    run_completion "wt -h"
    [[ "${#COMPREPLY[@]}" -eq 1 ]]
    [[ "${COMPREPLY[0]}" == "-h" ]]
}

@test "completion: a subcommand's own flags are offered after a dash" {
    run_completion "wt prune -"
    [[ " ${COMPREPLY[*]} " == *" -y "* ]]
    [[ " ${COMPREPLY[*]} " == *" --yes "* ]]
    [[ " ${COMPREPLY[*]} " == *" -p "* ]]
    [[ " ${COMPREPLY[*]} " == *" -h "* ]]
}

@test "completion: -p/--project completes project names from ~/.config/wt/projects" {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/wt/projects"
    touch "$HOME/.config/wt/projects/nexus.yaml"
    touch "$HOME/.config/wt/projects/wt-cli.yaml"

    run_completion "wt ls -p "
    [[ " ${COMPREPLY[*]} " == *" nexus "* ]]
    [[ " ${COMPREPLY[*]} " == *" wt-cli "* ]]
    [[ "${#COMPREPLY[@]}" -eq 2 ]]
}

@test "completion: list offers --status but not -s" {
    run_completion "wt list -"
    [[ " ${COMPREPLY[*]} " == *" --status "* ]]
    [[ " ${COMPREPLY[*]} " != *" -s "* ]]
}

@test "completion: ls offers neither -s nor --status" {
    run_completion "wt ls -"
    [[ " ${COMPREPLY[*]} " != *" -s "* ]]
    [[ " ${COMPREPLY[*]} " != *" --status "* ]]
}

@test "completion: a worktree-listing command with no worktrees offers no candidates" {
    # $TEST_TMPDIR is not a git repo, so `git worktree list` fails silently
    # and the candidate list is empty.
    run_completion "wt open "
    [[ "${#COMPREPLY[@]}" -eq 0 ]]
}

@test "completion: open offers neither -a nor --all" {
    run_completion "wt open -"
    [[ " ${COMPREPLY[*]} " != *" -a "* ]]
    [[ " ${COMPREPLY[*]} " != *" --all "* ]]
}

@test "completion: status offers no --services" {
    run_completion "wt status -"
    [[ " ${COMPREPLY[*]} " != *" --services "* ]]
}

@test "completion: init offers --name but not -n" {
    run_completion "wt init -"
    [[ " ${COMPREPLY[*]} " == *" --name "* ]]
    [[ " ${COMPREPLY[*]} " != *" -n "* ]]
}
