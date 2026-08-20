#!/usr/bin/env bats
# tests/test_lane.bats - Tests for lane windows and lane commands

load test_helper

TMUX_TEST_SESSION="wt-lane-test"

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "tmux"

    TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export TMUX_LOG

    mkdir -p "$TEST_TMPDIR/bin"
    _mock_tmux ""
    REAL_PATH="$PATH"
    export REAL_PATH
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    teardown_test_dirs
}

# Install a stateful tmux mock: it logs every call, and it REMEMBERS the windows it
# is asked to create. A stateless mock cannot answer "does the window exist now",
# which is exactly the question that separates a live lane from an accepted request.
# $1 seeds one pre-existing window; empty means no window and no session.
_mock_tmux() {
    local existing_window="$1"
    WINDOWS_FILE="$TEST_TMPDIR/windows.txt"
    export WINDOWS_FILE
    : > "$WINDOWS_FILE"
    [[ -n "$existing_window" ]] && echo "$existing_window" >> "$WINDOWS_FILE"
    cat > "$TEST_TMPDIR/bin/tmux" <<'MOCK'
#!/bin/bash
echo "$@" >> "$TMUX_LOG"
case "$1" in
    list-windows) cat "$WINDOWS_FILE" 2>/dev/null ;;
    has-session)  [[ -s "$WINDOWS_FILE" ]] || exit 1 ;;
    new-window|new-session)
        prev=""
        for a in "$@"; do
            [[ "$prev" == "-n" ]] && echo "$a" >> "$WINDOWS_FILE"
            prev="$a"
        done
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/tmux"
}

# --- Seam A: create_lane_window ---------------------------------------------

@test "create_lane_window creates a detached window at the worktree running the command" {
    _mock_tmux "some-other-window"

    create_lane_window "$TMUX_TEST_SESSION" "nex-3345-lane" "$TEST_TMPDIR" "claude go"

    local line
    line=$(grep "new-window" "$TMUX_LOG" | head -1)
    [[ "$line" == *"-d"* ]]
    [[ "$line" == *"nex-3345-lane"* ]]
    [[ "$line" == *"$TEST_TMPDIR"* ]]
    [[ "$line" == *"claude go"* ]]
}

@test "create_lane_window refuses when the lane window already exists" {
    _mock_tmux "nex-3345-lane"

    run create_lane_window "$TMUX_TEST_SESSION" "nex-3345-lane" "$TEST_TMPDIR" "claude go"

    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 127 ]]   # 127 means the function is missing, not that it refused
    [[ "$(grep -c "new-window" "$TMUX_LOG")" -eq 0 ]]
}

@test "create_lane_window creates the session when none exists" {
    _mock_tmux ""

    create_lane_window "$TMUX_TEST_SESSION" "nex-3345-lane" "$TEST_TMPDIR" "claude go"

    local line
    line=$(grep "new-session" "$TMUX_LOG" | head -1)
    [[ -n "$line" ]]
    [[ "$line" == *"-d"* ]]
    [[ "$line" == *"nex-3345-lane"* ]]
}

@test "create_lane_window does not create a session when one already exists" {
    _mock_tmux "some-other-window"

    create_lane_window "$TMUX_TEST_SESSION" "nex-3345-lane" "$TEST_TMPDIR" "claude go"

    [[ "$(grep -c "new-session" "$TMUX_LOG")" -eq 0 ]]
}

# --- Seam B: cmd_lane -------------------------------------------------------

_load_lane_command() {
    load_lib "state"
    load_lib "worktree"
    load_lib "smart"
    source "$WT_SCRIPT_DIR/commands/lane.sh"
}

@test "lane_window_name suffixes the worktree dir name" {
    _load_lane_command
    run lane_window_name "yann-lauwers/nex-3345-run-evals"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"-lane" ]]
    [[ "$output" != "-lane" ]]
}

@test "lane shows help with --help" {
    _load_lane_command
    run cmd_lane --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"wt lane"* ]]
}

@test "lane rejects an unknown subcommand" {
    _load_lane_command
    run cmd_lane frobnicate 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 127 ]]
}

