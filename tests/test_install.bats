#!/usr/bin/env bats
# tests/test_install.bats - Pins install.sh's completion/help/flag-parsing
# contract: every completion file it installs is a symlink into this
# checkout's completions/ (so a checkout edit shows through with no
# re-install), its --help page and printed text name only commands wt.sh's
# own dispatcher accepts, and an unknown flag or a malformed --prefix stops
# with exit 2 before anything is written under HOME.
#
# Every scenario runs a fixture copy of install.sh under $TEST_TMPDIR/checkout
# (install.sh, wt.sh, lib/, commands/, completions/ copied from
# $WT_SCRIPT_DIR), with HOME pointed at a fresh $TEST_TMPDIR/home and a stub
# PATH (no-op yq/tmux/fzf/jq/gh) so check_dependencies never prompts on
# stdin. install.sh's own make_executable chmods the scripts beside it, so
# running it against the fixture, rather than $WT_SCRIPT_DIR, keeps this
# checkout's tracked files untouched — never the real $HOME, and never the
# installed copy. The static extraction helpers (_parser_flags,
# _dispatcher_words) read $WT_SCRIPT_DIR directly since they only inspect
# source text, never execute it.

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    setup_test_dirs
    HOME_DIR="$TEST_TMPDIR/home"
    mkdir -p "$HOME_DIR"

    CHECKOUT="$TEST_TMPDIR/checkout"
    mkdir -p "$CHECKOUT"
    cp "$WT_SCRIPT_DIR/install.sh" "$CHECKOUT/"
    cp "$WT_SCRIPT_DIR/wt.sh" "$CHECKOUT/"
    cp -R "$WT_SCRIPT_DIR/lib" "$CHECKOUT/"
    cp -R "$WT_SCRIPT_DIR/commands" "$CHECKOUT/"
    cp -R "$WT_SCRIPT_DIR/completions" "$CHECKOUT/"

    STUB_BIN="$TEST_TMPDIR/stubbin"
    mkdir -p "$STUB_BIN"
    local dep
    for dep in yq tmux fzf jq gh; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$dep"
        chmod +x "$STUB_BIN/$dep"
    done
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    teardown_test_dirs
}

# Run the fixture checkout's install.sh with stdin closed, so a prompt would
# fail loudly instead of hanging
# Args: $1 SHELL value, $2... install.sh arguments
# Side: sets bats' $status, $output (stdout) and $stderr
_run_install() {
    local shell="$1"
    shift
    run --separate-stderr env HOME="$HOME_DIR" SHELL="$shell" \
        bash -c 'exec "$0" "$@" </dev/null' "$CHECKOUT/install.sh" "$@"
}

# Split case labels ("a|b)") on stdin into one sorted, unique alternative per line
# Out: the alternatives
_split_labels() {
    tr -d ') ' | tr '|' '\n' | grep -vx '\*' | sort -u
}

# List the `wt <word>` subcommands the dispatcher's case labels accept
# Out: one word per line
_dispatcher_words() {
    sed -n '/case "\$command" in/,/^esac/p' "$WT_SCRIPT_DIR/wt.sh" \
        | grep -oE '^\s*[A-Za-z_|*-]+\)' \
        | _split_labels
}

# List the flags parse_args' case block accepts
# Out: one flag per line
_parser_flags() {
    sed -n '/^parse_args() {/,/^}/p' "$WT_SCRIPT_DIR/install.sh" \
        | grep -oE '^ *(-h|--[a-z-]+)(\|(-h|--[a-z-]+))*\)' \
        | _split_labels
}

@test "install: reproduction — fresh HOME links zsh completions, names no wt new, --bogus and --prefix each exit 2" {
    _run_install /bin/zsh
    [ "$status" -eq 0 ]
    [[ "$output" != *"wt new"* ]]

    run readlink "$HOME_DIR/.zsh/completions/_wt"
    [ "$status" -eq 0 ]
    [ "$output" = "$CHECKOUT/completions/wt.zsh" ]

    ! grep -q 'wt new' "$CHECKOUT/install.sh"

    _run_install /bin/zsh --bogus
    [ "$status" -eq 2 ]

    _run_install /bin/zsh --prefix
    [ "$status" -eq 2 ]
}

@test "install: every completion file installed, zsh and bash, is a symlink into the checkout's completions/" {
    _run_install /bin/zsh
    [ "$status" -eq 0 ]
    [ -L "$HOME_DIR/.zsh/completions/_wt" ]
    [ "$(readlink "$HOME_DIR/.zsh/completions/_wt")" = "$CHECKOUT/completions/wt.zsh" ]

    HOME_DIR="$TEST_TMPDIR/home-bash"
    mkdir -p "$HOME_DIR"
    _run_install /bin/bash
    [ "$status" -eq 0 ]
    [ -L "$HOME_DIR/.local/share/bash-completion/completions/wt" ]
    [ "$(readlink "$HOME_DIR/.local/share/bash-completion/completions/wt")" = "$CHECKOUT/completions/wt.bash" ]
}

