#!/bin/bash
# wt - Git Worktree Manager
# A CLI tool for managing git worktrees with tmux integration

set -euo pipefail

VERSION="2.0.0"

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
source "${WT_SCRIPT_DIR}/lib/config.sh"
source "${WT_SCRIPT_DIR}/lib/port.sh"
source "${WT_SCRIPT_DIR}/lib/state.sh"
source "${WT_SCRIPT_DIR}/lib/worktree.sh"
source "${WT_SCRIPT_DIR}/lib/setup.sh"
source "${WT_SCRIPT_DIR}/lib/tmux.sh"
source "${WT_SCRIPT_DIR}/lib/service.sh"
source "${WT_SCRIPT_DIR}/lib/smart.sh"

# Source command modules
source "${WT_SCRIPT_DIR}/commands/create.sh"
source "${WT_SCRIPT_DIR}/commands/delete.sh"
source "${WT_SCRIPT_DIR}/commands/list.sh"
source "${WT_SCRIPT_DIR}/commands/start.sh"
source "${WT_SCRIPT_DIR}/commands/stop.sh"
source "${WT_SCRIPT_DIR}/commands/status.sh"
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
source "${WT_SCRIPT_DIR}/commands/new.sh"
source "${WT_SCRIPT_DIR}/commands/open.sh"
source "${WT_SCRIPT_DIR}/commands/smartlist.sh"
source "${WT_SCRIPT_DIR}/commands/smartdelete.sh"
source "${WT_SCRIPT_DIR}/commands/prune.sh"
source "${WT_SCRIPT_DIR}/commands/code.sh"
source "${WT_SCRIPT_DIR}/commands/pr.sh"

# Show help
show_help() {
    echo -e "${BOLD}wt${NC} - Git Worktree Manager v${VERSION}

${BOLD}USAGE${NC}
    wt <command> [arguments] [options]

${BOLD}SMART COMMANDS${NC}
    ${CYAN}new, n${NC}          Smart create (Linear-aware, scratch, plain branch)
    ${CYAN}open, o${NC}         Open worktree in cmux/tmux (fzf picker)
    ${CYAN}ls${NC}              List all worktrees across projects (PR status)
    ${CYAN}rm${NC}              Smart delete (fzf multi-select)
    ${CYAN}prune${NC}           Delete worktrees whose PRs have been merged
    ${CYAN}code, cursor${NC}    Open worktree in editor (fzf picker)
    ${CYAN}pr${NC}              Open PR in browser for a branch

${BOLD}CORE COMMANDS${NC}
    ${CYAN}Worktree Management${NC}
    create          Create a new worktree (basic)
    delete          Delete a worktree (basic)
    list            List worktrees (single project)

    ${CYAN}Service Management${NC}
    start, up       Start services in a worktree
    stop, down      Stop services in a worktree
    status, st      Show worktree status

    ${CYAN}Session Management${NC}
    attach, a       Attach to tmux session

    ${CYAN}Tmux Integration${NC}
    send, s         Send command to a tmux pane
    logs, log       Capture pane output
    panes           List panes for a worktree

    ${CYAN}Utilities${NC}
    run             Run a setup step
    exec            Execute command in worktree
    ports           Show port assignments
    doctor, doc     Run diagnostic checks

    ${CYAN}Configuration${NC}
    init            Initialize project configuration
    config          View/edit configuration

${BOLD}OPTIONS${NC}
    -p, --project   Specify project name
    -v, --verbose   Enable verbose output
    -h, --help      Show help for command
    --version       Show version

${BOLD}EXAMPLES${NC}
    # Smart create from Linear task
    wt new NEX-1500

    # Smart create with plain branch
    wt new fix/my-bug

    # Open worktree (fzf picker)
    wt open

    # List all worktrees with PR status
    wt ls

    # Basic worktree create
    wt create feature/auth --from develop

    # Start all services
    wt start feature/auth --all

    # Prune merged worktrees
    wt prune

${BOLD}CONFIGURATION${NC}
    Global config:  ~/.config/wt/config.yaml
    Project configs: ~/.config/wt/projects/<name>.yaml

For more information on a command, run:
    wt <command> --help
"
}

# Show version
show_version() {
    echo "wt version $VERSION"
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
            echo "  - $dep"
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
            echo "  - $dep"
        done
        echo ""
    fi
}

# Main command dispatcher
main() {
    # Handle no arguments
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command="$1"
    shift

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

    # Check dependencies before running commands
    check_dependencies

    # Initialize config directories
    init_config_dirs

    # Dispatch to command handlers
    # Smart commands first (override core aliases where applicable)
    case "$command" in
        n|new)
            cmd_new "$@"
            ;;
        o|open)
            cmd_open "$@"
            ;;
        ls)
            cmd_smartlist "$@"
            ;;
        rm)
            cmd_smartdelete "$@"
            ;;
        prune)
            cmd_prune "$@"
            ;;
        code|cursor)
            cmd_code "$@"
            ;;
        pr)
            cmd_pr "$@"
            ;;
        # Core commands
        create)
            cmd_create "$@"
            ;;
        delete)
            cmd_delete "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        start|up)
            cmd_start "$@"
            ;;
        stop|down)
            cmd_stop "$@"
            ;;
        status|st)
            cmd_status "$@"
            ;;
        attach|a)
            cmd_attach "$@"
            ;;
        run)
            cmd_run "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        init)
            cmd_init "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        ports)
            cmd_ports "$@"
            ;;
        send|s)
            cmd_send "$@"
            ;;
        logs|log)
            cmd_logs "$@"
            ;;
        panes)
            cmd_panes "$@"
            ;;
        doctor|doc)
            cmd_doctor "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            echo "Run 'wt --help' for usage information."
            exit 1
            ;;
    esac
}

# Run main
main "$@"
