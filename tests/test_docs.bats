#!/usr/bin/env bats
# tests/test_docs.bats - COMMANDS.md must stay in sync with the source doc-comments.
#
# The doc-comment above each function is the single source of truth; COMMANDS.md is
# generated from it. This fails if the committed COMMANDS.md drifts from what the
# current source would produce — run `scripts/gen-docs.sh --write` to regenerate.

load test_helper

@test "COMMANDS.md is up to date with the source doc-comments" {
    run bash "$WT_SCRIPT_DIR/scripts/gen-docs.sh" --check
    [[ "$status" -eq 0 ]]
}

@test "COMMANDS.md lists the command surface and function index" {
    run bash "$WT_SCRIPT_DIR/scripts/gen-docs.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Commands"* ]]
    [[ "$output" == *"wt create"* ]]
    [[ "$output" == *"wt doctor"* ]]
    [[ "$output" == *"## Functions by file"* ]]
}

@test "every public function carries a doc-comment purpose (none missing from the index)" {
    # Public = not a _private helper and not a show_*_help emitter.
    local defined indexed missing
    defined=$(grep -rhoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' \
        "$WT_SCRIPT_DIR"/commands/*.sh "$WT_SCRIPT_DIR"/lib/*.sh "$WT_SCRIPT_DIR"/wt.sh \
        | sed 's/()//' | grep -vE '^_|^show_' | sort -u)
    indexed=$(bash "$WT_SCRIPT_DIR/scripts/gen-docs.sh" | grep -oE '`[a-zA-Z_][a-zA-Z0-9_]*`' | tr -d '`' | sort -u)
    missing=$(comm -23 <(echo "$defined") <(echo "$indexed"))
    [[ -z "$missing" ]]
}
