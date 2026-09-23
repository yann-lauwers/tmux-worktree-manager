#!/usr/bin/env bats
# tests/test_output_streams.bats - colour/hyperlink gating (per-stream tty check,
# NO_COLOR, WT_COLOR=always), the shared not-found message, and check_dependencies'
# stdout/stderr split.

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"

    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/health.sh"
    source "$WT_SCRIPT_DIR/commands/exec.sh"
    source "$WT_SCRIPT_DIR/commands/run.sh"
    source "$WT_SCRIPT_DIR/commands/start.sh"
    source "$WT_SCRIPT_DIR/commands/stop.sh"
    source "$WT_SCRIPT_DIR/commands/ports.sh"
    source "$WT_SCRIPT_DIR/commands/attach.sh"
    source "$WT_SCRIPT_DIR/commands/delete.sh"
    source "$WT_SCRIPT_DIR/commands/db.sh"

    TEST_REPO="$TEST_TMPDIR/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1
}

teardown() {
    teardown_test_dirs
}

# Write a minimal project config for $1 into $2 (default: WT_PROJECTS_DIR).
# Args: $1 project name, $2 projects dir
# Side: writes <dir>/<project>.yaml
_create_test_config() {
    local project="${1:-testproj}"
    local dir="${2:-$WT_PROJECTS_DIR}"
    create_yaml_fixture "$dir/${project}.yaml" "name: $project
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []"
}

# ===== _wt_color_decide: the full decision matrix, no real terminal needed =====

@test "_wt_color_decide: no tty, no NO_COLOR, no WT_COLOR -> off" {
    unset NO_COLOR WT_COLOR
    if _wt_color_decide 0; then result=1; else result=0; fi
    [[ "$result" == "0" ]]
}

@test "_wt_color_decide: tty, no NO_COLOR, no WT_COLOR -> on" {
    unset NO_COLOR WT_COLOR
    if _wt_color_decide 1; then result=1; else result=0; fi
    [[ "$result" == "1" ]]
}

@test "_wt_color_decide: tty, NO_COLOR=1 -> off" {
    export NO_COLOR=1
    unset WT_COLOR
    if _wt_color_decide 1; then result=1; else result=0; fi
    unset NO_COLOR
    [[ "$result" == "0" ]]
}

@test "_wt_color_decide: tty, NO_COLOR= (empty) -> on, per no-color.org" {
    export NO_COLOR=
    unset WT_COLOR
    if _wt_color_decide 1; then result=1; else result=0; fi
    unset NO_COLOR
    [[ "$result" == "1" ]]
}

@test "_wt_color_decide: no tty, NO_COLOR= (empty) -> off, follows the tty read" {
    export NO_COLOR=
    unset WT_COLOR
    if _wt_color_decide 0; then result=1; else result=0; fi
    unset NO_COLOR
    [[ "$result" == "0" ]]
}

@test "_wt_color_decide: no tty, WT_COLOR=always -> on" {
    unset NO_COLOR
    export WT_COLOR=always
    if _wt_color_decide 0; then result=1; else result=0; fi
    unset WT_COLOR
    [[ "$result" == "1" ]]
}

@test "_wt_color_decide: WT_COLOR=always wins over NO_COLOR=1" {
    export NO_COLOR=1
    export WT_COLOR=always
    if _wt_color_decide 0; then result=1; else result=0; fi
    unset NO_COLOR WT_COLOR
    [[ "$result" == "1" ]]
}

@test "_wt_color_decide: no tty, NO_COLOR unset, WT_COLOR unset -> off (matches piped default)" {
    unset NO_COLOR WT_COLOR
    if _wt_color_decide 0; then result=1; else result=0; fi
    [[ "$result" == "0" ]]
}

# ===== wt_color_init: stdout and stderr decided independently =====

@test "wt_color_init sets every stdout and stderr color var to '' when both streams are non-tty" {
    unset NO_COLOR WT_COLOR
    (
        wt_color_init
        [[ -z "$RED" && -z "$NC" && -z "$E_RED" && -z "$E_NC" ]]
    ) < /dev/null > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err"
    [[ $? -eq 0 ]]
}

@test "wt_color_init: WT_COLOR=always sets escape codes even off a terminal" {
    (
        export WT_COLOR=always
        wt_color_init
        [[ "$RED" == '\033[0;31m' && "$E_RED" == '\033[0;31m' ]]
    ) < /dev/null > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err"
    [[ $? -eq 0 ]]
}

