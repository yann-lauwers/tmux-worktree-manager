#!/bin/bash
# commands/config.sh - View and edit configuration

# View or edit a project's or the global wt configuration file.
# Args: none (reads -e/--edit, -g/--global, -p/--project, --path, and [project] from argv)
# Side: may write a default global config, opens $EDITOR with --edit, or prints the file/path
cmd_config() {
    local edit=0
    local global=0
    local project=""
    local show_path=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--edit)
                edit=1
                shift
                ;;
            -g|--global)
                global=1
                shift
                ;;
            -p|--project)
                require_optarg "config" "$1" "${2:-}" "wt config [options] [project]"
                project="$2"
                shift 2
                ;;
            --path)
                show_path=1
                shift
                ;;
            -h|--help)
                show_config_help
                return 0
                ;;
            -*)
                die_unknown_option "config" "$1"
                ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                fi
                shift
                ;;
        esac
    done

    local config_file

    if [[ "$global" -eq 1 ]]; then
        config_file=$(global_config_path)

        # Create default global config if it doesn't exist
        if [[ ! -f "$config_file" ]]; then
            init_config_dirs
            cat > "$config_file" << 'EOF'
# Global wt configuration

# Default settings for all projects
defaults:
  worktree_dir: ".worktrees"
  port_range:
    min: 3000
    max: 5000
  tmux:
    prefix: "wt"
    default_layout: "even-horizontal"

# Editor to use for editing configs
editor:
  default: "${EDITOR:-vim}"
EOF
            log_info "Created default global config"
        fi
    else
        # Project config
        project=$(require_project "$project" "Could not detect project. Specify a project name or use --global.")

        config_file=$(project_config_path "$project")

        if [[ ! -f "$config_file" ]]; then
            die "No configuration found for project: $project\nRun 'wt init' in the project directory first."
        fi
    fi

    if [[ "$show_path" -eq 1 ]]; then
        echo "$config_file"
        return 0
    fi

    if [[ "$edit" -eq 1 ]]; then
        local editor="${EDITOR:-vim}"
        log_info "Opening: $config_file"
        $editor "$config_file"
    else
        # Display config
        echo ""
        if [[ "$global" -eq 1 ]]; then
            echo -e "${BOLD}Global Configuration${NC}"
        else
            echo -e "${BOLD}Project Configuration: ${CYAN}$project${NC}"
        fi
        echo "File: $config_file"
        echo "$(printf '%.0s-' {1..60})"
        echo ""

        if command_exists bat; then
            bat --style=plain --language=yaml "$config_file"
        elif command_exists pygmentize; then
            pygmentize -l yaml "$config_file"
        else
            cat "$config_file"
        fi
    fi
}

# Print the 'wt config' help page to stdout.
show_config_help() {
    cat << 'EOF'
Reads a project's or the global wt configuration file and prints it to stdout, syntax-highlighted
when bat or pygmentize is on PATH.
Opens the file in $EDITOR instead with --edit; --global writes a default global config first if none
exists yet, a project config dies if its own file is missing.

Usage: wt config [options] [project]

Arguments:
  [project]         Project name (default: detected from the current directory)

Options:
  -e, --edit          Open the configuration in $EDITOR instead of printing it (default: off —
                      prints)
  -g, --global        Act on the global configuration instead of a project's (default: off —
                      project config)
  -p, --project <name>   Project name (default: detected from the current directory, or the
                         [project] argument)
  --path              Print only the config file's path (default: off)
  -h, --help            Show this page

Examples:
  wt config                   # Show current project config
  wt config --edit            # Edit current project config
  wt config --global          # Show global config
  wt config --global --edit   # Edit global config
  wt config myproject         # Show specific project config
  wt config --path            # Print config file path

Exit codes:
  0  printed, edited, or path shown
  1  no project detected and none given, or no configuration found for the project
  2  usage error: unknown option or missing option argument
EOF
}
