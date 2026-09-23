#!/bin/bash
# tests/test_helper.bash - Common test helpers for BATS tests

# Resolve project root (parent of tests/)
WT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WT_SCRIPT_DIR

# Create temporary directories for test isolation, and put the test process
# in a non-git directory: bats itself runs from this repo's own worktree
# checkout, so a test that never `cd`s away from it would auto-detect a real
# branch from anything reading cwd (detect_worktree_branch and friends),
# changing behaviour a fixture never asked for. cd runs last so every path
# captured above it (WT_CONFIG_DIR and friends) stays absolute.
setup_test_dirs() {
    TEST_TMPDIR="$(mktemp -d)"
    export WT_CONFIG_DIR="$TEST_TMPDIR/config"
    export WT_PROJECTS_DIR="$WT_CONFIG_DIR/projects"
    export WT_DATA_DIR="$TEST_TMPDIR/data"
    export WT_STATE_DIR="$WT_DATA_DIR/state"
    export WT_LOG_DIR="$WT_DATA_DIR/logs"

    mkdir -p "$WT_CONFIG_DIR" "$WT_PROJECTS_DIR" "$WT_DATA_DIR" "$WT_STATE_DIR" "$WT_LOG_DIR"
    cd "$TEST_TMPDIR"
}

# Remove temporary directories
teardown_test_dirs() {
    if [[ -n "${TEST_TMPDIR:-}" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Source a single lib module (and its dependencies)
# Usage: load_lib "utils"  -> sources lib/utils.sh
load_lib() {
    local lib="$1"
    source "$WT_SCRIPT_DIR/lib/${lib}.sh"
}

# Write a YAML fixture file
# Usage: create_yaml_fixture "$path" "yaml content"
create_yaml_fixture() {
    local path="$1"
    local content="$2"

    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}

# Put a stub gh first on PATH, so a command under test never reaches the network.
# Args: $1 the stub's body — the shell run in place of gh (e.g. "exit 1", or an echo of its JSON)
# Side: writes $TEST_TMPDIR/bin/gh, prepends $TEST_TMPDIR/bin to PATH
stub_gh() {
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\n%s\n' "$1" > "$TEST_TMPDIR/bin/gh"
    chmod +x "$TEST_TMPDIR/bin/gh"
    PATH="$TEST_TMPDIR/bin:$PATH"
}

# Build a PATH directory holding symlinks to every dependency wt.sh checks
# for (git, yq, tmux, jq, gh) plus the coreutils its startup and library
# sourcing need, but never fzf — so a test can pin behaviour that must hold
# on a machine without it, like CI's ubuntu runners, regardless of whether
# this machine happens to have it installed.
# Args: $1 shim directory (created if absent)
# Side: writes symlinks into $1
build_no_fzf_shim() {
    local shim="$1"
    mkdir -p "$shim"
    local u
    for u in bash sh git yq tmux jq gh cat dirname readlink basename sed awk \
        grep printf mkdir true rm mv cp ls mktemp date tr cut head tail sort \
        uniq wc find xargs env id whoami hostname sleep kill ps df du chmod \
        touch ln; do
        local p
        p=$(command -v "$u" 2>/dev/null) || continue
        ln -sf "$p" "$shim/$u" 2>/dev/null
    done
}
