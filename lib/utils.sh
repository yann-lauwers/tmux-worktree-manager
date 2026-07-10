#!/bin/bash
# lib/utils.sh - Logging, colors, and common utilities

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Logging functions - all output to stderr to not interfere with function return values
# Print an informational message.
# Args: $* message
# Side: writes to stderr
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

# Print a success message.
# Args: $* message
# Side: writes to stderr
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

# Print a warning message.
# Args: $* message
# Side: writes to stderr
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Print an error message.
# Args: $* message
# Side: writes to stderr
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Print a debug message when WT_DEBUG=1.
# Args: $* message
# Side: writes to stderr
log_debug() {
    if [[ "${WT_DEBUG:-}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} $*" >&2
    fi
}

# Print a numbered progress step.
# Args: $1 current, $2 total, $3 message
# Side: writes to stderr
log_step() {
    local current="$1"
    local total="$2"
    local message="$3"
    echo -e "${CYAN}[$current/$total]${NC} $message" >&2
}

# Animate a spinner in the terminal until a background PID exits.
# Args: $1 pid, $2 message (opt)
# Side: writes an animated line to the terminal
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

# Log an error message and exit the process.
# Args: $* message
# Side: writes to stderr, exits 1
die() {
    log_error "$@"
    exit 1
}

# Report whether a command is available (predicate).
# Args: $1 command name
command_exists() {
    command -v "$1" &>/dev/null
}

# Die unless a command is installed.
# Args: $1 command name, $2 install hint (opt)
# Side: die (exit 1) when the command is missing
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

# Sanitize a branch name for filesystem/tmux use.
# Args: $1 branch
# Out:  sanitized name
sanitize_branch_name() {
    local branch="$1"
    # Replace / with - and remove other problematic chars (single sed call)
    echo "$branch" | sed 's|/|-|g; s|[^a-zA-Z0-9_-]||g'
}

# Report whether the cwd is inside a git work tree (predicate).
is_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null
}

# Print the git repository root path.
# Out:  repo root path
git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Print the current branch name.
# Out:  branch name
current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Report whether a branch exists locally (predicate).
# Args: $1 branch
branch_exists() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/$branch"
}

# Report whether a branch exists on a remote (predicate).
# Args: $1 branch, $2 remote (opt, default origin)
remote_branch_exists() {
    local branch="$1"
    local remote="${2:-origin}"
    git ls-remote --exit-code --heads "$remote" "$branch" &>/dev/null
}

# Prompt the user to confirm an action (predicate: yes → success).
# Args: $1 message (opt), $2 default y|n (opt, default n)
# Side: reads stdin, writes the prompt to the terminal
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

# Create a directory (and parents) if it does not exist.
# Args: $1 dir
# Side: mkdir -p
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Derive the project name from a repo path.
# Args: $1 repo path (opt, defaults to git root)
# Out:  basename of the path
get_project_name() {
    local repo_path="${1:-$(git_root)}"
    basename "$repo_path"
}

# Expand a leading ~ to $HOME in a path.
# Args: $1 path
# Out:  expanded path
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Run a command while holding an exclusive file lock.
# Uses mkdir for portable atomic locking (works on macOS and Linux).
# Args: $1 lock target path, $2.. command + args
# Side: creates then removes "<target>.lockdir"; force-clears a stale lock
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

# Report whether a TCP port has a listener (predicate).
# Args: $1 port
port_in_use() {
    local port="$1"
    lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null
}

# Print an aligned bold key-value pair.
# Args: $1 key, $2 value, $3 width (opt, default 20)
# Out:  formatted line
print_kv() {
    local key="$1"
    local value="$2"
    local width="${3:-20}"
    printf "${BOLD}%-${width}s${NC} %s\n" "$key:" "$value"
}

# Print a bold header underlined with dashes.
# Args: $* header text
# Out:  formatted header (two lines)
print_header() {
    echo -e "${BOLD}$*${NC}"
    echo "$(echo "$*" | sed 's/./-/g')"
}

# Truncate a string to a max length, appending "..." when clipped.
# Args: $1 string, $2 max (opt, default 30)
# Out:  truncated string
truncate() {
    local str="$1"
    local max="${2:-30}"

    if (( ${#str} > max )); then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}

# Print the current UTC timestamp (ISO 8601).
# Out:  timestamp string
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

