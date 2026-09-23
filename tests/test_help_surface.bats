#!/usr/bin/env bats
# tests/test_help_surface.bats - the code-derived help-surface test: every
# command, subcommand and flag `wt.sh`/`commands/*.sh` dispatch has to carry a
# --help page with a description, its flags documented, and an Exit codes:
# block, or `wt_surface_check` names the missing one by word and flag.

load test_helper
load help_surface

setup() {
    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    teardown_test_dirs
}

# Copy wt.sh, lib/, commands/, README.md and completions/ into a fresh
# directory so a control can mutate a page, a parser, README's command
# tables or a completion script without touching the real source tree.
# Args: $1 destination directory (created if absent)
_copy_wt_tree() {
    local dest="$1"
    mkdir -p "$dest"
    cp "$WT_SCRIPT_DIR/wt.sh" "$dest/wt.sh"
    cp -R "$WT_SCRIPT_DIR/lib" "$dest/lib"
    cp -R "$WT_SCRIPT_DIR/commands" "$dest/commands"
    cp "$WT_SCRIPT_DIR/README.md" "$dest/README.md"
    cp -R "$WT_SCRIPT_DIR/completions" "$dest/completions"
}

# Rewrite a fixture copy's commands/attach.sh into a page that conforms to
# every rule wt_surface_check enforces — a description paragraph, both flags
# carrying a <placeholder> and a default:, an Exit codes: block, and the
# standard unknown-option line — so a control's mutation is the only thing
# that can still make it fail.
# Args: $1 fixture root (as built by _copy_wt_tree)
_make_attach_conform() {
    local root="$1"
    cat > "$root/commands/attach.sh" <<'EOF'
#!/bin/bash
# commands/attach.sh - Attach to a worktree's tmux session

cmd_attach() {
    local branch=""
    local window=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--window)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                window="$2"
                shift 2
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_attach_help
                return 0
                ;;
            -*)
                die_unknown_option "attach" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        branch=$(detect_worktree_branch)
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required"
            show_attach_help
            return 1
        fi
        log_info "Detected worktree branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local window_name
    window_name=$(get_session_name "$project" "$branch")

    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    if ! session_exists "$tmux_session" || ! window_exists "$tmux_session" "$window_name"; then
        if worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
            log_info "Window not found, creating..."
            local wt_path
            wt_path=$(get_worktree_path "$project" "$branch")
            create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE" "$window"
        else
            die "No worktree found for branch: $branch"
        fi
    fi

    attach_session "$window_name" "$PROJECT_CONFIG_FILE"
}

show_attach_help() {
    cat << 'PAGE'
Attaches to a worktree's tmux session, creating the window first when none exists yet.

Usage: wt attach <branch> [options]

Arguments:
  <branch>          Branch name of the worktree (required)

Options:
  -w, --window <index>   Create the window at a specific index (default: next free index)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt attach feature/auth              # attach, creating the window if needed
  wt attach feature/auth -w 2         # create at window index 2

Exit codes:
  0  success
  1  no worktree found for the branch
  2  usage error: unknown option or missing argument
PAGE
}
EOF
}

# Wrap a conforming attach fixture's own -w/--window Options entry and its
# exit-code-1 line onto a second physical line each, indented deeper than the
# entry they continue and starting with neither a flag token nor a digit —
# the shape _wt_fold_continuations folds back onto the entry above it.
# Args: $1 fixture root (as built by _make_attach_conform)
_wrap_attach_page() {
    local root="$1"
    awk '
        /^  -w, --window <index>   Create the window at a specific index \(default: next free index\)$/ {
            print "  -w, --window <index>   Create the window at a specific index"
            print "                          (default: next free index)"
            next
        }
        /^  1  no worktree found for the branch$/ {
            print "  1  no worktree found"
            print "     for the branch"
            next
        }
        { print }
    ' "$root/commands/attach.sh" > "$root/commands/attach.sh.tmp"
    mv "$root/commands/attach.sh.tmp" "$root/commands/attach.sh"
}

