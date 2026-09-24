#!/usr/bin/env bats
# tests/test_json.bats - Unit tests for lib/json.sh

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "json"
}

teardown() {
    teardown_test_dirs
}

# json_begin's `exec 3>&1 1>&2` must never run in the bats test process itself
# — bats reserves fd 3 for its own bookkeeping, so every call below runs
# json_begin/json_set/json_emit inside a subshell via command substitution,
# the same isolation a real command gets by being its own process.

# --- string escaping round-trips ---

@test "json_set str round-trips a double quote" {
    doc=$(json_begin; json_set ".x" str 'a "quoted" value'; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == 'a "quoted" value' ]]
}

@test "json_set str round-trips a backslash" {
    doc=$(json_begin; json_set ".x" str 'a\backslash'; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == 'a\backslash' ]]
}

@test "json_set str round-trips a tab and a newline" {
    doc=$(json_begin; json_set ".x" str "$(printf 'a\tb\nc')"; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == "$(printf 'a\tb\nc')" ]]
}

@test "json_set str round-trips a control character" {
    doc=$(json_begin; json_set ".x" str "$(printf 'a\x01b')"; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == "$(printf 'a\x01b')" ]]
}

@test "json_set str round-trips unicode" {
    doc=$(json_begin; json_set ".x" str 'café 日本語'; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == 'café 日本語' ]]
}

