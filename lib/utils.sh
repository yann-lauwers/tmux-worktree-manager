#!/bin/bash
# lib/utils.sh - Logging, colors, and common utilities

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
# shellcheck disable=SC2034 # read by lib/smart.sh, part of this file's exported color palette
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Logging functions - all output to stderr to not interfere with function return values
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${WT_DEBUG:-}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} $*" >&2
    fi
}

log_step() {
    local current="$1"
    local total="$2"
    local message="$3"
    echo -e "${CYAN}[$current/$total]${NC} $message" >&2
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

