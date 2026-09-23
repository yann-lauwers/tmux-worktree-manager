#!/bin/bash
# wt - Git Worktree Manager
# A CLI tool for managing git worktrees with tmux integration

set -euo pipefail

# What `wt --version` reports where the install is not a git checkout; a checkout
# reports its release tag instead (lib/version.sh). The release step,
# scripts/check-release.sh, keeps this equal to the latest v* tag. Keep the
# VERSION="x.y.z" form: that script parses this line.
VERSION="2.1.0"

# Determine script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If $SOURCE is relative, resolve it relative to the symlink's directory
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
WT_SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
export WT_SCRIPT_DIR

# Source library modules
source "${WT_SCRIPT_DIR}/lib/utils.sh"
source "${WT_SCRIPT_DIR}/lib/json.sh"
source "${WT_SCRIPT_DIR}/lib/version.sh"
source "${WT_SCRIPT_DIR}/lib/config.sh"
source "${WT_SCRIPT_DIR}/lib/port.sh"
source "${WT_SCRIPT_DIR}/lib/state.sh"
source "${WT_SCRIPT_DIR}/lib/worktree.sh"
source "${WT_SCRIPT_DIR}/lib/setup.sh"
source "${WT_SCRIPT_DIR}/lib/tmux.sh"
source "${WT_SCRIPT_DIR}/lib/service.sh"
source "${WT_SCRIPT_DIR}/lib/smart.sh"
source "${WT_SCRIPT_DIR}/lib/worktree-list.sh"

# Source command modules
source "${WT_SCRIPT_DIR}/commands/create.sh"
source "${WT_SCRIPT_DIR}/commands/delete.sh"
source "${WT_SCRIPT_DIR}/commands/list.sh"
source "${WT_SCRIPT_DIR}/commands/start.sh"
source "${WT_SCRIPT_DIR}/commands/stop.sh"
source "${WT_SCRIPT_DIR}/commands/status.sh"
source "${WT_SCRIPT_DIR}/commands/health.sh"
source "${WT_SCRIPT_DIR}/commands/attach.sh"
source "${WT_SCRIPT_DIR}/commands/run.sh"
source "${WT_SCRIPT_DIR}/commands/exec.sh"
source "${WT_SCRIPT_DIR}/commands/init.sh"
source "${WT_SCRIPT_DIR}/commands/config.sh"
source "${WT_SCRIPT_DIR}/commands/ports.sh"
source "${WT_SCRIPT_DIR}/commands/send.sh"
source "${WT_SCRIPT_DIR}/commands/logs.sh"
source "${WT_SCRIPT_DIR}/commands/panes.sh"
source "${WT_SCRIPT_DIR}/commands/doctor.sh"
source "${WT_SCRIPT_DIR}/commands/open.sh"
source "${WT_SCRIPT_DIR}/commands/smartlist.sh"
source "${WT_SCRIPT_DIR}/commands/db.sh"
# smartdelete.sh + prune.sh merged into delete.sh — `wt rm` is the single delete surface
source "${WT_SCRIPT_DIR}/commands/code.sh"
source "${WT_SCRIPT_DIR}/commands/pr.sh"

# Show quick usage (wt with no args) — a short pointer to the full page, not a
# restatement of it, so the two never drift apart.
# Side: writes to stdout
show_usage() {
    cat <<EOF
wt manages git worktrees across projects — creating and deleting them with tmux
windows, port slots, an optional ephemeral Postgres, and Cloudflare tunnels.

Usage: wt <command> [arguments] [options]

Common commands: create, open, ls, rm, start, stop, status, attach, db

Run 'wt --help' for the full command list, or 'wt help <command>' (same as
'wt <command> --help') for one command's own page.
EOF
}