# ===== die_no_worktree: the one shared message =====

@test "die_no_worktree writes the exact message to stderr, nothing to stdout, exit 1" {
    run --separate-stderr die_no_worktree "status" "nope" "testproj"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt status: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
    [[ "$stderr" != *$'\e'* ]]
}

# ===== die_no_worktree call sites: C7, C8 =====

@test "status: unknown branch dies via the shared not-found message (C7)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_status -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt status: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "health: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_health -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt health: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "exec: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_exec -p "testproj" "nope" echo hi
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt exec: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "run: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_run -p "testproj" "nope" some-step
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt run: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "start: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_start -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt start: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "delete: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_delete -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt delete: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "attach: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_attach -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt attach: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "ports: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    load_project_config "testproj"
    run --separate-stderr cmd_ports -p "testproj" "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt ports: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "ports set: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    run --separate-stderr cmd_ports_set -p "testproj" api-server 4500 nope
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt ports set: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

@test "db use-remote: unknown branch dies via the shared not-found message (C8)" {
    _create_test_config "testproj"
    run --separate-stderr cmd_db_use_remote -p "testproj" -y "nope"
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == "wt db use-remote: no worktree for branch 'nope' in project testproj — branch names are matched in full; 'wt ls' shows them" ]]
}

# ===== C9: one shared function writes the message =====

@test "no source file spells out the not-found message inline anymore (C9)" {
    run grep -rn 'Worktree not found' "$WT_SCRIPT_DIR/lib" "$WT_SCRIPT_DIR/commands" "$WT_SCRIPT_DIR/wt.sh"
    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

# ===== source scan: no stdout palette var on a line redirected to stderr =====

@test "no lib/commands/wt.sh line writes a stdout color var (\${RED} etc) redirected >&2" {
    run bash -c "grep -rnE '>&2' '$WT_SCRIPT_DIR/lib' '$WT_SCRIPT_DIR/commands' '$WT_SCRIPT_DIR/wt.sh' | grep -E '\\\$\\{(RED|GREEN|YELLOW|BLUE|MAGENTA|CYAN|BOLD|DIM|NC)\\}'"
    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

# ===== check_dependencies: whole report to stderr, nothing to stdout (C10) =====
#
# Driven through the real `wt.sh` entry point rather than sourced directly:
# wt.sh's own `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"` guard evaluates
# false-and-short-circuits under `source`, which set -e (on since wt.sh's own
# top line) turns into an immediate exit of the sourcing shell before
# check_dependencies would ever run.

# Build a PATH directory holding every tool in the system bin directories
# plus git and yq, minus the ones named — a PATH of that directory alone hides
# them wherever the platform installs them (/usr/bin on Linux runners,
# /opt/homebrew on macOS).
# Args: $1 shim dir, $@ tool names to leave out
# Side: creates the shim dir of symlinks
_path_without() {
    local shim="$1"; shift
    local dir f name skip
    mkdir -p "$shim"
    for dir in /usr/bin /bin /usr/sbin /sbin; do
        for f in "$dir"/*; do
            name="${f##*/}"
            for skip in "$@"; do [[ "$name" == "$skip" ]] && continue 2; done
            [[ -e "$shim/$name" ]] || ln -s "$f" "$shim/$name"
        done
    done
    for name in git yq tmux; do
        for skip in "$@"; do [[ "$name" == "$skip" ]] && continue 2; done
        ln -sf "$(command -v "$name")" "$shim/$name"
    done
}

@test "check_dependencies writes the whole report to stderr, nothing to stdout (C10)" {
    local shim="$TEST_TMPDIR/shim"
    local home_dir="$TEST_TMPDIR/home-deps1"
    mkdir -p "$home_dir"
    _path_without "$shim" tmux
    run --separate-stderr env PATH="$shim" HOME="$home_dir" "$WT_SCRIPT_DIR/wt.sh" ls
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
    [[ "$stderr" == *"Missing required dependencies"* ]]
    [[ "$stderr" == *"tmux"* ]]
}

@test "check_dependencies: optional-deps warning also lands entirely on stderr" {
    local shim="$TEST_TMPDIR/shim2"
    local home_dir="$TEST_TMPDIR/home-deps2"
    mkdir -p "$home_dir"
    _path_without "$shim" fzf jq gh
    run --separate-stderr env PATH="$shim" HOME="$home_dir" "$WT_SCRIPT_DIR/wt.sh" ls -q
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Optional dependencies"* ]]
    [[ "$stderr" == *"Optional dependencies missing"* ]]
    [[ "$stderr" == *"fzf"* ]]
}

# ===== C6: --help documents WT_COLOR and NO_COLOR =====

@test "wt --help documents WT_COLOR and NO_COLOR in the Environment block (C6)" {
    run "$WT_SCRIPT_DIR/wt.sh" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Environment:"* ]]
    [[ "$output" == *"WT_COLOR"* ]]
    [[ "$output" == *"NO_COLOR"* ]]
}

# ===== C1 / C5: wt ls, piped, with and without WT_COLOR=always =====
#
# The fixture lives under WT_CONFIG_DIR like the rest of this suite's; HOME
# points at a scratch directory so nothing under the real home is read.

_wt_ls_home() {
    local home_dir="$1"
    mkdir -p "$home_dir"
    _create_test_config testproj
}

@test "wt ls -q piped emits no ANSI escapes on stdout (C1)" {
    local home_dir="$TEST_TMPDIR/home1"
    _wt_ls_home "$home_dir"
    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-one" -b feature/one >/dev/null 2>&1

    run --separate-stderr env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" \
        "$WT_SCRIPT_DIR/wt.sh" ls -q
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"feature/one"* ]]
    [[ "$output" != *$'\e'* ]]
}