@test "lane start launches claude in a lane window at the worktree" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"

    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    smart_detect_project() { echo "lanetest"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { printf '%s\n' "$1" "$2" "$3" "$4" > "$TEST_TMPDIR/lane_call"; }

    run cmd_lane start nex-3345 --prompt "Work NEX-3345."
    [[ "$status" -eq 0 ]]

    local session window workdir command
    { read -r session; read -r window; read -r workdir; read -r command; } < "$TEST_TMPDIR/lane_call"
    [[ "$session" == "wt-lane-itest" ]]
    [[ "$window" == "nex-3345-lane" ]]
    [[ "$workdir" == "$TEST_TMPDIR/wt/nex-3345" ]]
    [[ "$command" == *"claude"* ]]
    [[ "$command" == *"Work NEX-3345."* ]]
}

@test "lane start survives a prompt containing a single quote" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"

    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { printf '%s\n' "$1" "$2" "$3" "$4" > "$TEST_TMPDIR/lane_call"; }

    run cmd_lane start nex-3345 --prompt "don't break the quoting"
    [[ "$status" -eq 0 ]]

    local command
    command=$(sed -n '4p' "$TEST_TMPDIR/lane_call")
    # Parsing is necessary and nowhere near sufficient: a build that silently drops
    # every apostrophe also parses. Assert the prompt survives, character for character.
    run bash -n -c "$command"
    [[ "$status" -eq 0 ]]

    # A shell must hand the prompt back whole, as ONE argument, unexpanded.
    local roundtrip
    roundtrip=$(bash -c "${command/#claude --/printf %s}")
    [[ "$roundtrip" == "don't break the quoting" ]]
}

@test "lane start without a prompt launches a bare claude session" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"

    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { printf '%s\n' "$1" "$2" "$3" "$4" > "$TEST_TMPDIR/lane_call"; }

    run cmd_lane start nex-3345
    [[ "$status" -eq 0 ]]

    local command
    command=$(sed -n '4p' "$TEST_TMPDIR/lane_call")
    [[ "$command" == "claude" ]]
}

@test "lane start creates the worktree when none exists yet" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-9999"

    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { printf '%s\n' "$1" "$2" "$3" "$4" > "$TEST_TMPDIR/lane_call"; }
    # Absent on the first resolve, present once cmd_create has run.
    smart_find_worktree() { [[ -f "$TEST_TMPDIR/created" ]] && echo "$TEST_TMPDIR/wt/nex-9999"; }
    cmd_create() { touch "$TEST_TMPDIR/created"; echo "$1" > "$TEST_TMPDIR/create_arg"; }

    run cmd_lane start NEX-9999 --prompt "go"
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_TMPDIR/created" ]]
    [[ "$(cat "$TEST_TMPDIR/create_arg")" == "NEX-9999" ]]
    [[ "$(sed -n '3p' "$TEST_TMPDIR/lane_call")" == "$TEST_TMPDIR/wt/nex-9999" ]]
}

@test "lane start fails when the worktree is still unresolved after create" {
    _load_lane_command

    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { touch "$TEST_TMPDIR/should_not_exist"; }
    smart_find_worktree() { echo ""; }
    cmd_create() { return 0; }

    run cmd_lane start NEX-9999
    [[ "$status" -ne 0 ]]
    [[ ! -f "$TEST_TMPDIR/should_not_exist" ]]
}

@test "lane ls lists lane windows and skips the service windows beside them" {
    _load_lane_command
    _mock_tmux "anything"
    cat > "$TEST_TMPDIR/bin/tmux" <<'MOCK'
#!/bin/bash
case "$1" in
    has-session)  exit 0 ;;
    list-windows) printf '%s\n' "nex-3345-dev|/wt/nex-3345" "nex-3345-lane|/wt/nex-3345" "nex-3482-lane|/wt/nex-3482" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/tmux"

    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }

    run cmd_lane ls
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"nex-3345-lane"* ]]
    [[ "$output" == *"nex-3482-lane"* ]]
    [[ "$output" != *"nex-3345-dev"* ]]
}

# --- Seam C: reusing a cmux workspace ---------------------------------------

# Install a cmux mock that logs every call and answers workspace.list with $1.
_mock_cmux() {
    local payload="$1"
    CMUX_LOG="$TEST_TMPDIR/cmux_calls.log"
    export CMUX_LOG
    cat > "$TEST_TMPDIR/bin/cmux" <<MOCK
#!/bin/bash
echo "\$@" >> "\$CMUX_LOG"
[[ "\$1" == "rpc" ]] && printf '%s\n' '$payload'
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/cmux"
}