# Show the top-level help page (wt --help / wt -h).
# Side: writes to stdout
show_help() {
    cat <<EOF
wt manages git worktrees across projects: it creates and deletes them with tmux
windows, port slots, an optional ephemeral Postgres, and Cloudflare tunnels wired
through per-project hooks. It never removes a worktree without confirming first,
except under -f/--force on a direct delete, or the bulk 'wt rm' and 'wt prune'
pickers, which force-remove a matching worktree by default.

Usage: wt <command> [arguments] [options]

Commands:
  help <command>   Show one command's page (same as wt <command> --help)
  create, c        Create a worktree (Linear-aware, scratch, or a plain branch)
  open, o          Open a worktree in cmux/tmux (fzf picker)
  ls               List worktrees across all projects, with PR status
  rm               Delete worktrees (fzf multi-select; --merged for merged/closed only)
  prune            Delete merged/closed-PR worktrees (alias for rm --merged)
  code, cursor     Open a worktree in the configured editor
  pr               PR management (open in browser, list conflicts, resolve one)
  start, up        Start services in a worktree
  stop, down       Stop services in a worktree
  status, st       Show worktree status (recorded state)
  health, hc       Live-probe services and exit 0/1 (actual state)
  attach, a        Attach to the worktree's tmux session
  db               Manage a worktree's ephemeral Postgres
  delete           Delete a single worktree (no picker)
  list             List worktrees for one project
  send, s          Send a command to a tmux pane
  logs, log        Capture pane output
  panes            List tmux panes for a worktree
  run              Run one setup step again
  exec             Execute a command inside a worktree
  ports            Show or override port assignments
  doctor, doc      Run diagnostic checks
  init             Initialize a project's configuration
  config           View or edit configuration

Examples:
  wt create NEX-1500                   # create from a Linear task
  wt open                              # fzf picker over every worktree
  wt start                             # start services (run inside a worktree)
  wt rm                                # fzf multi-select delete

Options:
  -h, --help       Show this page
  -v, --version    Show the wt version

Environment:
  WT_CONFIG_DIR      Config directory (default: ~/.config/wt)
  WT_DATA_DIR        State, logs and generated data (default: ~/.local/share/wt)
  WT_DEBUG           Set to 1 to print [DEBUG] lines (default: unset)
  WT_WARN_DEPS       Set to false to silence optional-dependency warnings (default: true)
  WT_COLOR           Set to 'always' to force colour and hyperlinks even when piped, overriding
                    NO_COLOR (default: unset)
  NO_COLOR           Set (non-empty) to disable colour and hyperlinks even on a terminal (default: unset)
  WT_TMUX_SESSION    tmux session name (default: the current tmux session, else "wt")
  WT_LINEAR_API_KEY  Linear API token for 'wt create <TICKET-ID>' (default: read from pass)

Issues: https://github.com/yann-lauwers/tmux-worktree-manager/issues

Exit codes:
  0  success
  1  operational failure
  2  usage error: unknown command, unknown option, or a missing required argument
EOF
}