# b81cc62 is the commit before this effort's page contract and command changes
# landed — the tree the surface test above (real tree, zero violations) is
# graded against. On a shallow clone (Linux CI's actions/checkout@v4 defaults
# to depth 1) that commit is not in the object store, so this test skips
# rather than failing on an artifact of the checkout depth.
@test "wt_surface_check reports violations on the pre-change tree" {
    if ! git -C "$WT_SCRIPT_DIR" cat-file -e b81cc62^{commit} 2>/dev/null; then
        skip "b81cc62 not in the object store (shallow clone)"
    fi
    local base_dir="$TEST_TMPDIR/base"
    mkdir -p "$base_dir"
    git -C "$WT_SCRIPT_DIR" archive b81cc62 wt.sh lib commands | tar -x -C "$base_dir"

    run wt_surface_check "$base_dir"
    [[ "$status" -ne 0 ]]
    local count
    count=$(printf '%s\n' "$output" | grep -c '^VIOLATION')
    [[ "$count" -gt 0 ]]
}

@test "wt_surface_check exits 0 with zero violations on the real tree" {
    run wt_surface_check "$WT_SCRIPT_DIR"
    echo "$output"
    [[ "$status" -eq 0 ]]
    local count
    count=$(printf '%s\n' "$output" | grep -c '^VIOLATION' || true)
    [[ "$count" -eq 0 ]]
}

@test "wt_surface_list discovers every subcommand from source" {
    run wt_surface_list "$WT_SCRIPT_DIR"
    [[ "$output" == *"db reset"* ]]
    [[ "$output" == *"db use-remote,detach"* ]]
    [[ "$output" == *"db dump"* ]]
    [[ "$output" == *"db url"* ]]
    [[ "$output" == *"pr conflicts,c"* ]]
    [[ "$output" == *"pr resolve"* ]]
    [[ "$output" == *"ports set"* ]]
    [[ "$output" == *"ports clear"* ]]
}

@test "control: an undocumented flag added to cmd_attach is caught by name" {
    local fixture="$TEST_TMPDIR/control-flag"
    _copy_wt_tree "$fixture"
    _make_attach_conform "$fixture"

    awk '
        /^            -h\|--help\)$/ && !done {
            print "            --surface-probe)"
            print "                shift"
            print "                ;;"
            done = 1
        }
        { print }
    ' "$fixture/commands/attach.sh" > "$fixture/commands/attach.sh.tmp"
    mv "$fixture/commands/attach.sh.tmp" "$fixture/commands/attach.sh"

    run wt_surface_check "$fixture" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--surface-probe is not listed in Options:"* ]]
}

@test "an arm refusing its flag through die_unknown_option is owed no Options: line" {
    run _wt_emit_arm "-s | --status" "die_unknown_option \"ls\" \"\$1\" \"use -q\""$'\n'
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]

    # control: the same header with a live body is surface
    run _wt_emit_arm "-s | --status" "smart_quick=false"$'\n'"shift"$'\n'
    [[ "$output" == *$'FLAG\t-s\t0'* ]]
    [[ "$output" == *$'FLAG\t--status\t0'* ]]
}

@test "control: a page missing its Exit codes: block is caught by name" {
    local fixture="$TEST_TMPDIR/control-exitcodes"
    _copy_wt_tree "$fixture"
    _make_attach_conform "$fixture"

    awk '
        BEGIN { skip = 0 }
        /^Exit codes:$/ { skip = 1; next }
        skip == 1 && /^PAGE$/ { skip = 0 }
        skip == 1 { next }
        { print }
    ' "$fixture/commands/attach.sh" > "$fixture/commands/attach.sh.tmp"
    mv "$fixture/commands/attach.sh.tmp" "$fixture/commands/attach.sh"

    run wt_surface_check "$fixture" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"attach,a: no Exit codes: block"* ]]
}