@test "json_set str round-trips a value with spaces" {
    doc=$(json_begin; json_set ".x" str 'a value with spaces'; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$result" == 'a value with spaces' ]]
}

# --- int/bool/null typing ---

@test "json_set int emits a JSON number" {
    doc=$(json_begin; json_set ".x" int "42"; json_emit)
    type=$(printf '%s' "$doc" | yq -p json '.x | type')
    value=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$type" == "!!int" ]]
    [[ "$value" == "42" ]]
}

@test "json_set int with an empty value emits null" {
    doc=$(json_begin; json_set ".x" int ""; json_emit)
    type=$(printf '%s' "$doc" | yq -p json '.x | type')
    [[ "$type" == "!!null" ]]
}

@test "json_set int with a non-numeric value dies" {
    WTJ_EXPRS=()
    WTJ_PAIRS=()
    WTJ_N=0
    run json_set ".x" int "not-a-number"
    [[ "$status" -ne 0 ]]
}

@test "json_set bool emits a JSON boolean, not a string or 0/1" {
    doc=$(json_begin; json_set ".x" bool "true"; json_emit)
    type=$(printf '%s' "$doc" | yq -p json '.x | type')
    value=$(printf '%s' "$doc" | yq -p json '.x')
    [[ "$type" == "!!bool" ]]
    [[ "$value" == "true" ]]
}

@test "json_set bool normalises 0/1 to JSON booleans" {
    doc=$(json_begin; json_set ".a" bool "1"; json_set ".b" bool "0"; json_emit)
    a=$(printf '%s' "$doc" | yq -p json '.a')
    b=$(printf '%s' "$doc" | yq -p json '.b')
    [[ "$a" == "true" ]]
    [[ "$b" == "false" ]]
}

@test "json_set null emits a JSON null" {
    doc=$(json_begin; json_set ".x" null; json_emit)
    type=$(printf '%s' "$doc" | yq -p json '.x | type')
    [[ "$type" == "!!null" ]]
}

# --- arr/obj empties ---

@test "json_set arr emits an empty array" {
    doc=$(json_begin; json_set ".x" arr; json_emit)
    result=$(printf '%s' "$doc" | yq -p json -o json '.x')
    [[ "$result" == "[]" ]]
}

@test "json_set obj emits an empty object" {
    doc=$(json_begin; json_set ".x" obj; json_emit)
    result=$(printf '%s' "$doc" | yq -p json -o json '.x')
    [[ "$result" == "{}" ]]
}

# --- nested arrays of objects ---

@test "json_set builds a nested array of objects" {
    doc=$(json_begin
        json_set ".projects[0].worktrees[0].branch" str "feature/a"
        json_set ".projects[0].worktrees[1].branch" str "feature/b"
        json_emit)
    b0=$(printf '%s' "$doc" | yq -p json '.projects[0].worktrees[0].branch')
    b1=$(printf '%s' "$doc" | yq -p json '.projects[0].worktrees[1].branch')
    [[ "$b0" == "feature/a" ]]
    [[ "$b1" == "feature/b" ]]
}

# --- json_set_key ---

@test "json_set_key handles a key containing a dot" {
    doc=$(json_begin; json_set_key ".env" "FRONTEND.PORT" str "3000"; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.env["FRONTEND.PORT"]')
    [[ "$result" == "3000" ]]
}

@test "json_set_key handles a key containing a double quote" {
    doc=$(json_begin; json_set_key ".env" 'WEIRD"KEY' str "value"; json_emit)
    result=$(printf '%s' "$doc" | yq -p json '.env["WEIRD\"KEY"]')
    [[ "$result" == "value" ]]
}

# --- ts: valid ---

@test "json_set ts on a valid timestamp computes the right epoch" {
    doc=$(json_begin; json_set ".x.created_at" ts "2026-01-02T03:04:05Z"; json_emit)
    epoch=$(printf '%s' "$doc" | yq -p json '.x.created_at_epoch')
    [[ "$epoch" == "1767323045" ]]
}

@test "json_set ts on a valid timestamp keeps the stored string and a non-null local rendering" {
    doc=$(json_begin; json_set ".x.created_at" ts "2026-01-02T03:04:05Z"; json_emit)
    stored=$(printf '%s' "$doc" | yq -p json '.x.created_at')
    local_type=$(printf '%s' "$doc" | yq -p json '.x.created_at_local | type')
    [[ "$stored" == "2026-01-02T03:04:05Z" ]]
    [[ "$local_type" == "!!str" ]]
}

# --- ts: malformed / empty ---

@test "json_set ts on a malformed value keeps the raw string but nulls epoch and local" {
    doc=$(json_begin; json_set ".x.created_at" ts "not-a-timestamp"; json_emit)
    stored=$(printf '%s' "$doc" | yq -p json '.x.created_at')
    epoch_type=$(printf '%s' "$doc" | yq -p json '.x.created_at_epoch | type')
    local_type=$(printf '%s' "$doc" | yq -p json '.x.created_at_local | type')
    [[ "$stored" == "not-a-timestamp" ]]
    [[ "$epoch_type" == "!!null" ]]
    [[ "$local_type" == "!!null" ]]
}

@test "json_set ts on an empty value nulls all three keys" {
    doc=$(json_begin; json_set ".x.created_at" ts ""; json_emit)
    stored_type=$(printf '%s' "$doc" | yq -p json '.x.created_at | type')
    epoch_type=$(printf '%s' "$doc" | yq -p json '.x.created_at_epoch | type')
    local_type=$(printf '%s' "$doc" | yq -p json '.x.created_at_local | type')
    [[ "$stored_type" == "!!null" ]]
    [[ "$epoch_type" == "!!null" ]]
    [[ "$local_type" == "!!null" ]]
}

# --- key order ---

@test "json_emit preserves key insertion order" {
    doc=$(json_begin; json_set ".z" str "last-declared-first"; json_set ".a" str "second"; json_emit)
    keys=$(printf '%s' "$doc" | yq -p json -o json 'keys | join(",")')
    [[ "$keys" == '"z,a"' ]]
}

@test "an empty collector emits an empty object" {
    doc=$(json_begin; json_emit)
    [[ "$doc" == "{}" ]]
}

# --- the fd guard ---

@test "a stray echo between json_begin and json_emit lands on stderr, not stdout" {
    run --separate-stderr bash -c '
        source "$WT_SCRIPT_DIR/lib/utils.sh"
        source "$WT_SCRIPT_DIR/lib/json.sh"
        json_begin
        echo "junk"
        json_set ".x" str "value"
        json_emit
    '
    [[ "$stderr" == *"junk"* ]]
    [[ "$output" != *"junk"* ]]
    value=$(printf '%s' "$output" | yq -p json '.x')
    [[ "$value" == "value" ]]
}

# --- note_optional_missing stays off stdout ---

@test "note_optional_missing prints nothing on stdout, and warns on stderr" {
    run --separate-stderr env WT_WARN_DEPS=true WT_SCRIPT_DIR="$WT_SCRIPT_DIR" bash -c '
        source "$WT_SCRIPT_DIR/lib/utils.sh"
        note_optional_missing gh "pr_lookup reports unavailable"
    ' < /dev/null
    [[ "$output" == "" ]]
    [[ "$stderr" == *"gh"* ]]
}
