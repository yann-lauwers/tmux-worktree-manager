#!/bin/bash
# commands/init.sh - Initialize project configuration

# Write a new project config for the current git repository.
# Args: flags only
# Side: writes the project config file, updates .gitignore for the default layout, dies (exit 1) on a git-repo or naming failure
cmd_init() {
    local project_name=""
    local force=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)
                die_unknown_option "init" "$1" "use --name"
                ;;
            --name)
                require_optarg "init" "$1" "${2:-}" "wt init [options]"
                project_name="$2"
                shift 2
                ;;
            -f|--force)
                force=1
                shift
                ;;
            -h|--help)
                show_init_help
                return 0
                ;;
            -*)
                die_unknown_option "init" "$1"
                ;;
            *)
                shift
                ;;
        esac
    done

    # Check we're in a git repo
    if ! is_git_repo; then
        die "Not in a git repository. Navigate to a git repo first."
    fi

    local repo_root
    repo_root=$(git_root)

    # Determine project name
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$repo_root")
    fi

    # Sanitize project name: replace unsafe chars with hyphens, strip leading/trailing hyphens
    project_name=$(echo "$project_name" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/^-*//;s/-*$//')

    if [[ -z "$project_name" ]]; then
        die "Could not derive a valid project name. Use --name to specify one."
    fi

    if ! [[ "$project_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        die "Invalid project name: '$project_name'. Must start with alphanumeric and contain only [a-zA-Z0-9._-]"
    fi

    local config_file
    config_file=$(project_config_path "$project_name")

    # Check if config already exists
    if [[ -f "$config_file" ]] && [[ "$force" -eq 0 ]]; then
        die "Configuration already exists: $config_file\nUse --force to overwrite."
    fi

    # Ensure config directories exist
    init_config_dirs

    # Create configuration
    log_info "Creating configuration for project: $project_name"

    cat > "$config_file" << EOF
# Configuration for project: $project_name
name: $project_name
repo_path: $repo_root

# External worktree directory (optional)
# When set, worktrees are created here instead of \$repo/.worktrees/
# worktree_dir: ~/worktrees/$project_name

# Port configuration
ports:
  # Reserved ports for services requiring specific ports
  reserved:
    range: { min: 3000, max: 3005 }
    slots: 3
    services: {}
      # service-name: 0  # offset from slot base

  # Dynamic ports for flexible services
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
      # service-name: true

# Global environment variables
env:
  NODE_ENV: development

# Setup steps (run on worktree create)
setup: []
  # - name: install-deps
  #   description: "Install dependencies"
  #   command: npm install
  #   working_dir: "."
  #   on_failure: abort  # abort | continue | retry
  #   depends_on: []

# Services (can be started/stopped)
services: []
  # - name: app
  #   description: "Main application"
  #   working_dir: "."
  #   command: npm run dev
  #   port_key: app
  #   env:
  #     PORT: "\${PORT}"

# tmux session configuration
tmux:
  layout: tiled
  windows:
    - name: shell
      panes:
        - ""

# Hooks (lifecycle events)
hooks: {}
  # pre_create: |
  #   echo "About to create worktree for \${BRANCH_NAME}"
  # post_create: |
  #   echo "Worktree created at \${WORKTREE_PATH}"
  # pre_start: |
  #   echo "About to start services for \${BRANCH_NAME}"
  # post_start: |
  #   echo "Services started for \${BRANCH_NAME}"
  # post_stop: |
  #   echo "Services stopped for \${BRANCH_NAME}"
  # pre_delete: |
  #   echo "About to delete \${WORKTREE_PATH}"
  # post_delete: |
  #   echo "Worktree deleted for \${BRANCH_NAME}"
EOF

    # Add .worktrees to .gitignore (only when using default in-repo location)
    local wt_dir
    wt_dir=$(yaml_get "$config_file" ".worktree_dir" "")
    if [[ -z "$wt_dir" ]]; then
        local gitignore="$repo_root/.gitignore"
        if [[ -f "$gitignore" ]]; then
            if ! grep -q "^\.worktrees/?$" "$gitignore" 2>/dev/null; then
                echo ".worktrees/" >> "$gitignore"
                log_info "Added .worktrees/ to .gitignore"
            fi
        else
            echo ".worktrees/" > "$gitignore"
            log_info "Created .gitignore with .worktrees/"
        fi
    else
        log_info "External worktree_dir configured — skipping .gitignore"
    fi

    log_success "Configuration created: $config_file"
    echo ""
    echo "Next steps:"
    echo "  1. Edit the configuration to match your project:"
    echo "     \$EDITOR $config_file"
    echo ""
    echo "  2. Create your first worktree:"
    echo "     wt create <branch-name>"
}

# Print the 'wt init' help page to stdout.
show_init_help() {
    cat << 'EOF'
Writes a new project config under the wt config directory for the current git repository, and prints
the path it wrote plus a next-steps hint.
Adds .worktrees/ to the repo's .gitignore when using the default in-repo worktree layout.

Usage: wt init [options]

Options:
  --name <name>       Project name (default: the repo directory's name, sanitized)
  -f, --force          Overwrite an existing configuration (default: off — refuses if one exists)
  -h, --help            Show this page

Examples:
  wt init
  wt init --name my-project
  wt init --force

Exit codes:
  0  configuration written
  1  not in a git repository, config already exists (without --force), or the derived project name
     is invalid
  2  usage error: unknown option or missing option argument
EOF
}
