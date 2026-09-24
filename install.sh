#!/bin/bash
# install.sh - Install wt (Git Worktree Manager)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v git &>/dev/null; then
        missing+=("git")
    fi

    if ! command -v yq &>/dev/null; then
        missing+=("yq")
    fi

    if ! command -v tmux &>/dev/null; then
        missing+=("tmux")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install with:"
        echo "  brew install ${missing[*]}"
        echo ""
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Optional deps (for smart commands)
    local optional=()
    if ! command -v fzf &>/dev/null; then optional+=("fzf"); fi
    if ! command -v jq &>/dev/null; then optional+=("jq"); fi
    if ! command -v gh &>/dev/null; then optional+=("gh"); fi

    if [[ ${#optional[@]} -gt 0 ]]; then
        log_info "Optional dependencies (for smart commands like 'wt open', 'wt ls', 'wt rm'):"
        for dep in "${optional[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install with: brew install ${optional[*]}"
        echo ""
    fi
}

# Make scripts executable
make_executable() {
    log_info "Making scripts executable..."
    chmod +x "$SCRIPT_DIR/wt.sh"
    chmod +x "$SCRIPT_DIR/install.sh"
    chmod +x "$SCRIPT_DIR/lib/"*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR/commands/"*.sh 2>/dev/null || true
}

# Create symlink
create_symlink() {
    local target_dir="${1:-$HOME/bin}"
    local symlink="$target_dir/wt"

    # Create target directory if needed
    if [[ ! -d "$target_dir" ]]; then
        log_info "Creating directory: $target_dir"
        mkdir -p "$target_dir"
    fi

    # Remove existing symlink
    if [[ -L "$symlink" ]]; then
        log_info "Removing existing symlink..."
        rm "$symlink"
    elif [[ -f "$symlink" ]]; then
        log_warn "File exists at $symlink (not a symlink)"
        read -r -p "Replace? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm "$symlink"
        else
            return 1
        fi
    fi

    # Create symlink
    log_info "Creating symlink: $symlink -> $SCRIPT_DIR/wt.sh"
    ln -s "$SCRIPT_DIR/wt.sh" "$symlink"

    # Check if target_dir is in PATH
    if [[ ":$PATH:" != *":$target_dir:"* ]]; then
        log_warn "$target_dir is not in your PATH"
        echo ""
        echo "Add to your shell profile:"
        echo "  export PATH=\"\$PATH:$target_dir\""
    fi
}

# Link shell completions into $HOME so they track this checkout, replacing
# any existing symlink or stale regular-file copy at the target path.
# Args: $1 shell name ("bash"/"zsh"), defaults to $SHELL's basename
# Side: writes a symlink under $HOME's completion dir; appends a source/fpath
#   line to .bashrc/.zshrc when not already present
install_completions() {
    local shell="${1:-}"

    # Detect shell if not specified
    if [[ -z "$shell" ]]; then
        shell=$(basename "$SHELL")
    fi

    case "$shell" in
        bash)
            local bash_completion_dir="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"
            mkdir -p "$bash_completion_dir"
            ln -sfn "$SCRIPT_DIR/completions/wt.bash" "$bash_completion_dir/wt"
            log_success "Linked bash completions: $bash_completion_dir/wt -> $SCRIPT_DIR/completions/wt.bash"

            # Also add to .bashrc for immediate availability
            local bashrc="$HOME/.bashrc"
            local source_line="source \"$SCRIPT_DIR/completions/wt.bash\""

            if [[ -f "$bashrc" ]]; then
                if ! grep -q "wt.bash" "$bashrc" 2>/dev/null; then
                    echo "" >> "$bashrc"
                    echo "# wt (Git Worktree Manager) completions" >> "$bashrc"
                    echo "$source_line" >> "$bashrc"
                    log_info "Added completion source to $bashrc"
                fi
            fi
            ;;
        zsh)
            local zsh_completion_dir="${ZSH_COMPLETION_DIR:-$HOME/.zsh/completions}"
            mkdir -p "$zsh_completion_dir"
            ln -sfn "$SCRIPT_DIR/completions/wt.zsh" "$zsh_completion_dir/_wt"
            log_success "Linked zsh completions: $zsh_completion_dir/_wt -> $SCRIPT_DIR/completions/wt.zsh"

            # Add to fpath in .zshrc
            local zshrc="$HOME/.zshrc"
            local fpath_line="fpath=($zsh_completion_dir \$fpath)"

            if [[ -f "$zshrc" ]]; then
                if ! grep -q "$zsh_completion_dir" "$zshrc" 2>/dev/null; then
                    echo "" >> "$zshrc"
                    echo "# wt (Git Worktree Manager) completions" >> "$zshrc"
                    echo "$fpath_line" >> "$zshrc"
                    echo "autoload -Uz compinit && compinit" >> "$zshrc"
                    log_info "Added completion fpath to $zshrc"
                fi
            fi
            ;;
        *)
            log_warn "Unknown shell: $shell. Manual completion setup required."
            ;;
    esac
}

# Create config directories
create_config_dirs() {
    log_info "Creating configuration directories..."
    mkdir -p "$HOME/.config/wt/projects"
    mkdir -p "$HOME/.local/share/wt/state"
    mkdir -p "$HOME/.local/share/wt/logs"
}

# Print a usage error naming what's wrong, then exit 2
# Args: $1 the message describing the bad option or argument
# Side: writes to stderr, exits 2
usage_error() {
    log_error "$1" >&2
    echo "Run './install.sh --help' for usage information." >&2
    exit 2
}

# Print install.sh's --help page
# Side: writes to stdout
show_help() {
    cat <<EOF
Usage: ./install.sh [options]

Symlinks wt.sh onto your PATH and links its shell completions so they
track this checkout.

Options:
  --prefix <dir>      Install directory (default: ~/bin)
  --no-completions    Skip shell completion installation (default: installed)
  -h, --help          Show this help and exit

Exit codes:
  0  installed
  1  aborted (e.g. declined a prompt)
  2  usage error
EOF
}

# Parse install.sh's own command-line flags
# Side: sets INSTALL_DIR and SKIP_COMPLETIONS; exits 0 after printing --help;
#   exits 2 via usage_error on an unknown flag, a stray positional argument,
#   or --prefix with no value
parse_args() {
    INSTALL_DIR="$HOME/bin"
    SKIP_COMPLETIONS=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    usage_error "--prefix requires a directory: --prefix <dir>"
                fi
                INSTALL_DIR="$2"
                shift 2
                ;;
            --no-completions)
                SKIP_COMPLETIONS=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                usage_error "Unknown option: $1"
                ;;
        esac
    done
}

# Main installation
# Side: runs check_dependencies, make_executable, create_symlink,
#   install_completions and create_config_dirs, in order
main() {
    local INSTALL_DIR SKIP_COMPLETIONS
    parse_args "$@"

    echo ""
    echo -e "${BOLD}wt - Git Worktree Manager${NC}"
    echo -e "${BOLD}=========================${NC}"
    echo ""

    # Run installation steps
    check_dependencies
    make_executable
    create_symlink "$INSTALL_DIR"

    if [[ "$SKIP_COMPLETIONS" -eq 0 ]]; then
        echo ""
        install_completions
    fi

    create_config_dirs

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
    echo "  2. Verify installation: wt --version"
    echo "  3. Initialize a project: cd <your-repo> && wt init"
    echo ""
    echo "Smart commands: wt open, wt ls, wt rm, wt prune, wt code, wt pr"
    echo "For help: wt --help"
    echo ""
}

main "$@"
