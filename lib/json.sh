#!/bin/bash
# lib/json.sh - Shared yq-backed JSON emitter for wt's --json commands
#
# A caller builds a document with json_set/json_set_key calls, then flushes it
# with json_emit. json_begin redirects the real stdout to fd 3 and routes fd 1
# to stderr, so a stray echo between begin and emit lands where diagnostics
# belong instead of corrupting the JSON stream; json_emit is the only function
# that writes to fd 3, and it restores stdout to fd 1 before returning.
# bash 3.2 compatible: no namerefs, no associative arrays, no ${var,,}.

# Reset the pending document and take over stdout for the JSON emitter.
# Side: resets WTJ_EXPRS/WTJ_PAIRS/WTJ_N, then `exec 3>&1 1>&2` — every plain
#       echo from here until json_emit lands on stderr, not on the real stdout
json_begin() {
    WTJ_EXPRS=()
    WTJ_PAIRS=()
    WTJ_N=0
    exec 3>&1 1>&2
}

# Reserve the next WTJ_<n> env slot for one value, queuing it for json_emit's
# `env` call. Sets _JSON_RESERVED rather than returning on stdout: every
# caller runs in the same process as json_begin/json_emit, and a `$(...)`
# capture here would fork a subshell whose WTJ_PAIRS append never reaches the
# caller's array.
# Args: $1 value to carry through the environment
# Side: appends "WTJ_<n>=<value>" to WTJ_PAIRS; sets _JSON_RESERVED to the
#       reserved variable name (WTJ_<n>)
_json_reserve() {
    WTJ_N=$((WTJ_N + 1))
    _JSON_RESERVED="WTJ_${WTJ_N}"
    WTJ_PAIRS+=("${_JSON_RESERVED}=${1}")
}

# Record a string assignment.
# Args: $1 yq path, $2 value
# Side: appends to WTJ_EXPRS/WTJ_PAIRS
_json_set_str() {
    local path="$1"
    local value="$2"
    _json_reserve "$value"
    WTJ_EXPRS+=("${path} = strenv(${_JSON_RESERVED})")
}

# Record an integer assignment; empty becomes null, non-numeric dies (a
# programming error in the caller, not a data problem).
# Args: $1 yq path, $2 value
# Side: appends to WTJ_EXPRS/WTJ_PAIRS, or calls die
_json_set_int() {
    local path="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        WTJ_EXPRS+=("${path} = null")
        return
    fi

    [[ "$value" =~ ^-?[0-9]+$ ]] || die "json_set: non-numeric int '$value' for path '$path'"

    _json_reserve "$value"
    WTJ_EXPRS+=("${path} = (strenv(${_JSON_RESERVED}) | tonumber)")
}

# Record a boolean assignment. Accepts true/false/1/0 and normalises to the
# JSON boolean literal.
# Args: $1 yq path, $2 value (true|false|1|0)
# Side: appends to WTJ_EXPRS/WTJ_PAIRS, or calls die on any other value
_json_set_bool() {
    local path="$1"
    local value="$2"

    case "$value" in
        true|1) value="true" ;;
        false|0) value="false" ;;
        *) die "json_set: invalid bool '$value' for path '$path'" ;;
    esac

    _json_reserve "$value"
    WTJ_EXPRS+=("${path} = (strenv(${_JSON_RESERVED}) == \"true\")")
}

# Record a timestamp assignment as three sibling keys: the stored string, its
# epoch seconds, and its local ISO-8601 rendering. A value that does not match
# the stored timestamp shape keeps its raw string under the plain key and
# nulls the two derived ones, rather than dying — a malformed stored value is
# data to report, not a programming error.
# Args: $1 yq path ending in the timestamp key (e.g. ".x.created_at"), $2 value
# Side: appends three assignments (<key>, <key>_epoch, <key>_local) to
#       WTJ_EXPRS/WTJ_PAIRS
_json_set_ts() {
    local path="$1"
    local value="$2"
    local key="${path##*.}"
    local parent="${path%.*}"
    local iso_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

    if [[ -z "$value" ]]; then
        WTJ_EXPRS+=("${parent}.${key} = null")
        WTJ_EXPRS+=("${parent}.${key}_epoch = null")
        WTJ_EXPRS+=("${parent}.${key}_local = null")
        return
    fi

    _json_reserve "$value"
    local var="$_JSON_RESERVED"
    WTJ_EXPRS+=("${parent}.${key} = strenv(${var})")

    if [[ "$value" =~ $iso_re ]]; then
        WTJ_EXPRS+=("${parent}.${key}_epoch = (strenv(${var}) | to_unix)")
        WTJ_EXPRS+=("${parent}.${key}_local = (strenv(${var}) | tz(\"Local\"))")
    else
        WTJ_EXPRS+=("${parent}.${key}_epoch = null")
        WTJ_EXPRS+=("${parent}.${key}_local = null")
    fi
}

# Record one assignment in the pending document.
# Args: $1 yq path (e.g. ".projects[0].worktrees[2].branch"),
#       $2 type (str|int|bool|null|ts|arr|obj),
#       $3 value (required for str/int/bool/ts; ignored for null/arr/obj)
# Side: appends to WTJ_EXPRS/WTJ_PAIRS, consumed by json_emit; calls die on an
#       unknown type or an invalid int/bool value
json_set() {
    local path="$1"
    local type="$2"
    local value="${3:-}"

    case "$type" in
        str)  _json_set_str "$path" "$value" ;;
        int)  _json_set_int "$path" "$value" ;;
        bool) _json_set_bool "$path" "$value" ;;
        null) WTJ_EXPRS+=("${path} = null") ;;
        ts)   _json_set_ts "$path" "$value" ;;
        arr)  WTJ_EXPRS+=("${path} = []") ;;
        obj)  WTJ_EXPRS+=("${path} = {}") ;;
        *)    die "json_set: unknown type '$type' for path '$path'" ;;
    esac
}

# Record one assignment under a key that comes from user data (an env var
# name, say) rather than from a literal the caller wrote — the key itself is
# routed through strenv so a "." or a quote inside it cannot reshape the path.
# Args: $1 yq path to the parent object, $2 key, $3 type, $4 value
# Side: same as json_set
json_set_key() {
    local path="$1"
    local key="$2"
    local type="$3"
    local value="${4:-}"

    _json_reserve "$key"
    json_set "${path}[strenv(${_JSON_RESERVED})]" "$type" "$value"
}

# Flush the pending document as one JSON object on the real stdout (fd 3),
# then hand stdout back to the rest of the command.
# Out: the emitted JSON document, on the real stdout
# Side: runs one `yq -n -o json`, restores `exec 1>&3 3>&-`
# Returns: yq's own exit status
json_emit() {
    local expr=""
    local e

    for e in "${WTJ_EXPRS[@]+"${WTJ_EXPRS[@]}"}"; do
        if [[ -z "$expr" ]]; then
            expr="$e"
        else
            expr="$expr | $e"
        fi
    done
    [[ -z "$expr" ]] && expr="{}"

    local rc=0
    env "${WTJ_PAIRS[@]+"${WTJ_PAIRS[@]}"}" yq -n -o json "$expr" >&3 || rc=$?
    exec 1>&3 3>&-
    return $rc
}
