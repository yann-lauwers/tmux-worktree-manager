#!/bin/bash
# lib/utils.sh - Logging, colors, and common utilities

# The raw escape codes behind every color variable. wt_color_init assigns
# these (or '') to the stdout names below and to their E_-prefixed stderr
# twins, decided independently per stream — never referenced directly outside
# this block.
_WT_ESC_RED='\033[0;31m'
_WT_ESC_GREEN='\033[0;32m'
_WT_ESC_YELLOW='\033[0;33m'
_WT_ESC_BLUE='\033[0;34m'
_WT_ESC_MAGENTA='\033[0;35m'
_WT_ESC_CYAN='\033[0;36m'
_WT_ESC_BOLD='\033[1m'
_WT_ESC_DIM='\033[2m'
_WT_ESC_NC='\033[0m' # No Color

# OSC 8 hyperlink open/close, as real ESC bytes (not \033 text) — consumed
# through %s to build a link_start/link_end pair, unlike the %b-driven colors
# above.
_WT_OSC8_OPEN=$'\e]8;;'
_WT_OSC8_ST=$'\e\\'

# Decide whether one stream gets colour. WT_COLOR=always wins outright —
# including over a piped stream. Failing that, a non-empty NO_COLOR (an empty
# NO_COLOR= counts as unset, per no-color.org) turns colour off regardless of
# the terminal. Failing that, the stream's own tty test decides. Pure: reads
# only WT_COLOR/NO_COLOR, so the same decision is reproducible from a test
# with no real terminal in play. Answers by exit status, so the caller forks
# no subshell to read it.
# Args: $1 is_tty (1 when that stream is a terminal, 0 otherwise)
# Out: exit 0 (colour on) or 1 (colour off)
_wt_color_decide() {
    if [[ "${WT_COLOR:-}" == "always" ]]; then
        return 0
    elif [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi
    [[ "$1" == "1" ]]
}

# Decide colour for stdout and stderr independently — a piped stdout with a
# terminal stderr (or the reverse) gets colour on one stream only — then
# assign every color variable this file exports: the plain names
# (RED/GREEN/.../NC) for stdout call sites, the E_-prefixed twins
# (E_RED/E_GREEN/.../E_NC) for stderr call sites, log_* included. Called once
# at the bottom of this block so every sourcer (wt.sh, and a bats load_lib
# "utils") gets it; safe to call again — tests re-call it after exporting
# WT_COLOR/NO_COLOR to redecide.
# Side: sets _WT_COLOR_OUT, _WT_COLOR_ERR, and every color variable above
wt_color_init() {
    local out_tty=0 err_tty=0 name esc
    [[ -t 1 ]] && out_tty=1
    [[ -t 2 ]] && err_tty=1

    _WT_COLOR_OUT=0; _wt_color_decide "$out_tty" && _WT_COLOR_OUT=1
    _WT_COLOR_ERR=0; _wt_color_decide "$err_tty" && _WT_COLOR_ERR=1

    for name in RED GREEN YELLOW BLUE MAGENTA CYAN BOLD DIM NC; do
        esc="_WT_ESC_$name"
        if [[ "$_WT_COLOR_OUT" == "1" ]]; then printf -v "$name" '%s' "${!esc}"; else printf -v "$name" '%s' ''; fi
        if [[ "$_WT_COLOR_ERR" == "1" ]]; then printf -v "E_$name" '%s' "${!esc}"; else printf -v "E_$name" '%s' ''; fi
    done
}

wt_color_init

# Logging functions - all output to stderr to not interfere with function return values
log_info() {
    echo -e "${E_BLUE}[INFO]${E_NC} $*" >&2
}

log_success() {
    echo -e "${E_GREEN}[SUCCESS]${E_NC} $*" >&2
}

log_warn() {
    echo -e "${E_YELLOW}[WARN]${E_NC} $*" >&2
}

log_error() {
    echo -e "${E_RED}[ERROR]${E_NC} $*" >&2
}

log_debug() {
    if [[ "${WT_DEBUG:-}" == "1" ]]; then
        echo -e "${E_DIM}[DEBUG]${E_NC} $*" >&2
    fi
}

log_step() {
    local current="$1"
    local total="$2"
    local message="$3"
    echo -e "${E_CYAN}[$current/$total]${E_NC} $message" >&2
}

# Spinner for long-running operations
spinner() {
    local pid=$1
    local message="${2:-Working...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#spin} ))
        printf "\r${CYAN}%s${NC} %s" "${spin:$i:1}" "$message"
        sleep 0.1
    done
    printf "\r"
}

# Die with error message
die() {
    log_error "$@"
    exit 1
}

# Die with the standard usage-error line for a command or subcommand, on stderr,
# plain (no color, unlike log_error — a usage error is parsed by scripts and by
# the surface test, so its wording is exact and never routed through the color codes).
# Args: $1 cmd-words (e.g. "attach", "db reset"), $2 detail, $3 accepted form (optional)
# Side: writes to stderr, exits 2
die_usage() {
    local cmd_words="$1"
    local detail="$2"
    local form="${3:-}"

    printf "wt %s: %s \xe2\x80\x94 see 'wt %s --help'\n" "$cmd_words" "$detail" "$cmd_words" >&2
    if [[ -n "$form" ]]; then
        printf 'usage: %s\n' "$form" >&2
    fi
    exit 2
}

# Die with the standard unknown-option line for a command or subcommand.
# Args: $1 cmd-words, $2 the rejected flag
# Side: writes to stderr, exits 2 (via die_usage)
die_unknown_option() {
    die_usage "$1" "unknown option '$2'"
}

# The listing command every not-found message below points a reader at.
WT_LISTING_CMD="wt ls"

# Die with the standard unknown-branch line for a command whose target branch
# has no worktree in the given project — one wording shared by every command
# that resolves a branch, so a caller (human or script) matches one string.
# Args: $1 cmd-words (e.g. "status", "ports set", "db use-remote"), $2 branch, $3 project
# Side: writes to stderr, plain (no colour), exits 1
die_no_worktree() {
    local cmd_words="$1"
    local branch="$2"
    local project="$3"

    printf "wt %s: no worktree for branch '%s' in project %s \xe2\x80\x94 branch names are matched in full; '%s' shows them\n" \
        "$cmd_words" "$branch" "$project" "$WT_LISTING_CMD" >&2
    exit 1
}

# Die with the standard missing-argument line when a flag's value is empty —
# a no-op when the value is non-empty, so a caller runs it unconditionally
# instead of guarding it behind its own `[[ -z ]]` check.
# Args: $1 cmd-words, $2 the flag, $3 the value as read (may be empty/unset), $4 accepted form (optional)
# Side: writes to stderr, exits 2 (via die_usage) when $3 is empty
require_optarg() {
    local cmd_words="$1"
    local flag="$2"
    local value="$3"
    local form="${4:-}"

    [[ -z "$value" ]] && die_usage "$cmd_words" "option $flag requires an argument" "$form"
    return 0
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Require a command or die
require_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command_exists "$cmd"; then
        if [[ -n "$install_hint" ]]; then
            die "'$cmd' is required but not installed. $install_hint"
        else
            die "'$cmd' is required but not installed."
        fi
    fi
}

# Sanitize branch name for filesystem/tmux use
sanitize_branch_name() {
    local branch="$1"
    # Replace / with - and remove other problematic chars (single sed call)
    echo "$branch" | sed 's|/|-|g; s|[^a-zA-Z0-9_-]||g'
}

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null
}