@test "install: a checkout completions/ edit shows through the installed path with no reinstall" {
    _run_install /bin/zsh
    [ "$status" -eq 0 ]

    local before after
    before="$(cat "$HOME_DIR/.zsh/completions/_wt")"
    printf '\n# marker-for-test\n' >> "$CHECKOUT/completions/wt.zsh"
    after="$(cat "$HOME_DIR/.zsh/completions/_wt")"

    [ "$before" != "$after" ]
    [[ "$after" == *"marker-for-test"* ]]
}

@test "install: every 'wt <command>' install.sh names is a subcommand wt.sh's dispatcher accepts" {
    local valid mentioned word found=1
    valid=$(_dispatcher_words)
    mentioned=$(grep -oE 'wt [a-z][a-z-]*' "$WT_SCRIPT_DIR/install.sh" | awk '{print $2}' | sort -u)

    while IFS= read -r word; do
        [ -z "$word" ] && continue
        echo "$valid" | grep -qx "$word" || { echo "not a dispatcher command: wt $word" >&2; found=0; }
    done <<< "$mentioned"

    [ "$found" -eq 1 ]
    ! echo "$mentioned" | grep -qx 'new'
}

@test "install: an unknown flag stops with exit 2, names it on stderr with ./install.sh --help, before anything lands under HOME" {
    _run_install /bin/zsh --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--bogus"* ]]
    [[ "$stderr" == *"./install.sh --help"* ]]
    [ -z "$output" ]
    [ -z "$(ls -A "$HOME_DIR")" ]
}

@test "install: a stray positional argument stops with exit 2 and nothing lands under HOME" {
    _run_install /bin/zsh extra-positional
    [ "$status" -eq 2 ]
    [ -z "$(ls -A "$HOME_DIR")" ]
}

@test "install: --prefix with no value stops with exit 2 naming '--prefix <dir>', no unbound-variable error, on stderr" {
    _run_install /bin/zsh --prefix
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--prefix <dir>"* ]]
    [[ "$stderr" != *"unbound variable"* ]]
    [ -z "$output" ]
    [ -z "$(ls -A "$HOME_DIR")" ]
}

@test "install: --prefix with an empty value stops with exit 2 naming '--prefix <dir>', on stderr" {
    _run_install /bin/zsh --prefix ""
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--prefix <dir>"* ]]
    [ -z "$output" ]
    [ -z "$(ls -A "$HOME_DIR")" ]
}

@test "install: --help lists exactly the flags the parser accepts, with an opening sentence, defaults and exit codes" {
    local parser_flags help_flags first_desc_line
    parser_flags="$(_parser_flags)"

    _run_install /bin/zsh --help
    [ "$status" -eq 0 ]

    [[ "$output" == "Usage: ./install.sh [options]"* ]]
    first_desc_line="$(echo "$output" | sed -n '3p')"
    [[ "$first_desc_line" == *"Symlinks wt.sh onto your PATH"* ]]
    [[ "$output" == *"default: ~/bin"* ]]
    [[ "$output" == *"0"*"installed"* ]]
    [[ "$output" == *"1"*"aborted"* ]]
    [[ "$output" == *"2"*"usage error"* ]]

    help_flags="$(echo "$output" | grep -oE -- '(-h|--[a-z-]+)' | sort -u)"
    [ "$parser_flags" = "$help_flags" ]
}

@test "install: re-running over an existing symlink leaves a working symlink and exits 0" {
    _run_install /bin/zsh
    [ "$status" -eq 0 ]

    _run_install /bin/zsh
    [ "$status" -eq 0 ]
    [ -L "$HOME_DIR/.zsh/completions/_wt" ]
    [ "$(readlink "$HOME_DIR/.zsh/completions/_wt")" = "$CHECKOUT/completions/wt.zsh" ]
}

@test "install: re-running over an old regular-file completion copy replaces it with a working symlink and exits 0" {
    mkdir -p "$HOME_DIR/.zsh/completions"
    echo "stale copy" > "$HOME_DIR/.zsh/completions/_wt"

    _run_install /bin/zsh
    [ "$status" -eq 0 ]
    [ -L "$HOME_DIR/.zsh/completions/_wt" ]
    [ "$(readlink "$HOME_DIR/.zsh/completions/_wt")" = "$CHECKOUT/completions/wt.zsh" ]
}

@test "install: running against the fixture checkout leaves this repo's tracked install files untouched" {
    local before after
    before="$(git -C "$WT_SCRIPT_DIR" status --porcelain -- lib commands completions install.sh wt.sh)"

    _run_install /bin/zsh
    [ "$status" -eq 0 ]

    after="$(git -C "$WT_SCRIPT_DIR" status --porcelain -- lib commands completions install.sh wt.sh)"
    [ "$before" = "$after" ]
}
