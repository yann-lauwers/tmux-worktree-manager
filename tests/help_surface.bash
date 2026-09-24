#!/bin/bash
# tests/help_surface.bash - discovers wt's command/subcommand/flag surface from
# source and checks every discovered word's --help page against the page-shape
# contract: a description paragraph, every flag documented with its default,
# every subcommand named, and an Exit codes block. Never a hand-kept list — a
# command, subcommand or flag added to wt.sh/commands/*.sh with no page fails
# `wt_surface_check` by name. It also checks README.md's command tables and
# both shell completion scripts against the same discovery
# (`wt_surface_docs_check`) — a command added to main()'s dispatch with no
# README row fails by name, and so does a command or subcommand, alias
# included, missing from either completion. main()'s own global-flag case
# (`-h|--help|help)`, `-v|--version|version)`) is checked too, as a synthetic
# ROOT unit standing for `wt` itself — a flag or command word it never routes
# through a handler still owes a line on `wt --help`.
#
# Discovery reads `declare -f` output, which bash normalises so every case arm
# header is its own line ("tok1 | tok2)") and every arm ends with a lone ";;"
# line — that shape is what the parser below depends on, not the source text.

# ─── Discovery ──────────────────────────────────────────────────────────────

# Source wt.sh in an isolated subprocess and dump the normalised body of every
# function the discovery rules read: main() plus every cmd_* and every
# underscore-prefixed helper (default-action functions like _pr_open live
# there too). `|| true` after the source is load-bearing: wt.sh's guarded
# `main "$@"` line ends on a false `[[ ... ]]` when sourced (BASH_SOURCE[0]
# names the file, $0 names "bash"), and wt.sh's own `set -e` is inherited by
# the sourcing shell, so an unguarded `source` aborts this script before it
# ever reaches `declare -F`.
# Args: $1 root
# Out: one "###FN### <name>" marker line followed by that function's
#      `declare -f` body, repeated for every discovered function
_wt_surface_dump() {
    local root="$1"
    bash -c "
        source '$root/wt.sh' >/dev/null 2>&1 || true
        for fn in \$(declare -F | awk '{print \$3}' | grep -E '^(main\$|cmd_[a-z_]+\$|_[a-z][a-z_]*\$)'); do
            printf '###FN### %s\n' \"\$fn\"
            declare -f \"\$fn\"
        done
    " 2>/dev/null
}

# Slice one function's normalised body back out of a _wt_surface_dump dump by
# its "###FN### <name>" marker — the bash-3.2-safe stand-in for storing every
# function body in an associative array, which /bin/bash on macOS has none of.
# Args: $1 dump text, $2 function name
# Out: that function's `declare -f` body (empty when the name was not dumped)
_wt_fn_body() {
    local dump="$1" name="$2"
    local marker="###FN### ${name}"
    local in_fn=0 line
    while IFS= read -r line; do
        if [[ "$line" == "###FN### "* ]]; then
            if [[ "$line" == "$marker" ]]; then
                in_fn=1
            else
                [[ $in_fn -eq 1 ]] && return 0
                in_fn=0
            fi
            continue
        fi
        [[ $in_fn -eq 1 ]] && printf '%s\n' "$line"
    done <<< "$dump"
}

# Parse one `declare -f`-normalised function body and emit one discovery line
# per case arm at its top level (sequential case blocks, never nested, are
# what every handler in this repo uses — a nested case would break the
# in_case counter below, but none exists as of this writing):
#   CMD <handler-fn> <token1,token2,...>   — one line for an arm's bare-word
#     tokens (no leading '-', never '*'), only when its body calls a cmd_*
#     function; the first cmd_* token in the body is the handler. An arm may
#     be all words (main()'s second case) or mixed (main()'s own
#     `-h|--help|help)`), and the word half is treated the same either way.
#   FLAG <token> <takes_value:0|1>          — one line per dash token in an
#     arm (all-dash or mixed), dropping -*, --, -h and --help; a body
#     containing "shift 2" marks the flag as taking a value. An arm whose body
#     calls die_unknown_option refuses its flags — a removed flag answered with
#     a hint — so it emits nothing: a refused flag is owed no Options: line.
# An arm carrying a literal '*' token, or a word-only arm whose body never
# calls cmd_*, is silently skipped — it is not part of the discoverable
# surface (e.g. cmd_ports's own `set|clear)` arm just sets a local variable;
# the *real* dispatch is its second, sequential case block).
# Args: $1 function body text (as produced by `declare -f`)
# Out: one discovery line per case arm, as described above
_wt_parse_case_arms() {
    local text="$1"
    local in_case=0
    local collecting=0
    local header=""
    local body=""

    while IFS= read -r raw_line; do
        local line="$raw_line"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" ]] && continue

        if [[ $collecting -eq 0 && "$line" =~ ^case\  ]]; then
            in_case=$((in_case + 1))
            continue
        fi
        if [[ $collecting -eq 0 && "$line" =~ ^esac ]]; then
            [[ $in_case -gt 0 ]] && in_case=$((in_case - 1))
            continue
        fi
        [[ $in_case -eq 0 ]] && continue

        if [[ $collecting -eq 0 ]]; then
            if [[ "$line" =~ ^(.+)\)[[:space:]]*$ ]]; then
                header="${BASH_REMATCH[1]}"
                body=""
                collecting=1
            fi
            continue
        fi

        if [[ "$line" == ";;" ]]; then
            _wt_emit_arm "$header" "$body"
            collecting=0
            header=""
            body=""
            continue
        fi
        body+="$line"$'\n'
    done <<< "$text"
}