@test "control: a page missing its description paragraph is caught by name" {
    local fixture="$TEST_TMPDIR/control-description"
    _copy_wt_tree "$fixture"
    _make_attach_conform "$fixture"

    awk '
        /^Attaches to a worktree/ { next }
        { print }
    ' "$fixture/commands/attach.sh" > "$fixture/commands/attach.sh.tmp"
    mv "$fixture/commands/attach.sh.tmp" "$fixture/commands/attach.sh"

    run wt_surface_check "$fixture" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"attach,a: first non-blank line is not a description ending in '.'"* ]]
}

@test "control: a wrapped Options entry and a wrapped exit-code line pass" {
    local fixture="$TEST_TMPDIR/control-wrapped-pass"
    _copy_wt_tree "$fixture"
    _make_attach_conform "$fixture"
    _wrap_attach_page "$fixture"

    run wt_surface_check "$fixture" attach
    [[ "$status" -eq 0 ]]
    local count
    count=$(printf '%s\n' "$output" | grep -c '^VIOLATION' || true)
    [[ "$count" -eq 0 ]]
}

@test "control: a wrapped continuation line never hides an undocumented flag" {
    local fixture="$TEST_TMPDIR/control-wrapped-hide"
    _copy_wt_tree "$fixture"
    _make_attach_conform "$fixture"
    _wrap_attach_page "$fixture"

    awk '
        /^            -h\|--help\)$/ && !done {
            print "            --surface-probe)"
            print "                shift"
            print "                ;;"
            done = 1
        }
        { print }
    ' "$fixture/commands/attach.sh" > "$fixture/commands/attach.sh.tmp"
    mv "$fixture/commands/attach.sh.tmp" "$fixture/commands/attach.sh"

    run wt_surface_check "$fixture" attach
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--surface-probe is not listed in Options:"* ]]
}

@test "wt --help exits 0 with yq and tmux absent and creates no directory (C2)" {
    local shim home_dir
    shim="$TEST_TMPDIR/shim"
    home_dir="$TEST_TMPDIR/home"
    mkdir -p "$home_dir"
    _wt_build_help_shim "$shim"

    local out="$TEST_TMPDIR/out.txt"
    _wt_run_help_probe "$WT_SCRIPT_DIR" "$shim" "$home_dir" "$out" --help
    [[ "$?" -eq 0 ]]

    local created
    created=$(find "$home_dir" -mindepth 1 2>/dev/null | wc -l)
    [[ "$created" -eq 0 ]]
}

@test "wt --help under the help shim never calls yq or tmux (C2)" {
    local shim="$TEST_TMPDIR/shim2"
    _wt_build_help_shim "$shim"
    run env -i PATH="$shim" bash -c 'command -v yq'
    [[ "$status" -ne 0 ]]
    run env -i PATH="$shim" bash -c 'command -v tmux'
    [[ "$status" -ne 0 ]]
}

@test "wt --help opens on a purpose sentence and a stated non-goal, not a version banner (C14)" {
    run "$WT_SCRIPT_DIR/wt.sh" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" != version* ]]
    [[ "$output" == *"never removes a worktree without confirming"* ]]
    [[ "$output" == *"Usage: wt <command>"* ]]
    [[ "$output" == *"db"* ]]
    [[ "$output" == *"Environment:"* ]]
    [[ "$output" == *"https://github.com/yann-lauwers/tmux-worktree-manager/issues"* ]]
    [[ "$output" == *"Exit codes:"* ]]
    local example_count
    example_count=$(printf '%s\n' "$output" | grep -cE '^\s*wt .*#')
    [[ "$example_count" -ge 2 ]]
    [[ "$example_count" -le 4 ]]
}

@test "wt --help never mentions verbose, and -p/--project is gone from the top-level page (C15)" {
    run "$WT_SCRIPT_DIR/wt.sh" --help
    [[ "$status" -eq 0 ]]
    run grep -ic verbose "$WT_SCRIPT_DIR/wt.sh"
    [[ "$output" == "0" ]]
}