@test "wt ls -q piped with WT_COLOR=always still carries escape codes (C5)" {
    local home_dir="$TEST_TMPDIR/home2"
    _wt_ls_home "$home_dir"
    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-two" -b feature/two >/dev/null 2>&1

    run --separate-stderr env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" WT_COLOR=always \
        "$WT_SCRIPT_DIR/wt.sh" ls -q
    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'\e'* ]]
}

@test "wt ls -q piped with WT_COLOR=always wins over NO_COLOR=1 (C5)" {
    local home_dir="$TEST_TMPDIR/home3"
    _wt_ls_home "$home_dir"
    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-three" -b feature/three >/dev/null 2>&1

    run --separate-stderr env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" WT_COLOR=always NO_COLOR=1 \
        "$WT_SCRIPT_DIR/wt.sh" ls -q
    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'\e'* ]]
}

# ===== C3: on a real terminal, colour survives with NO_COLOR unset =====

@test "wt ls -q on a pty carries escape codes when NO_COLOR is unset (C3)" {
    if ! command -v script &>/dev/null; then
        skip "script(1) not available"
    fi

    local home_dir="$TEST_TMPDIR/home4"
    _wt_ls_home "$home_dir"
    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-four" -b feature/four >/dev/null 2>&1

    local raw
    if [[ "$(uname)" == "Darwin" ]]; then
        raw=$(env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" \
            script -q /dev/null "$WT_SCRIPT_DIR/wt.sh" ls -q 2>/dev/null)
    else
        raw=$(env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" \
            script -qec "'$WT_SCRIPT_DIR/wt.sh' ls -q" /dev/null 2>/dev/null)
    fi

    [[ "$raw" == *$'\e'* ]]
}

# ===== C4: NO_COLOR wins even on a terminal =====

@test "wt ls -q on a pty emits no escape codes when NO_COLOR is set (C4)" {
    if ! command -v script &>/dev/null; then
        skip "script(1) not available"
    fi

    local home_dir="$TEST_TMPDIR/home5"
    _wt_ls_home "$home_dir"
    git -C "$TEST_REPO" worktree add "$TEST_TMPDIR/wt-five" -b feature/five >/dev/null 2>&1

    local raw
    if [[ "$(uname)" == "Darwin" ]]; then
        raw=$(env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" NO_COLOR=1 \
            script -q /dev/null "$WT_SCRIPT_DIR/wt.sh" ls -q 2>/dev/null)
    else
        raw=$(env HOME="$home_dir" WT_CONFIG_DIR="$WT_CONFIG_DIR" WT_DATA_DIR="$WT_DATA_DIR" NO_COLOR=1 \
            script -qec "'$WT_SCRIPT_DIR/wt.sh' ls -q" /dev/null 2>/dev/null)
    fi

    [[ "$raw" != *$'\e'* ]]
}