@test "smart_find_cmux_workspace returns the ref of a workspace already at that path" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:2","current_directory":"/wt/other"},{"ref":"workspace:8","current_directory":"/wt/nex-3345"}]}'
    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "workspace:8" ]]
}

@test "smart_find_cmux_workspace returns nothing when no workspace holds that path" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:2","current_directory":"/wt/other"}]}'
    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ -z "$output" ]]
}

@test "smart_find_cmux_workspace returns nothing when cmux answers with junk" {
    load_lib "smart"
    _mock_cmux 'not json at all'
    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ -z "$output" ]]
}

@test "smart_find_cmux_workspace returns nothing when cmux is not installed" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[]}'
    rm -f "$TEST_TMPDIR/bin/cmux"
    export PATH="$TEST_TMPDIR/bin:/usr/bin:/bin"   # cmux genuinely absent; teardown still works
    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "smart_find_cmux_workspace picks the first when several already hold the path" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:3","current_directory":"/wt/x"},{"ref":"workspace:9","current_directory":"/wt/x"}]}'
    run smart_find_cmux_workspace "/wt/x"
    [[ "$output" == "workspace:3" ]]
}

@test "smart_cmux_open selects the workspace already open instead of making a second" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:8","current_directory":"/wt/nex-3345"}]}'

    run smart_cmux_open "/wt/nex-3345"
    [[ "$status" -eq 0 ]]
    grep -q "select-workspace" "$TEST_TMPDIR/cmux_calls.log"
    grep -q "workspace:8" "$TEST_TMPDIR/cmux_calls.log"
    ! grep -q "new-workspace" "$TEST_TMPDIR/cmux_calls.log"
}

@test "smart_cmux_open creates a workspace named for the worktree when none is open" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[]}'

    run smart_cmux_open "/wt/nex-3345"
    [[ "$status" -eq 0 ]]
    local line
    line=$(grep "new-workspace" "$TEST_TMPDIR/cmux_calls.log" | head -1)
    [[ "$line" == *"--name nex-3345"* ]]
    [[ "$line" == *"--cwd /wt/nex-3345"* ]]
    ! grep -q "select-workspace" "$TEST_TMPDIR/cmux_calls.log"
}

# --- Live tmux: what a mock cannot separate ---------------------------------
# A mocked tmux returns 0 for "request accepted" and for "a lane is alive in the
# directory it was given" alike. These two cases need the real thing.

@test "create_lane_window refuses a working directory that does not exist" {
    _mock_tmux "some-other-window"

    run create_lane_window "$TMUX_TEST_SESSION" "bad-lane" "/nonexistent/path/does/not/exist" "sleep 300"

    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 127 ]]
    [[ "$(grep -c "new-window" "$TMUX_LOG")" -eq 0 ]]
    [[ "$(grep -c "new-session" "$TMUX_LOG")" -eq 0 ]]
}

@test "create_lane_window reports a command that dies on the spot as a failure" {
    export PATH="$REAL_PATH"          # the mock cannot tell these two cases apart
    tmux() { command tmux -L wt-lane-tests "$@"; }   # a private server, never the user's
    command_exists tmux || skip "tmux not available"
    local session="wt-lane-ghost-$$"
    tmux kill-session -t "$session" 2>/dev/null || true

    run create_lane_window "$session" "ghost-lane" "$TEST_TMPDIR" "definitely-not-a-real-binary-xyz"
    local rc="$status"

    tmux kill-session -t "$session" 2>/dev/null || true
    [[ "$rc" -ne 0 ]]
}

@test "create_lane_window reports a real lane as a success, against real tmux" {
    export PATH="$REAL_PATH"          # the mock cannot tell these two cases apart
    tmux() { command tmux -L wt-lane-tests "$@"; }   # a private server, never the user's
    command_exists tmux || skip "tmux not available"
    local session="wt-lane-real-$$"
    tmux kill-session -t "$session" 2>/dev/null || true

    run create_lane_window "$session" "real-lane" "$TEST_TMPDIR" "sleep 30"
    local rc="$status"
    local listed
    listed=$(tmux list-windows -t "$session" -F "#{window_name} #{pane_current_path}" 2>/dev/null)

    tmux kill-session -t "$session" 2>/dev/null || true
    [[ "$rc" -eq 0 ]]
    [[ "$listed" == *"real-lane"* ]]
}