# Emit the discovery line(s) for one parsed case arm. Split out of
# _wt_parse_case_arms so the token classification reads as one place.
#
# An arm's tokens split into its dash tokens and its bare words; each half is
# handled independently, so an all-dash arm, an all-word arm and a mixed arm
# (main()'s own `-h|--help|help)`, `-v|--version|version)`) all fall out of
# the same two blocks below. A literal '*' token disqualifies the whole arm
# (returns before either block runs) — that arm is a catch-all, never a
# documented word or flag.
#
# The word half emits "CMD\t<handler-fn>\t<token1,token2,...>" only when the
# body calls a cmd_* function; the first cmd_* token in the body is the
# handler. The dash half emits one "FLAG\t<token>\t<takes_value:0|1>" line per
# kept token (dropping -*, --, -h, --help; "shift 2" in the body marks
# takes_value), plus one "ALIASES\t<tokens comma-joined>" row grouping that
# arm's own kept dash tokens — the per-token FLAG rows lose which short and
# long token share one arm, and wt_short_flag_check needs that grouping to
# find a short letter mapped to two different long flags. A body calling
# die_unknown_option refuses its flags — a removed flag answered with a hint —
# so the dash half emits nothing at all, independently of the word half.
# Every existing FLAG/CMD consumer filters with `grep '^FLAG'` / `grep
# '^CMD'`, so the ALIASES row is invisible to them.
# Args: $1 arm header ("tok1 | tok2"), $2 arm body text
_wt_emit_arm() {
    local header="$1" body="$2"
    local IFS_SAVE="$IFS"
    IFS='|'
    read -ra raw_toks <<< "$header"
    IFS="$IFS_SAVE"

    local -a toks=()
    local t
    for t in "${raw_toks[@]}"; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [[ -n "$t" ]] && toks+=("$t")
    done
    [[ ${#toks[@]} -eq 0 ]] && return

    local -a dash_toks=() word_toks=()
    for t in "${toks[@]}"; do
        [[ "$t" == "*" ]] && return
        if [[ "$t" == -* ]]; then
            dash_toks+=("$t")
        else
            word_toks+=("$t")
        fi
    done

    if [[ ${#word_toks[@]} -gt 0 ]]; then
        local handler
        handler=$(printf '%s\n' "$body" | grep -oE 'cmd_[a-zA-Z_]+' | head -1)
        [[ -n "$handler" ]] && printf 'CMD\t%s\t%s\n' "$handler" "$(IFS=,; echo "${word_toks[*]}")"
    fi

    if [[ ${#dash_toks[@]} -gt 0 ]]; then
        [[ "$body" == *die_unknown_option* ]] && return
        local takes_value=0
        [[ "$body" == *"shift 2"* ]] && takes_value=1
        local -a kept=()
        for t in "${dash_toks[@]}"; do
            case "$t" in
                -*'*') continue ;;
                --) continue ;;
                -h|--help) continue ;;
            esac
            printf 'FLAG\t%s\t%s\n' "$t" "$takes_value"
            kept+=("$t")
        done
        [[ ${#kept[@]} -gt 0 ]] && printf 'ALIASES\t%s\n' "$(IFS=,; echo "${kept[*]}")"
    fi
}

# ─── Surface discovery, driven off main() and each handler in turn ─────────

# Re-emit one function's FLAG and ALIASES arm rows under the words that own them.
# Args: $1 owner words (empty for a top-level flag), $2 _wt_parse_case_arms output
# Out: "FLAG<TAB>owner<TAB>flag<TAB>takes_value" and "ALIASES<TAB>owner<TAB>tokens-csv" rows
_wt_emit_owned_flags() {
    local owner="$1" arms="$2"
    local kind a b
    while IFS=$'\t' read -r kind a b; do
        case "$kind" in
            FLAG) printf 'FLAG\t%s\t%s\t%s\n' "$owner" "$a" "$b" ;;
            ALIASES) printf 'ALIASES\t%s\t%s\n' "$owner" "$a" ;;
        esac
    done <<< "$arms"
}

# Discover the full command/subcommand/flag surface from source.
# Args: $1 root
# Out: tab-separated rows —
#      "COMMAND<TAB>tokens<TAB>handler-fn"
#      "SUBCOMMAND<TAB>parent-tokens<TAB>tokens<TAB>handler-fn"
#      "FLAG<TAB>owner-words<TAB>flag<TAB>takes_value"
#      "ALIASES<TAB>owner-words<TAB>tokens-csv" — one live arm's own short and
#      long tokens together, owner-words empty for a top-level flag; wt's
#      short-flag-collision check reads these, everything else ignores them.
#
# Bash 3.2 (macOS's /bin/bash) has no associative arrays, so a function's body
# is never held in one — _wt_fn_body slices it back out of the flat dump text
# by its "###FN### <name>" marker each time it is needed instead.
_wt_discover_surface() {
    local root="$1"
    local dump
    dump=$(_wt_surface_dump "$root")

    local main_body
    main_body=$(_wt_fn_body "$dump" "main")
    [[ -z "$main_body" ]] && { echo "DISCOVERY-ERROR main() not found after sourcing wt.sh" >&2; return 1; }

    local main_arms
    main_arms=$(_wt_parse_case_arms "$main_body")

    # Top-level commands, from main()'s own dispatch.
    local -a cmd_lines=()
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        cmd_lines+=("$row")
    done < <(printf '%s\n' "$main_arms" | grep '^CMD' || true)

    local row
    for row in "${cmd_lines[@]}"; do
        local handler tokens
        IFS=$'\t' read -r _ handler tokens <<< "$row"
        printf 'COMMAND\t%s\t%s\n' "$tokens" "$handler"

        local handler_body
        handler_body=$(_wt_fn_body "$dump" "$handler")
        [[ -z "$handler_body" ]] && continue

        # Flags directly on the handler's own arg-parsing loop.
        local handler_arms
        handler_arms=$(_wt_parse_case_arms "$handler_body")
        _wt_emit_owned_flags "$tokens" "$handler_arms"

        # Subcommands: a case block inside the handler whose arms call a
        # cmd_* function (e.g. cmd_db's second case, cmd_pr's own case).
        printf '%s\n' "$handler_arms" | grep '^CMD' | while IFS=$'\t' read -r _ sub_handler sub_tokens; do
            # A handler's own case can re-discover itself (e.g. cmd_delete is
            # reached both directly and via rm/prune) — skip a "child" that
            # is the same function as its parent.
            [[ "$sub_handler" == "$handler" ]] && continue
            printf 'SUBCOMMAND\t%s\t%s\t%s\n' "$tokens" "$sub_tokens" "$sub_handler"
            local sub_body
            sub_body=$(_wt_fn_body "$dump" "$sub_handler")
            if [[ -n "$sub_body" ]]; then
                _wt_emit_owned_flags "$tokens $sub_tokens" "$(_wt_parse_case_arms "$sub_body")"
            fi
        done

        # A default-action function (_<canonical>_*) reached from the
        # handler's own "*)" arm — cmd_pr's *) arm calls _pr_open, which
        # carries no flags of its own today, but a future one might.
        local default_fn
        default_fn=$(printf '%s\n' "$handler_body" | grep -oE '_[a-zA-Z_]+_open\b|_[a-zA-Z_]+_default\b' | head -1)
        if [[ -n "$default_fn" ]]; then
            local default_body
            default_body=$(_wt_fn_body "$dump" "$default_fn")
            if [[ -n "$default_body" ]]; then
                _wt_emit_owned_flags "$tokens" "$(_wt_parse_case_arms "$default_body")"
            fi
        fi
    done

    # Top-level flags: dash tokens in main()'s own first (global-flag) case.
    _wt_emit_owned_flags "" "$main_arms"
}

# ─── Help environment ───────────────────────────────────────────────────────

# Build a PATH directory holding symlinks to only what sourcing wt.sh and
# printing a help page need — never yq, tmux, fzf, jq or gh, so a page that
# reaches for any of them fails loudly instead of silently working on a dev
# machine that happens to have them installed.
# Args: $1 shim directory (created if absent)
_wt_build_help_shim() {
    local shim="$1"
    mkdir -p "$shim"
    local u
    for u in bash sh cat dirname readlink basename sed awk grep printf mkdir true; do
        local p
        p=$(command -v "$u" 2>/dev/null) || continue
        ln -sf "$p" "$shim/$u" 2>/dev/null
    done
}

# Run `wt <words...>` under the help shim and an isolated, empty HOME/config
# tree, capturing combined stdout+stderr to a file.
# Args: $1 root, $2 shim dir, $3 isolated home dir, $4 output file, $@ words
# Out: exit status of the wt.sh invocation (via return)
_wt_run_help_probe() {
    local root="$1" shim="$2" home_dir="$3" out_file="$4"
    shift 4
    env -i HOME="$home_dir" PATH="$shim" \
        WT_CONFIG_DIR="$home_dir/config" WT_DATA_DIR="$home_dir/data" \
        bash "$root/wt.sh" "$@" >"$out_file" 2>&1
}

# Run `wt <words...>` under the given PATH and an isolated, empty HOME/config
# tree, capturing stdout and stderr to separate files (never through a pipe —
# `run --separate-stderr` is a bats-core extension and the last pipeline stage
# would swallow wt.sh's own exit status either way).
# Args: $1 root, $2 PATH to run under, $3 isolated home dir, $4 stdout file,
#   $5 stderr file, $@ words
_wt_run_usage_probe() {
    local root="$1" path="$2" home_dir="$3" out_file="$4" err_file="$5"
    shift 5
    env -i HOME="$home_dir" PATH="$path" \
        WT_CONFIG_DIR="$home_dir/config" WT_DATA_DIR="$home_dir/data" \
        bash "$root/wt.sh" "$@" >"$out_file" 2>"$err_file" </dev/null
}

# ─── Page-shape checks ──────────────────────────────────────────────────────

# Fold a continuation line into the entry above it, so an Options or Exit
# codes entry may wrap onto a second physical line without the checker
# reading the wrap as its own entry, or missing the flag/default text that
# spilled onto it. A continuation is a line indented deeper than the entry
# line it follows, beginning with neither a flag token ('-') nor an
# exit-code number — the two entry shapes this section reader ever sees.
# Args: $1 section text (one entry or continuation per line)
# Out: the folded text, one entry per line
_wt_fold_continuations() {
    local text="$1"
    local -a out=()
    local line
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            out+=("$line")
            continue
        fi
        local indent="${line%%[![:space:]]*}"
        local trimmed="${line#"$indent"}"
        local is_continuation=0
        if [[ ${#out[@]} -gt 0 ]]; then
            local prev="${out[${#out[@]}-1]}"
            if [[ -n "$prev" ]]; then
                local prev_indent="${prev%%[![:space:]]*}"
                if [[ ${#indent} -gt ${#prev_indent} && "$trimmed" != -* && ! "$trimmed" =~ ^[0-9] ]]; then
                    is_continuation=1
                fi
            fi
        fi
        if [[ $is_continuation -eq 1 ]]; then
            out[${#out[@]}-1]="${out[${#out[@]}-1]} ${trimmed}"
        else
            out+=("$line")
        fi
    done <<< "$text"
    local o
    for o in "${out[@]}"; do
        printf '%s\n' "$o"
    done
}

# Extract the lines of one labelled section ("Options:", "Exit codes:", ...)
# from a page's text: every line after the "Header:" line, up to the next
# blank line or the next "Header:" line, with a wrapped entry's continuation
# lines folded back onto the entry they belong to (_wt_fold_continuations).
# Args: $1 page text, $2 header (without its trailing colon)
# Out: the section's entries, one per line (empty when the header is absent)
_wt_section_lines() {
    local text="$1" header="$2"
    local in_sec=0 line
    local raw=""
    while IFS= read -r line; do
        if [[ $in_sec -eq 0 && "$line" == "${header}:"* ]]; then
            in_sec=1
            continue
        fi
        if [[ $in_sec -eq 1 ]]; then
            if [[ -z "$line" || "$line" =~ ^[A-Za-z][A-Za-z\ ]*:[[:space:]]*$ ]]; then
                break
            fi
            raw+="$line"$'\n'
        fi
    done <<< "$text"
    [[ -z "$raw" ]] && return 0
    _wt_fold_continuations "$raw"
}

# True when a page's output carries a raw ESC byte (a colour code).
_wt_has_esc_byte() {
    LC_ALL=C grep -q $'\x1b' "$1" 2>/dev/null
}

# True when a page's first non-blank line is prose: not a "Usage:" line, not a
# bare "Header:" line, and its paragraph contains a period. Reads every line of
# the first paragraph (up to the next blank line), not only its first physical
# one — a description sentence rewrapped past 100 columns puts its period on a
# later physical line, and that wrap is still one paragraph, not a new unit.
_wt_first_line_is_prose() {
    local text="$1" line
    local first_seen=0 para=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            [[ $first_seen -eq 1 ]] && break
            continue
        fi
        if [[ $first_seen -eq 0 ]]; then
            [[ "$line" == Usage:* ]] && return 1
            [[ "$line" =~ ^[A-Za-z][A-Za-z\ ]*:[[:space:]]*$ ]] && return 1
            first_seen=1
        fi
        para+="$line "
    done <<< "$text"
    [[ "$para" == *.* ]] && return 0
    return 1
}

# Check one discovered flag against a page's "Options:" section: the flag
# appears as a whole token in some entry's first column (the text before its
# first run of 2+ spaces), a value-taking flag shows a "<placeholder>" on
# that line, and every entry but -h/--help states its default.
# Args: $1 options section text, $2 flag token, $3 takes_value (0|1)
# Out: nothing; return 0 documented correctly, 1 missing entirely,
#      2 missing its <placeholder>, 3 missing "default:"
_wt_check_flag_documented() {
    local options_text="$1" flag="$2" takes_value="$3"
    local line found=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        local first_col="${trimmed%%  *}"
        local tok
        for tok in ${first_col//,/ }; do
            [[ "$tok" != "$flag" ]] && continue
            found=1
            if [[ "$takes_value" -eq 1 && "$line" != *"<"*">"* ]]; then
                return 2
            fi
            if [[ "$flag" != "-h" && "$flag" != "--help" && "$line" != *"default:"* ]]; then
                return 3
            fi
        done
    done <<< "$options_text"
    [[ $found -eq 1 ]] && return 0
    return 1
}

# Check a page's "Exit codes:" block: present, every line "  <n>  <text>",
# and both 0 and 2 are among the listed codes.
# Out: return 0 present and well-formed with 0 and 2, 1 absent,
#      2 malformed line, 3 missing code 0 or 2
_wt_check_exit_codes_block() {
    local text="$1"
    local lines
    lines=$(_wt_section_lines "$text" "Exit codes")
    [[ -z "$lines" ]] && return 1
    local line has0=0 has2=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+.+ ]]; then
            return 2
        fi
        [[ "$line" =~ ^[[:space:]]*0[[:space:]] ]] && has0=1
        [[ "$line" =~ ^[[:space:]]*2[[:space:]] ]] && has2=1
    done <<< "$lines"
    [[ $has0 -eq 1 && $has2 -eq 1 ]] || return 3
    return 0
}

# The standard unknown-option stderr line for one command/subcommand word.
# Args: $1 cmd-words, $2 flag
_wt_standard_usage_line() {
    printf "wt %s: unknown option '%s' \xe2\x80\x94 see 'wt %s --help'\n" "$1" "$2" "$1"
}

# The stderr line main()'s own "*)" arm prints for an unrecognised leading
# word — the shape a ROOT-unit probe hits, since a bad top-level word never
# reaches a command's own die_unknown_option.
# Args: $1 the unrecognised word
_wt_root_unknown_command_line() {
    printf "wt: unknown command '%s' \xe2\x80\x94 see 'wt --help'\n" "$1"
}

# ─── Unit assembly ──────────────────────────────────────────────────────────

# Turn a `_wt_discover_surface` dump into one testable unit per command and
# subcommand, each carrying its own flags, plus one synthetic ROOT unit
# standing for `wt` itself. Both `wt_surface_check` (which probes each unit's
# --help page) and `wt_surface_list` (which only reports what discovery
# found) read from this — the discovery and the aggregation it runs on top of
# are never duplicated between them.
#
# The word a unit is probed with, and the word its standard unknown-option
# line names, is always the FIRST token of a case arm's tokens — "${a%%,*}"
# below, and "${b%%,*}" for a subcommand. Case arms are written
# canonical-first in wt.sh/commands/*.sh (e.g. "create|c)", never
# "c|create)"), so that first token is always the canonical name, and a
# command's own die_usage/die_unknown_option calls must name that same
# canonical word — reordering an arm without updating its die_* calls
# produces a stderr line this check no longer recognises as standard.
#
# The ROOT unit carries an EMPTY invoke — `wt --help`/`wt -h` take no leading
# word — its display word is the literal "wt", its flags are every FLAG row
# with an empty owner (main()'s own global-flag arm), and its subwords are
# every top-level COMMAND's own token csv, so a command word missing from
# `wt --help` fails the same way a subcommand missing from its parent's page
# does.
# Args: $1 root
# Out: one "kind|invoke-words|display-words|flags-csv|subwords-csv" line per unit
_wt_build_units() {
    local root="$1"
    local surface
    surface=$(_wt_discover_surface "$root")
    [[ -z "$surface" ]] && return 1

    # Filtered once per call and read from these two variables from here on —
    # every COMMAND and SUBCOMMAND unit below scans FLAG/SUBCOMMAND rows, and
    # re-running `grep` over the whole surface inside each of those loops was
    # doing that filtering once per unit instead of once per call.
    local flags_only subs_only
    flags_only=$(printf '%s\n' "$surface" | grep '^FLAG' || true)
    subs_only=$(printf '%s\n' "$surface" | grep '^SUBCOMMAND' || true)

    local kind a b c
    local root_subwords_csv=""

    while IFS=$'\t' read -r kind a b; do
        [[ "$kind" != "COMMAND" ]] && continue
        local invoke="${a%%,*}"
        local flags_csv=""
        while IFS=$'\t' read -r _ owner flag tv; do
            [[ "$owner" == "$a" ]] && flags_csv+="${flag}:${tv},"
        done <<< "$flags_only"
        local subwords_csv=""
        while IFS=$'\t' read -r _ parent sub _sh; do
            [[ "$parent" == "$a" ]] && subwords_csv+="${sub};"
        done <<< "$subs_only"
        printf 'COMMAND|%s|%s|%s|%s\n' "$invoke" "$a" "$flags_csv" "$subwords_csv"
        root_subwords_csv+="${a};"
    done < <(printf '%s\n' "$surface" | grep '^COMMAND')

    # awk, not a tab-IFS `read` loop: bash's `read` treats a tab as "IFS
    # whitespace" regardless of what IFS is set to, so it collapses the
    # adjacent tabs an empty-owner row carries ("FLAG\t\t-v\t0") and shifts
    # every field left instead of reading owner as empty — awk's -F'\t'
    # splits on the literal byte and keeps the empty field.
    local root_flags_csv
    root_flags_csv=$(printf '%s\n' "$flags_only" | awk -F'\t' '$2 == "" { printf "%s:%s,", $3, $4 }')
    printf 'ROOT|%s|wt|%s|%s\n' "" "$root_flags_csv" "$root_subwords_csv"

    while IFS=$'\t' read -r kind a b c; do
        [[ "$kind" != "SUBCOMMAND" ]] && continue
        local parent_invoke="${a%%,*}"
        local sub_invoke="${b%%,*}"
        local owner="$a $b"
        local flags_csv=""
        while IFS=$'\t' read -r _ fowner flag tv; do
            [[ "$fowner" == "$owner" ]] && flags_csv+="${flag}:${tv},"
        done <<< "$flags_only"
        printf 'SUBCOMMAND|%s %s|%s %s|%s|\n' "$parent_invoke" "$sub_invoke" "$a" "$b" "$flags_csv"
    done <<< "$subs_only"
}

# List the discovered surface with no --help probing: one "<words> <kind>
# <flags>" line per unit, `<flags>` comma-separated or "-" when the unit
# carries none. For a caller that only needs to assert discovery found a
# given command, subcommand or flag — never a second parser of its own.
# Args: $1 root
# Out: one listing line per discovered unit
wt_surface_list() {
    local root="$1"
    local line
    while IFS='|' read -r u_kind u_invoke u_display u_flags u_subwords; do
        [[ -z "$u_kind" ]] && continue
        local flags_display="${u_flags%,}"
        [[ -z "$flags_display" ]] && flags_display="-"
        printf '%s %s %s\n' "$u_display" "$u_kind" "$flags_display"
    done < <(_wt_build_units "$root")
}

# Check that no short letter (-x) names two different long flags across wt:
# every live arm pairing a short with a long records that pair, and a short
# recorded against more than one distinct long is a violation. A short with no
# long beside it pairs with nothing. awk holds the grouping, since bash 3.2 has
# no associative arrays.
# Args: $1 root
# Out: one "VIOLATION -x names --a (<owner>) and --b (<owner>)" line per
#      colliding short; return 0 clean, 1 when any was printed
wt_short_flag_check() {
    local surface
    surface=$(_wt_discover_surface "$1")
    [[ -z "$surface" ]] && return 1

    local violations
    violations=$(printf '%s\n' "$surface" | awk -F'\t' '
        $1 != "ALIASES" { next }
        {
            owner = ($2 == "") ? "wt" : $2
            n = split($3, toks, ",")
            for (i = 1; i <= n; i++) {
                if (toks[i] !~ /^-[A-Za-z0-9]$/) continue
                for (j = 1; j <= n; j++) {
                    if (toks[j] !~ /^--/ || seen[toks[i], toks[j]]++) continue
                    if (!(toks[i] in names)) order[++count] = toks[i]
                    names[toks[i]] = names[toks[i]] (names[toks[i]] == "" ? "" : " and ") toks[j] " (" owner ")"
                    longs[toks[i]]++
                }
            }
        }
        END {
            for (k = 1; k <= count; k++)
                if (longs[order[k]] > 1) print "VIOLATION " order[k] " names " names[order[k]]
        }')
    [[ -z "$violations" ]] && return 0
    printf '%s\n' "$violations"
    return 1
}

# ─── Orchestrator ───────────────────────────────────────────────────────────

# Check the whole discovered surface against the page-shape and usage-error
# contract. Prints one line per violation, naming the command/subcommand and
# what failed; returns non-zero when any were printed.
# Args: $1 root, $2 optional invoke word — restricts probing to the one unit
#       whose invoke words equal it (a `control:` test checking the
#       shape-checking logic itself against one known unit, cheaper than the
#       whole surface); the real-tree guard test omits it and checks all of them.
#       "wt" selects the synthetic ROOT unit, whose own invoke is empty
#       (`wt --help` takes no leading word), so it cannot be selected by
#       matching invoke words the way every other unit is.
wt_surface_check() {
    local root="$1"
    local only_invoke="${2:-}"
    local violation_count=0
    local shim home_dir no_optional_shim
    shim=$(mktemp -d)
    home_dir=$(mktemp -d)
    _wt_build_help_shim "$shim"
    no_optional_shim=$(mktemp -d)
    build_shim_without "$no_optional_shim" fzf jq gh

    local -a units=()   # "kind|invoke-words|display-words|flags-csv|subwords-csv"
    while IFS= read -r line; do
        units+=("$line")
    done < <(_wt_build_units "$root")

    if [[ ${#units[@]} -eq 0 ]]; then
        echo "VIOLATION discovery produced no commands at all"
        return 1
    fi

    local unit
    for unit in "${units[@]}"; do
        local u_kind u_invoke u_display u_flags u_subwords
        IFS='|' read -r u_kind u_invoke u_display u_flags u_subwords <<< "$unit"

        if [[ -n "$only_invoke" ]]; then
            if [[ "$only_invoke" == "wt" ]]; then
                [[ "$u_kind" != "ROOT" ]] && continue
            else
                [[ "$u_invoke" != "$only_invoke" ]] && continue
            fi
        fi

        local -a probe_words=()
        read -ra probe_words <<< "$u_invoke"

        local out_h out_hh
        out_h=$(mktemp)
        out_hh=$(mktemp)
        _wt_run_help_probe "$root" "$shim" "$home_dir" "$out_h" ${probe_words[@]+"${probe_words[@]}"} -h
        local rc_h=$?
        _wt_run_help_probe "$root" "$shim" "$home_dir" "$out_hh" ${probe_words[@]+"${probe_words[@]}"} --help
        local rc_hh=$?

        if [[ $rc_h -ne 0 ]]; then
            echo "VIOLATION ${u_display}: 'wt ${u_invoke} -h' exited ${rc_h}, want 0"
            violation_count=$((violation_count + 1))
        fi
        if [[ $rc_hh -ne 0 ]]; then
            echo "VIOLATION ${u_display}: 'wt ${u_invoke} --help' exited ${rc_hh}, want 0"
            violation_count=$((violation_count + 1))
        fi

        local page
        page=$(cat "$out_hh" 2>/dev/null)

        if _wt_has_esc_byte "$out_hh"; then
            echo "VIOLATION ${u_display}: help output contains a raw ESC byte (colour code)"
            violation_count=$((violation_count + 1))
        fi

        if ! _wt_first_line_is_prose "$page"; then
            echo "VIOLATION ${u_display}: first non-blank line is not a description ending in '.'"
            violation_count=$((violation_count + 1))
        fi

        local options_text
        options_text=$(_wt_section_lines "$page" "Options")
        local flag_entry
        IFS=',' read -ra flag_entries <<< "$u_flags"
        for flag_entry in "${flag_entries[@]}"; do
            [[ -z "$flag_entry" ]] && continue
            local flag="${flag_entry%%:*}"
            local tv="${flag_entry##*:}"
            _wt_check_flag_documented "$options_text" "$flag" "$tv"
            local frc=$?
            case $frc in
                1) echo "VIOLATION ${u_display}: flag ${flag} is not listed in Options:"
                   violation_count=$((violation_count + 1)) ;;
                2) echo "VIOLATION ${u_display}: flag ${flag} takes a value but shows no <placeholder>"
                   violation_count=$((violation_count + 1)) ;;
                3) echo "VIOLATION ${u_display}: flag ${flag} is missing its default:"
                   violation_count=$((violation_count + 1)) ;;
            esac
        done

        local sub_word_label="subcommand"
        [[ "$u_kind" == "ROOT" ]] && sub_word_label="command"
        local sub_entry
        IFS=';' read -ra sub_entries <<< "$u_subwords"
        for sub_entry in "${sub_entries[@]}"; do
            [[ -z "$sub_entry" ]] && continue
            local sub_alias
            IFS=',' read -ra sub_aliases <<< "$sub_entry"
            for sub_alias in "${sub_aliases[@]}"; do
                [[ -z "$sub_alias" ]] && continue
                if [[ "$page" != *"$sub_alias"* ]]; then
                    echo "VIOLATION ${u_display}: ${sub_word_label} '${sub_alias}' is not named on the page"
                    violation_count=$((violation_count + 1))
                fi
            done
        done

        # ROOT's own invoke is empty, so "wt" itself already names it — the
        # generic own-page check below would either compare against a
        # nonsense empty word or pass on the coincidence that "wt " appears
        # in the Usage: line; skip it outright instead.
        if [[ "$u_kind" != "ROOT" ]] && [[ "$page" != *"wt ${u_display}"* && "$page" != *"wt ${u_invoke}"* ]]; then
            echo "VIOLATION ${u_display}: 'wt ${u_invoke}' does not appear on its own page"
            violation_count=$((violation_count + 1))
        fi

        _wt_check_exit_codes_block "$page"
        local erc=$?
        case $erc in
            1) echo "VIOLATION ${u_display}: no Exit codes: block"
               violation_count=$((violation_count + 1)) ;;
            2) echo "VIOLATION ${u_display}: Exit codes: block has a line not shaped '  <n>  <text>'"
               violation_count=$((violation_count + 1)) ;;
            3) echo "VIOLATION ${u_display}: Exit codes: block does not list both 0 and 2"
               violation_count=$((violation_count + 1)) ;;
        esac

        # Unknown option: real PATH, isolated HOME/WT_* dirs, standard message on stderr.
        local uo_home uo_out uo_err
        uo_home=$(mktemp -d)
        uo_out=$(mktemp)
        uo_err=$(mktemp)
        _wt_run_usage_probe "$root" "$PATH" "$uo_home" "$uo_out" "$uo_err" \
            ${probe_words[@]+"${probe_words[@]}"} --surface-no-such-flag
        local uo_rc=$?
        if [[ $uo_rc -ne 2 ]]; then
            echo "VIOLATION ${u_display}: an unknown option exited ${uo_rc}, want 2"
            violation_count=$((violation_count + 1))
        fi
        local expected_line
        if [[ "$u_kind" == "ROOT" ]]; then
            expected_line=$(_wt_root_unknown_command_line "--surface-no-such-flag")
        else
            expected_line=$(_wt_standard_usage_line "$u_invoke" "--surface-no-such-flag")
        fi
        if ! grep -qF "$expected_line" "$uo_err"; then
            echo "VIOLATION ${u_display}: unknown-option stderr does not equal the standard line"
            violation_count=$((violation_count + 1))
        fi

        # Unknown option, second: the same probe under a PATH holding no fzf, jq or gh
        # (WT_WARN_DEPS left unset), the shape a usage error must keep on a machine
        # missing every optional tool too — exit 2, empty stdout, stderr EXACTLY the
        # standard line (an extra note or warning line fails this, unlike the grep -qF
        # containment check above), and neither WT_CONFIG_DIR nor WT_DATA_DIR created.
        local nf_home nf_out nf_err
        nf_home=$(mktemp -d)
        nf_out=$(mktemp)
        nf_err=$(mktemp)
        _wt_run_usage_probe "$root" "$no_optional_shim" "$nf_home" "$nf_out" "$nf_err" \
            ${probe_words[@]+"${probe_words[@]}"} --surface-no-such-flag
        local nf_rc=$?
        if [[ $nf_rc -ne 2 ]]; then
            echo "VIOLATION ${u_display}: (no fzf/jq/gh) an unknown option exited ${nf_rc}, want 2"
            violation_count=$((violation_count + 1))
        fi
        if [[ -s "$nf_out" ]]; then
            echo "VIOLATION ${u_display}: (no fzf/jq/gh) unknown-option stdout is not empty"
            violation_count=$((violation_count + 1))
        fi
        if [[ "$(cat "$nf_err")" != "$expected_line" ]]; then
            echo "VIOLATION ${u_display}: (no fzf/jq/gh) unknown-option stderr is not exactly the standard line"
            violation_count=$((violation_count + 1))
        fi
        if [[ -d "$nf_home/config" || -d "$nf_home/data" ]]; then
            echo "VIOLATION ${u_display}: (no fzf/jq/gh) unknown option created \$home/config or \$home/data"
            violation_count=$((violation_count + 1))
        fi
        rm -rf "$nf_home"

        rm -f "$out_h" "$out_hh" "$uo_out" "$uo_err" "$nf_out" "$nf_err"
    done

    if [[ $violation_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ─── README and completions checks ─────────────────────────────────────────
#
# README's command tables are checked against top-level commands only — the
# words main()'s own dispatch case routes (_wt_build_units COMMAND rows).
# Both completion scripts are checked against every word main() or a
# command's own internal case routes — COMMAND rows and SUBCOMMAND rows
# alike, aliases included, so `wt pr conflicts`/`wt pr c` and `wt db reset`
# carry the same completion contract as `wt doctor`.

# Extract the markdown under README's "## Commands" heading, up to the next
# "## " heading — the region wt_surface_docs_check's README check reads.
# Args: $1 root
# Out: that region's text (empty when README.md is absent or carries no such heading)
_wt_docs_readme_commands_section() {
    local root="$1"
    [[ -f "$root/README.md" ]] || return 0
    awk '
        /^## Commands/ { insec=1; next }
        insec && /^## / { exit }
        insec { print }
    ' "$root/README.md"
}

# True when a canonical command name has a row in the README commands
# section: some row's text names `` `wt <name>` `` followed by a space, a
# closing backtick, or the end of the text. Matched in-shell, no fork per name.
# Args: $1 commands-section text, $2 canonical name
_wt_docs_readme_has_command() {
    local section="$1" name="$2"
    local re="\`wt ${name}([[:space:]\`]|\$)"
    [[ "$section" =~ $re ]]
}

# Extract the bash completion's flat top-level word list — the value of
# `local commands="..."` in completions/wt.bash.
# Args: $1 root
# Out: the space-separated word list (empty when the file or the line is absent)
_wt_docs_bash_commands() {
    local root="$1"
    [[ -f "$root/completions/wt.bash" ]] || return 0
    sed -n 's/^[[:space:]]*local commands="\(.*\)"$/\1/p' "$root/completions/wt.bash" | head -1
}

# Extract the zsh completion's top-level `commands=( ... )` array entries —
# never `db_subcommands`, which sits in its own array further down.
# Args: $1 root
# Out: one `'<word>:<desc>'` entry per line, as written in the array
_wt_docs_zsh_commands_block() {
    _wt_docs_zsh_named_array_block "$1" commands
}

# True when a word is present as one array entry's own leading token
# ('word:description' or 'word:desc...') in a zsh commands=( ... ) block.
# Matched in-shell against the block with a newline in front, so the first
# entry reads like every other one — no fork per word.
# Args: $1 block text, $2 word
_wt_docs_zsh_block_has_word() {
    local block="$1" word="$2"
    local re=$'\n'"[[:space:]]*'${word}:"
    [[ $'\n'"$block" =~ $re ]]
}

# Drive completions/wt.bash's own dispatcher for one parent command's
# subcommand position and return what it offers, one candidate per line —
# the bash-completion machinery is never simulated by reading the source
# text, since a word sitting in a case pattern (e.g. "conflicts|c)") cannot
# pass this check for one the user is actually offered at the prompt. Run in
# a subshell so the sourced script's functions and COMPREPLY never leak into
# the caller; `cd`'d into a directory with no git repo above it and
# GIT_DIR=/dev/null on top, so a worktree-listing candidate never sneaks a
# real branch name into the reply. Bash 3.2-safe: no associative array
# caches this — the caller computes it once per parent and reuses it across
# that parent's subcommand words.
# Args: $1 root, $2 parent canonical word
# Out: COMPREPLY entries, one per line (empty when the file or arm offers none)
_wt_docs_bash_subwords_for() {
    local root="$1" parent="$2"
    [[ -f "$root/completions/wt.bash" ]] || return 0
    local tmp_cd
    tmp_cd=$(mktemp -d)
    (
        cd "$tmp_cd" || exit 1
        export GIT_DIR=/dev/null
        _init_completion() { return 0; }
        # shellcheck disable=SC1090
        source "$root/completions/wt.bash" >/dev/null 2>&1
        COMP_WORDS=(wt "$parent" "")
        COMP_CWORD=2
        COMP_LINE="wt $parent "
        COMP_POINT=${#COMP_LINE}
        _wt_completions || true
        printf '%s\n' "${COMPREPLY[@]}"
    )
    rm -rf "$tmp_cd"
}

# Extract a named zsh array block ("<name>=( ... )") from wt.zsh — the
# subcommand-listing arrays a command with subcommands declares
# (db_subcommands, pr_subcommands, ports_subcommands, ...), so a word check
# never special-cases which command it belongs to.
# Args: $1 root, $2 array name
# Out: that block's entries text (empty when the file or array is absent)
_wt_docs_zsh_named_array_block() {
    local root="$1" name="$2"
    [[ -f "$root/completions/wt.zsh" ]] || return 0
    awk -v name="$name" '
        $0 ~ "^[[:space:]]*" name "=\\(" { insec=1; next }
        insec && /^[[:space:]]*\)/ { exit }
        insec { print }
    ' "$root/completions/wt.zsh"
}

# Check every command and subcommand discovered from source against
# README's command tables (COMMAND rows only) and both completion scripts
# (COMMAND and SUBCOMMAND rows alike, aliases included). Prints one line per
# violation, returns non-zero when any were printed.
# Args: $1 root
# Out: nothing but VIOLATION lines; return 0 clean, 1 any violation printed
wt_surface_docs_check() {
    local root="$1"
    local violation_count=0

    local -a units=()
    while IFS= read -r line; do
        units+=("$line")
    done < <(_wt_build_units "$root")

    if [[ ${#units[@]} -eq 0 ]]; then
        echo "VIOLATION discovery produced no commands at all"
        return 1
    fi

    local readme_section bash_commands zsh_block
    readme_section=$(_wt_docs_readme_commands_section "$root")
    bash_commands=$(_wt_docs_bash_commands "$root")
    zsh_block=$(_wt_docs_zsh_commands_block "$root")

    # What each completion offers at one parent's subcommand position —
    # wt.bash's COMPREPLY (newline-framed for an in-shell membership test)
    # and wt.zsh's <parent>_subcommands block. Driving wt.bash costs a
    # subshell and a source, so both are read once per parent: discovery
    # emits a parent's SUBCOMMAND rows consecutively.
    local sub_parent="" bash_subwords="" zsh_sub_block=""

    local unit
    for unit in "${units[@]}"; do
        local u_kind u_invoke u_display u_flags u_subwords
        IFS='|' read -r u_kind u_invoke u_display u_flags u_subwords <<< "$unit"

        # The synthetic ROOT unit stands for `wt` itself, never a documented
        # command or subcommand — README's tables and both completions are
        # checked against COMMAND/SUBCOMMAND rows only, so ROOT is skipped
        # rather than reported as missing from either.
        [[ "$u_kind" == "ROOT" ]] && continue

        if [[ "$u_kind" == "COMMAND" ]]; then
            local -a all_words=()
            IFS=',' read -ra all_words <<< "$u_display"
            local canonical="${all_words[0]}"

            if ! _wt_docs_readme_has_command "$readme_section" "$canonical"; then
                echo "VIOLATION ${canonical}: not in README.md's command tables"
                violation_count=$((violation_count + 1))
            fi

            local word
            for word in "${all_words[@]}"; do
                if [[ " $bash_commands " != *" $word "* ]]; then
                    echo "VIOLATION ${word}: not offered by completions/wt.bash"
                    violation_count=$((violation_count + 1))
                fi
                if ! _wt_docs_zsh_block_has_word "$zsh_block" "$word"; then
                    echo "VIOLATION ${word}: not offered by completions/wt.zsh"
                    violation_count=$((violation_count + 1))
                fi
            done
            continue
        fi

        if [[ "$u_kind" == "SUBCOMMAND" ]]; then
            # The parent field carries the parent's own aliases ("pr" today,
            # "x,y" for an aliased parent); completion is keyed on its
            # canonical word, and so is the zsh array's name.
            local parent_tokens="${u_display%% *}"
            local parent_word="${parent_tokens%%,*}"
            local sub_words_csv="${u_display#* }"
            local -a sub_words=()
            IFS=',' read -ra sub_words <<< "$sub_words_csv"

            if [[ "$parent_word" != "$sub_parent" ]]; then
                bash_subwords=$'\n'"$(_wt_docs_bash_subwords_for "$root" "$parent_word")"$'\n'
                zsh_sub_block=$(_wt_docs_zsh_named_array_block "$root" "${parent_word//-/_}_subcommands")
                sub_parent="$parent_word"
            fi

            local sub_word
            for sub_word in "${sub_words[@]}"; do
                if [[ "$bash_subwords" != *$'\n'"$sub_word"$'\n'* ]]; then
                    echo "VIOLATION ${parent_word} ${sub_word}: not offered by completions/wt.bash"
                    violation_count=$((violation_count + 1))
                fi
                if ! _wt_docs_zsh_block_has_word "$zsh_sub_block" "$sub_word"; then
                    echo "VIOLATION ${parent_word} ${sub_word}: not offered by completions/wt.zsh"
                    violation_count=$((violation_count + 1))
                fi
            done
        fi
    done

    if [[ $violation_count -gt 0 ]]; then
        return 1
    fi
    return 0
}