@test "wt_surface_docs_check exits 0 with zero violations on the real tree" {
    run wt_surface_docs_check "$WT_SCRIPT_DIR"
    echo "$output"
    [[ "$status" -eq 0 ]]
    local count
    count=$(printf '%s\n' "$output" | grep -c '^VIOLATION' || true)
    [[ "$count" -eq 0 ]]
}

@test "control: a command removed from README's tables is caught by name" {
    local fixture="$TEST_TMPDIR/control-readme"
    _copy_wt_tree "$fixture"

    awk '/`wt doctor`/ { next } { print }' "$fixture/README.md" > "$fixture/README.md.tmp"
    mv "$fixture/README.md.tmp" "$fixture/README.md"

    run wt_surface_docs_check "$fixture"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"VIOLATION doctor: not in README.md's command tables"* ]]
}

@test "control: a word removed from the bash completion is caught by name" {
    local fixture="$TEST_TMPDIR/control-bash"
    _copy_wt_tree "$fixture"

    sed -i.bak 's/ hc / /' "$fixture/completions/wt.bash"
    rm -f "$fixture/completions/wt.bash.bak"

    run wt_surface_docs_check "$fixture"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"VIOLATION hc: not offered by completions/wt.bash"* ]]
}

@test "control: an entry removed from the zsh completion is caught by name" {
    local fixture="$TEST_TMPDIR/control-zsh"
    _copy_wt_tree "$fixture"

    awk '/^        .db:Manage a worktree/ { next } { print }' "$fixture/completions/wt.zsh" > "$fixture/completions/wt.zsh.tmp"
    mv "$fixture/completions/wt.zsh.tmp" "$fixture/completions/wt.zsh"

    run wt_surface_docs_check "$fixture"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"VIOLATION db: not offered by completions/wt.zsh"* ]]
}

@test "control: README is checked by canonical name, so an alias row does not stand in for it" {
    local fixture="$TEST_TMPDIR/control-alias"
    _copy_wt_tree "$fixture"

    sed -i.bak 's/`wt status /`wt st /' "$fixture/README.md"
    rm -f "$fixture/README.md.bak"

    run wt_surface_docs_check "$fixture"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"VIOLATION status: not in README.md's command tables"* ]]
    [[ "$output" != *"VIOLATION st:"* ]]
    [[ "$output" != *"VIOLATION up:"* ]]
}

@test "start -a/--all is gone from both completion scripts" {
    run grep -n "start|up)" -A 4 "$WT_SCRIPT_DIR/completions/wt.bash"
    [[ "$output" != *"-a --all"* ]]
    run grep -n "start|up)" -A 8 "$WT_SCRIPT_DIR/completions/wt.zsh"
    [[ "$output" != *"'(-a --all)'"* ]]
}

@test "_wt_help_requested takes the early path for a subcommand's own --help (C2)" {
    run bash -c "
        source '$WT_SCRIPT_DIR/wt.sh' || true
        _wt_help_requested db reset --help && echo 'db reset: yes' || echo 'db reset: no'
        _wt_help_requested pr conflicts --help && echo 'pr conflicts: yes' || echo 'pr conflicts: no'
        _wt_help_requested ports set --help && echo 'ports set: yes' || echo 'ports set: no'
    "
    [[ "$output" == *"db reset: yes"* ]]
    [[ "$output" == *"pr conflicts: yes"* ]]
    [[ "$output" == *"ports set: yes"* ]]
}

@test "wt exec <branch> <cmd> -h reaches the wrapped command, not wt's own help" {
    run bash -c "
        source '$WT_SCRIPT_DIR/wt.sh' || true
        _wt_help_requested exec somebranch somecmd -h && echo 'exec: yes' || echo 'exec: no'
        _wt_help_requested send somebranch someservice -h && echo 'send: yes' || echo 'send: no'
    "
    [[ "$output" == *"exec: no"* ]]
    [[ "$output" == *"send: no"* ]]
}