# Get the root of the git repository
git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get the current branch name of a repository.
# Defaults to the working directory when no repo is named, which is what `wt start` and
# `wt stop` want — they ask "which branch am I standing in". A caller holding a specific
# repo passes it: reading cwd instead answers about the wrong repository, and returns
# "HEAD" whenever cwd happens to be detached.
# Args: $1 repo root (optional; defaults to cwd)
# Out: branch name, or "HEAD" when that repo is in detached HEAD state
current_branch() {
    local repo_root="${1:-}"

    if [[ -n "$repo_root" ]]; then
        git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null
    else
        git rev-parse --abbrev-ref HEAD 2>/dev/null
    fi
}

# Check if a branch exists locally
# Args: $1 branch, $2 repo root (optional; defaults to the caller's cwd, which is wrong
#       whenever the caller stands outside the repo or inside a worktree being removed)
branch_exists() {
    local branch="$1"
    local repo_root="${2:-.}"
    git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"
}

# Check if a branch exists on remote
# Args: $1 branch, $2 remote (default origin), $3 repo root (optional; defaults to cwd)
remote_branch_exists() {
    local branch="$1"
    local remote="${2:-origin}"
    local repo_root="${3:-.}"
    git -C "$repo_root" ls-remote --exit-code --heads "$remote" "$branch" &>/dev/null
}

# Confirm action with user
confirm() {
    local message="${1:-Are you sure?}"
    local default="${2:-n}"

    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    read -r -p "$message $prompt " response
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

# Create directory if it doesn't exist
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Get project name from repo path
get_project_name() {
    local repo_path="${1:-$(git_root)}"
    basename "$repo_path"
}

# Expand ~ in paths
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Execute a command while holding an exclusive file lock
# Uses mkdir for portable atomic locking (works on macOS and Linux)
# Usage: with_file_lock "/path/to/file" command args...
with_file_lock() {
    local lock_dir="$1.lockdir"
    shift

    local max_wait=10
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if (( waited >= max_wait )); then
            # Stale lock — force remove and retry
            rm -rf "$lock_dir"
            mkdir "$lock_dir" 2>/dev/null || true
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Run the command, capture exit code, then release lock
    local rc=0
    "$@" || rc=$?
    rm -rf "$lock_dir"
    return $rc
}

# Export VARNAME to a command's stdout, or to whatever a failed substitution captured with
# its exit status forced to 0 — matching `export VAR="$(cmd)"`, whose own status is the
# assignment's, so a failing cmd was already masked before this helper existed.
# Args: $1 VARNAME, $2.. cmd and its args
# Side: exports $1 in the caller's shell
export_or_empty() {
    local __eoe_varname="$1"
    shift
    local __eoe_value
    __eoe_value="$("$@")" || true
    export "${__eoe_varname}=${__eoe_value}"
}

# Check if port is in use
port_in_use() {
    local port="$1"
    lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null
}

# Pretty print a key-value pair
print_kv() {
    local key="$1"
    local value="$2"
    local width="${3:-20}"
    printf "${BOLD}%-${width}s${NC} %s\n" "$key:" "$value"
}

# Print a table header
print_header() {
    echo -e "${BOLD}$*${NC}"
    echo "$(echo "$*" | sed 's/./-/g')"
}

# Truncate string to max length
truncate() {
    local str="$1"
    local max="${2:-30}"

    if (( ${#str} > max )); then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}

# Get timestamp
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}


# Planted for validating #18 (C13): an unquoted expansion the CI shellcheck job must refuse. Never merged.
planted_sc2086_probe() { rm $1; }