# --- The attach verb: the help text promised something wt open does not do ----

@test "lane attach targets the lane window, not a session named for the worktree" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"
    _mock_tmux "nex-3345-lane"        # a lane is running

    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    lane_attach_exec() { printf '%s\n' "$1" > "$TEST_TMPDIR/attach_target"; }

    run cmd_lane attach nex-3345
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$TEST_TMPDIR/attach_target")" == "wt-lane-itest:nex-3345-lane" ]]
}

@test "lane attach refuses when no lane is running for that worktree" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"
    _mock_tmux ""      # no windows exist

    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    lane_attach_exec() { touch "$TEST_TMPDIR/should_not_attach"; }

    run cmd_lane attach nex-3345
    [[ "$status" -ne 0 ]]
    [[ "$status" -ne 127 ]]   # 127 means the verb is missing, not that it refused
    [[ ! -f "$TEST_TMPDIR/should_not_attach" ]]
}

@test "lane start names the window after the resolved worktree, not the typed query" {
    _load_lane_command
    mkdir -p "$TEST_TMPDIR/wt/nex-3345"

    # A fuzzy query resolves to a worktree whose name it does not equal.
    smart_find_worktree() { echo "$TEST_TMPDIR/wt/nex-3345"; }
    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }
    create_lane_window() { printf '%s\n' "$1" "$2" "$3" "$4" > "$TEST_TMPDIR/lane_call"; }

    run cmd_lane start nex-33 --prompt "go"
    [[ "$status" -eq 0 ]]
    [[ "$(sed -n '2p' "$TEST_TMPDIR/lane_call")" == "nex-3345-lane" ]]
}

# --- C3: a lane that dies later must leave a body -----------------------------

@test "create_lane_window keeps a dead lane's window so its output survives" {
    _mock_tmux "some-other-window"

    create_lane_window "$TMUX_TEST_SESSION" "nex-3345-lane" "$TEST_TMPDIR" "claude go"

    grep -q "remain-on-exit" "$TMUX_LOG"
}

@test "lane ls marks a lane whose pane has died" {
    _load_lane_command
    cat > "$TEST_TMPDIR/bin/tmux" <<'MOCK'
#!/bin/bash
case "$1" in
    has-session)  exit 0 ;;
    list-windows) printf '%s\n' "nex-3345-lane|/wt/nex-3345|0" "nex-3482-lane|/wt/nex-3482|1" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/tmux"

    require_project() { echo "lanetest"; }
    load_project_config() { PROJECT_CONFIG_FILE="$TEST_TMPDIR/lanetest.yaml"; }
    get_tmux_session_name() { echo "wt-lane-itest"; }

    run cmd_lane ls
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"nex-3482-lane"* ]]
    [[ "$output" == *"dead"* ]]        # the one whose pane exited says so
    [[ "$(grep -c dead <<< "$output")" -eq 1 ]]
}

# --- S2: reuse must survive a workspace whose terminal wandered ---------------

@test "smart_find_cmux_workspace matches a workspace by name when its cwd has moved" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:8","custom_title":"nex-3345","current_directory":"/wt/nex-3345/apps/backend"}]}'

    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ "$output" == "workspace:8" ]]
}

@test "smart_find_cmux_workspace prefers the path over a same-named stranger" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[{"ref":"workspace:2","custom_title":"nex-3345","current_directory":"/somewhere/else"},{"ref":"workspace:8","custom_title":"other","current_directory":"/wt/nex-3345"}]}'

    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ "$output" == "workspace:8" ]]
}

# --- C16: a missing jq must say so, not silently stop reusing -----------------

@test "smart_find_cmux_workspace warns when jq is missing instead of failing quietly" {
    load_lib "smart"
    _mock_cmux '{"workspaces":[]}'
    # A shim that shadows the real jq and is not executable as jq at all.
    mkdir -p "$TEST_TMPDIR/nojq"
    cp "$TEST_TMPDIR/bin/cmux" "$TEST_TMPDIR/nojq/cmux"
    export PATH="$TEST_TMPDIR/nojq:/bin"      # no jq anywhere on this PATH

    run smart_find_cmux_workspace "/wt/nex-3345"
    [[ "$output" == *"jq"* ]]
}