# Print the version of the install checkout wt runs from
# Out: wt <version>
show_version() {
    echo "wt $(resolve_version "$WT_SCRIPT_DIR")"
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command_exists git; then
        missing+=("git")
    fi

    if ! command_exists yq; then
        missing+=("yq (install: brew install yq)")
    fi

    if ! command_exists tmux; then
        missing+=("tmux (install: brew install tmux)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep" >&2
        done
        exit 1
    fi

    # Optional dependencies (for smart commands)
    local optional_missing=()
    if ! command_exists fzf; then
        optional_missing+=("fzf (for interactive pickers: brew install fzf)")
    fi
    if ! command_exists jq; then
        optional_missing+=("jq (for JSON parsing: brew install jq)")
    fi
    if ! command_exists gh; then
        optional_missing+=("gh (for PR status: brew install gh)")
    fi

    if [[ ${#optional_missing[@]} -gt 0 && "${WT_WARN_DEPS:-true}" != "false" ]]; then
        log_warn "Optional dependencies missing (some smart commands may not work):"
        for dep in "${optional_missing[@]}"; do
            echo "  - $dep" >&2
        done
        echo "" >&2
    fi
}

# True when the arguments name a request for a command's or a subcommand's own
# help page:
#   "-h"/"--help" as the command itself (the top-level page);
#   "<command> -h|--help" for any command word, with no lookup — the
#     handler's own -h|--help arm, or main()'s unknown-command arm, answers
#     with no dependency on check_dependencies/init_config_dirs having run;
#   "<command> <word> -h|--help" where <word> does not start with "-" and a
#     cmd_<command>_* function exists, discovered via declare -F rather than
#     a hand-kept list — covers wt db reset --help, wt pr conflicts --help,
#     wt ports set --help, and (by the same rule, harmlessly) wt pr <branch>
#     --help and wt ports <branch> --help, which reach a parser that prints
#     help either way. This rule keys on the command word as typed, so an
#     alias of a subcommand-bearing command (none exists today) would answer
#     subcommand help only after the dependency check — the surface test's
#     no-yq/no-tmux probe would report it.
# When true, main() skips check_dependencies and init_config_dirs and
# dispatches as normal — the handler's own -h|--help arm is what actually
# prints the page. exec and send carry no cmd_exec_*/cmd_send_* functions, so
# the third rule never fires for them: `wt exec <branch> <cmd> -h` reaches the
# wrapped command's own "-h" rather than being swallowed here.
# Args: $1 command word, $@ (from $2) the remaining arguments
# Out: none (boolean via exit status)
_wt_help_requested() {
    local command="$1"
    shift || true
    local first="${1:-}"
    local second="${2:-}"

    if [[ "$command" == "-h" || "$command" == "--help" ]]; then
        return 0
    fi
    [[ "$command" == -* ]] && return 1

    if [[ "$first" == "-h" || "$first" == "--help" ]]; then
        return 0
    fi

    if [[ -n "$first" && "$first" != -* && ( "$second" == "-h" || "$second" == "--help" ) ]]; then
        declare -F | awk '{print $3}' | grep -qE "^cmd_${command}_" && return 0
    fi

    return 1
}

# Resolves the command word to its handler function before check_dependencies
# and init_config_dirs run, so an unknown command refuses with nothing but
# its usage line and touches no dependency check or disk write; the resolved
# handler then runs after those two, unless the word is a help request.
# Args: $@ wt's own argv
# Side: check_dependencies, init_config_dirs (unless help was requested);
#   die_usage / exit 2 on a bad command or bad 'help' invocation; runs the
#   resolved handler
main() {
    # Handle no arguments
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi

    local command="$1"
    shift

    # 'wt help <command>' becomes '<command> --help', so it takes the exact path
    # a direct --help does: no dependency check, alias dispatch, the handler's
    # own page, and the unknown-command arm for a word that is no command.
    if [[ "$command" == "help" ]]; then
        if [[ $# -eq 1 ]]; then
            command="$1"
            set -- --help
        elif [[ $# -gt 1 ]]; then
            die_usage "help" "takes one command name — for a subcommand's page run 'wt <command> <subcommand> --help'" "wt help <command>"
        fi
    fi

    # Handle global flags
    case "$command" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -v|--version|version)
            show_version
            exit 0
            ;;
    esac

    # Resolve the command word to its handler — nothing here checks a
    # dependency or writes to disk, so a word that matches no arm below
    # exits with its usage line alone. `prune`'s extra `--merged` is held in
    # prefix_args rather than folded into "$@" here, so it does not reach
    # _wt_help_requested below and change whether a help request is detected
    # — the same separation `WT_CMD_NAME="rm" cmd_delete "$@"` gave rm.
    local handler=""
    local -a prefix_args=()
    case "$command" in
        create|c)
            handler=cmd_create
            ;;
        open|o)
            handler=cmd_open
            ;;
        ls)
            handler=cmd_smartlist
            ;;
        rm)
            WT_CMD_NAME="rm"
            handler=cmd_delete
            ;;
        prune)
            # Thin alias: the merged/closed-only door into the unified `wt rm` picker.
            WT_CMD_NAME="prune"
            prefix_args=(--merged)
            handler=cmd_delete
            ;;
        code|cursor)
            handler=cmd_code
            ;;
        pr)
            handler=cmd_pr
            ;;
        # Core commands
        delete)
            handler=cmd_delete
            ;;
        list)
            handler=cmd_list
            ;;
        start|up)
            handler=cmd_start
            ;;
        stop|down)
            handler=cmd_stop
            ;;
        status|st)
            handler=cmd_status
            ;;
        health|hc)
            handler=cmd_health
            ;;
        attach|a)
            handler=cmd_attach
            ;;
        run)
            handler=cmd_run
            ;;
        exec)
            handler=cmd_exec
            ;;
        init)
            handler=cmd_init
            ;;
        config)
            handler=cmd_config
            ;;
        ports)
            handler=cmd_ports
            ;;
        send|s)
            handler=cmd_send
            ;;
        logs|log)
            handler=cmd_logs
            ;;
        panes)
            handler=cmd_panes
            ;;
        doctor|doc)
            handler=cmd_doctor
            ;;
        db)
            handler=cmd_db
            ;;
        *)
            printf "wt: unknown command '%s' \xe2\x80\x94 see 'wt --help'\n" "$command" >&2
            exit 2
            ;;
    esac

    # A command or subcommand's own --help/-h skips dependency checks and
    # directory creation — reading help must never require yq or tmux to be
    # installed, or write anything to disk.
    if ! _wt_help_requested "$command" "$@"; then
        check_dependencies
        init_config_dirs
    fi

    if [[ ${#prefix_args[@]} -gt 0 ]]; then
        "$handler" "${prefix_args[@]}" "$@"
    else
        "$handler" "$@"
    fi
}

# Run main only when this file is executed, not when it is sourced — the
# surface test sources it to discover the command surface from `declare -f`,
# and a run of main() on that source is not something it asks for.
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
