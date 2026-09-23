#!/bin/bash
# commands/db.sh - Database management for worktrees

# Dispatch to a db subcommand (reset/url/dump/use-remote|detach).
# Args: $1 subcommand, $2... subcommand's own args
# Side: dies (exit 2) on a missing or unknown subcommand
cmd_db() {
    local subcommand="${1:-}"

    if [[ -z "$subcommand" ]]; then
        die_usage "db" "missing subcommand" "wt db <reset|url|dump|use-remote> [options]"
    fi
    shift

    case "$subcommand" in
        reset)
            cmd_db_reset "$@"
            ;;
        url)
            cmd_db_url "$@"
            ;;
        dump)
            cmd_db_dump "$@"
            ;;
        use-remote|detach)
            cmd_db_use_remote "$@"
            ;;
        -h|--help)
            show_db_help
            return 0
            ;;
        -*)
            die_unknown_option "db" "$subcommand"
            ;;
        *)
            die_usage "db" "unknown subcommand '$subcommand'"
            ;;
    esac
}

# Stop, wipe and recreate the ephemeral Postgres for a worktree, then apply migrations or a seed dump.
# Args: none (reads -p/--project, --seed, --fresh, [branch] from argv)
# Side: destroys and recreates the worktree's PG data dir, rewrites its env files
cmd_db_reset() {
    local branch=""
    local project=""
    local fresh_dump=0
    local seed=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "db reset" "$1" "${2:-}" "wt db reset [branch] [options]"
                project="$2"
                shift 2
                ;;
            --fresh)
                fresh_dump=1
                shift
                ;;
            --seed)
                seed=1
                shift
                ;;
            -h|--help)
                show_db_reset_help
                return 0
                ;;
            -*)
                die_unknown_option "db reset" "$1"
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    # Auto-detect branch
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "db reset" "branch name is required and could not be detected" "wt db reset [branch] [options]"
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Resolve PG binaries
    if ! command -v pg_ctl &>/dev/null; then
        export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
    fi
    if ! command -v pg_ctl &>/dev/null; then
        log_error "PostgreSQL not found. Install with: brew install postgresql@17"
        return 1
    fi

    # Derive PG dir and port from config
    local slug
    slug=$(echo "$branch" | sed 's|/|-|g')
    local pg_dir="${HOME}/.local/share/nexus-pg/${slug}"

    local slot
    slot=$(get_slot_for_worktree "$project" "$branch")
    if [[ -z "$slot" ]]; then
        log_error "No slot found for branch: $branch (is this a worktree?)"
        return 1
    fi

    local backend_port
    backend_port=$(get_service_port "backend" "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project")
    local pg_port=$((backend_port + 51300))
    local db_url
    # today's local-assign masked a failing whoami (status 0 from local); keep that behaviour under the split form
    db_url="postgresql://$(whoami)@localhost:${pg_port}/postgres" || true

    echo ""
    log_info "Resetting database for ${CYAN}${branch}${NC}"
    print_kv "PG dir" "$pg_dir"
    print_kv "PG port" "$pg_port"
    print_kv "DB URL" "$db_url"
    echo ""

    # Step 1: Stop existing PG
    if [[ -d "$pg_dir" ]]; then
        log_info "Stopping existing Postgres..."
        pg_ctl -D "$pg_dir" stop -m fast 2>/dev/null || true
        rm -rf "$pg_dir"
        log_success "Old data directory removed"
    else
        log_info "No existing data directory found"
    fi

    # Step 2: Init fresh PG
    log_info "Initializing fresh Postgres..."
    mkdir -p "${HOME}/.local/share/nexus-pg"
    initdb -D "$pg_dir" --no-locale --encoding=UTF8 --auth=trust > /dev/null
    pg_ctl -D "$pg_dir" -o "-p $pg_port -k /tmp" -l "$pg_dir/pg.log" start

    # Wait for ready
    local tries=0
    until pg_isready -h localhost -p "$pg_port" -q; do
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            log_error "Postgres not ready after 30 attempts. Log: $pg_dir/pg.log"
            return 1
        fi
        sleep 0.2
    done
    log_success "Fresh Postgres running on port $pg_port"

    # Step 3: Wire DB URLs in env files
    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")
    if [[ -n "$worktree_path" ]]; then
        for envfile in "$worktree_path/packages/prisma-db/.env" "$worktree_path/apps/backend/.env"; do
            if [[ -f "$envfile" ]]; then
                sed -i '' "s|^DATABASE_URL=.*|DATABASE_URL=${db_url}|" "$envfile"
                sed -i '' "s|^DIRECT_URL=.*|DIRECT_URL=${db_url}|" "$envfile"
            fi
        done
        log_success "DB URLs wired in env files"
    fi

    # Step 4: Apply schema
    if [[ $seed -eq 1 ]]; then
        # Seed mode: restore from the seed-source dump
        local seed_dump="$HOME/.local/share/nexus/seed.dump"
        local seed_max_age=$(( 24 * 3600 ))

        # Auto-refresh if dump is missing or older than 24h
        if [[ $fresh_dump -eq 0 ]]; then
            if [[ ! -f "$seed_dump" ]]; then
                log_info "No cached dump found — refreshing from the seed source"
                fresh_dump=1
            else
                local seed_age=$(( $(date +%s) - $(stat -f%m "$seed_dump") ))
                if (( seed_age > seed_max_age )); then
                    local seed_hours=$(( seed_age / 3600 ))
                    log_info "Cached dump is ${seed_hours}h old (>24h) — refreshing from the seed source"
                    fresh_dump=1
                fi
            fi
        fi

        if [[ $fresh_dump -eq 1 ]]; then
            log_info "Refreshing the seed-source dump..."
            rm -f "$seed_dump"

            local repo_path
            repo_path=$(yaml_get "$PROJECT_CONFIG_FILE" ".repo_path" "")
            repo_path="${repo_path/#\~/$HOME}"

            local seed_source_url
            seed_source_url=$(grep '^DIRECT_URL=' "$repo_path/packages/prisma-db/.env" 2>/dev/null | cut -d= -f2-)
            if [[ -z "$seed_source_url" ]]; then
                log_warn "No DIRECT_URL in main repo — cannot dump the seed source"
            else
                mkdir -p "$(dirname "$seed_dump")"
                if ! { pg_dump --format=custom --no-owner --no-acl "$seed_source_url" > "$seed_dump.tmp" \
                    && mv "$seed_dump.tmp" "$seed_dump" \
                    && log_success "Seed-source DB dumped ($(du -h "$seed_dump" | cut -f1))"; }; then
                    log_warn "pg_dump failed — falling back to migrate deploy"
                    rm -f "$seed_dump.tmp"
                fi
            fi
        fi

        if [[ -f "$seed_dump" ]]; then
            log_info "Restoring seed dump..."
            pg_restore --no-owner --no-acl --clean --if-exists -d "$db_url" "$seed_dump" 2>&1 \
                | grep -v "^pg_restore: warning" || true
            log_success "Seed dump restored"
        else
            log_warn "No seed dump found — falling back to migrate deploy"
            (
                cd "$worktree_path" 2>/dev/null || true
                DATABASE_URL="$db_url" DIRECT_URL="$db_url" \
                    pnpm --filter @nexus/prisma exec prisma migrate deploy
            )
            log_success "All migrations applied"
        fi
    else
        # Default: clean migration state
        log_info "Running prisma migrate deploy..."
        (
            cd "$worktree_path" 2>/dev/null || true
            DATABASE_URL="$db_url" DIRECT_URL="$db_url" \
                pnpm --filter @nexus/prisma exec prisma migrate deploy
        )
        log_success "All migrations applied from scratch"
    fi

    echo ""
    log_success "Database reset complete!"
    print_kv "Connection" "$db_url"
    echo ""
}

# Print the database connection URL for a worktree's slot.
# Args: none (reads -p/--project and [branch] from argv)
# Out: the connection URL
cmd_db_url() {
    local branch=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "db url" "$1" "${2:-}" "wt db url [branch] [options]"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_db_url_help
                return 0
                ;;
            -*)
                die_unknown_option "db url" "$1"
                ;;
            *)
                [[ -z "$branch" ]] && branch="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "db url" "branch name is required and could not be detected" "wt db url [branch] [options]"
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    if ! resolve_db_url "$PROJECT_CONFIG_FILE"; then
        log_error "No db.url_template in project config"
        return 1
    fi
}

# Print the 'wt db url' help page to stdout.
show_db_url_help() {
    cat << 'EOF'
Prints the database connection URL for a worktree's slot to stdout, and nothing else on success.

Usage: wt db url [branch] [options]

Arguments:
  [branch]          Full branch name (default: the current git branch)

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt db url
  wt db url feature/auth

Exit codes:
  0  URL printed
  1  no db.url_template in the project config
  2  usage error: unknown option, missing option argument, or missing branch
EOF
}

# Refresh the cached seed-source dump from the main repo's DIRECT_URL.
# Args: none (reads -p/--project from argv)
# Side: writes ~/.local/share/nexus/seed.dump
cmd_db_dump() {
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "db dump" "$1" "${2:-}" "wt db dump [options]"
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_db_dump_help
                return 0
                ;;
            -*)
                die_unknown_option "db dump" "$1"
                ;;
            *)
                shift
                ;;
        esac
    done

    # Resolve PG binaries
    if ! command -v pg_dump &>/dev/null; then
        export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
    fi
    if ! command -v pg_dump &>/dev/null; then
        log_error "PostgreSQL not found. Install with: brew install postgresql@17"
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Always read DIRECT_URL from the main repo (root worktree)
    local repo_path
    repo_path=$(yaml_get "$PROJECT_CONFIG_FILE" ".repo_path" "")
    repo_path="${repo_path/#\~/$HOME}"

    if [[ -z "$repo_path" ]] || [[ ! -d "$repo_path" ]]; then
        log_error "Main repo not found at: $repo_path"
        return 1
    fi

    local seed_source_url
    seed_source_url=$(grep '^DIRECT_URL=' "$repo_path/packages/prisma-db/.env" 2>/dev/null | cut -d= -f2-)
    if [[ -z "$seed_source_url" ]]; then
        log_error "No DIRECT_URL found in $repo_path/packages/prisma-db/.env"
        return 1
    fi

    local seed_dump="$HOME/.local/share/nexus/seed.dump"
    mkdir -p "$(dirname "$seed_dump")"

    # Show current cache age if it exists
    if [[ -f "$seed_dump" ]]; then
        local age=$(( $(date +%s) - $(stat -f%m "$seed_dump") ))
        local hours=$(( age / 3600 ))
        local mins=$(( (age % 3600) / 60 ))
        log_info "Current dump is ${hours}h${mins}m old ($(du -h "$seed_dump" | cut -f1))"
    else
        log_info "No cached dump found"
    fi

    log_info "Dumping the seed-source DB from main repo..."
    print_kv "Source" "$repo_path/packages/prisma-db/.env"
    print_kv "Target" "$seed_dump"
    echo ""

    if ! { pg_dump --format=custom --no-owner --no-acl "$seed_source_url" > "$seed_dump.tmp" \
        && mv "$seed_dump.tmp" "$seed_dump" \
        && log_success "Seed-source DB dumped ($(du -h "$seed_dump" | cut -f1))"; }; then
        log_error "pg_dump failed"
        rm -f "$seed_dump.tmp"
        return 1
    fi
}

# Print the 'wt db dump' help page to stdout.
show_db_dump_help() {
    cat << 'EOF'
Refreshes the cached seed-source dump from the main repo's DIRECT_URL, reading the connection string
from the root checkout, never the current worktree.

Usage: wt db dump [options]

Options:
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt db dump
  wt db dump --project myproject

Cache: ~/.local/share/nexus/seed.dump

Exit codes:
  0  dump refreshed
  1  pg_dump not found, main repo not found, no DIRECT_URL in its env file, or pg_dump failed
  2  usage error: unknown option or missing option argument
EOF
}

# Print the 'wt db' help page to stdout.
show_db_help() {
    cat << 'EOF'
Manages the ephemeral Postgres instance for a worktree: reset it, point it at the main repo's remote
DB instead, refresh the cached seed dump, or print its connection URL.

Usage: wt db <subcommand> [options]

Subcommands:
  reset [branch]       Stop, wipe, and recreate the ephemeral Postgres (see 'wt db reset --help')
  use-remote [branch]  Stop the ephemeral and point env refs at the main repo's remote DB — alias:
                       detach (see 'wt db use-remote --help')
  dump                 Refresh the cached seed-source dump from the main repo (see 'wt db dump
                       --help')
  url [branch]         Print the database connection URL (see 'wt db url --help')

Options:
  -h, --help         Show this page

Examples:
  wt db reset                    # Fresh DB + replay all migrations
  wt db reset --seed             # Restore from cached seed-source dump instead
  wt db reset --seed --fresh     # Re-dump the seed source first, then restore
  wt db use-remote               # Kill ephemeral + point env at remote DB
  wt db use-remote -y            # Same, skip confirmation
  wt db dump                     # Refresh seed-source dump cache
  wt db url                      # Print DB URL for current worktree

Exit codes:
  0  subcommand ran and reported success
  1  operational failure in the chosen subcommand
  2  usage error: missing subcommand or unknown subcommand/option
EOF
}

# Stop a worktree's ephemeral Postgres and point its env files at the main repo's remote DB.
# Args: none (reads -p/--project, -y/--yes, [branch] from argv)
# Side: removes the worktree's PG data dir, rewrites its env files; prompts for confirmation unless -y
cmd_db_use_remote() {
    local branch=""
    local project=""
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                require_optarg "db use-remote" "$1" "${2:-}" "wt db use-remote [branch] [options]"
                project="$2"
                shift 2
                ;;
            -y|--yes)
                force=1
                shift
                ;;
            -h|--help)
                show_db_use_remote_help
                return 0
                ;;
            -*)
                die_unknown_option "db use-remote" "$1"
                ;;
            *)
                [[ -z "$branch" ]] && branch="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            die_usage "db use-remote" "branch name is required and could not be detected" "wt db use-remote [branch] [options]"
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    if ! command -v pg_ctl &>/dev/null; then
        export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
    fi

    local slug
    slug=$(echo "$branch" | sed 's|/|-|g')
    local pg_dir="${HOME}/.local/share/nexus-pg/${slug}"

    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")
    if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree path not found for branch: $branch"
        return 1
    fi

    local repo_path
    repo_path=$(yaml_get "$PROJECT_CONFIG_FILE" ".repo_path" "")
    repo_path="${repo_path/#\~/$HOME}"
    if [[ -z "$repo_path" ]] || [[ ! -d "$repo_path" ]]; then
        log_error "Main repo not found at: $repo_path"
        return 1
    fi
    if [[ "$worktree_path" == "$repo_path" ]]; then
        log_error "Refusing to run on the main repo itself — this command is for worktrees only"
        return 1
    fi

    local main_prisma_env="$repo_path/packages/prisma-db/.env"
    if [[ ! -f "$main_prisma_env" ]]; then
        log_error "Main repo missing: $main_prisma_env"
        return 1
    fi
    local remote_db_line remote_direct_line
    remote_db_line=$(grep '^DATABASE_URL=' "$main_prisma_env" | head -1)
    remote_direct_line=$(grep '^DIRECT_URL=' "$main_prisma_env" | head -1)
    if [[ -z "$remote_db_line" ]] || [[ -z "$remote_direct_line" ]]; then
        log_error "DATABASE_URL or DIRECT_URL missing in $main_prisma_env"
        return 1
    fi

    local remote_host
    remote_host=$(echo "$remote_direct_line" | sed -E 's|.*@([^:/?]+).*|\1|')

    echo ""
    log_warn "This will detach ${CYAN}${branch}${NC} from its ephemeral Postgres"
    print_kv "PG dir to delete" "$pg_dir"
    print_kv "Env files to rewrite" "packages/prisma-db/.env, apps/backend/.env"
    print_kv "New DB host" "$remote_host"
    echo ""
    log_warn "After this, prisma/app writes go to the SHARED remote DB."
    echo ""

    if [[ $force -ne 1 ]]; then
        printf "Proceed? [y/N] "
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) log_info "Aborted."; return 0 ;;
        esac
    fi

    local pg_prefix="${HOME}/.local/share/nexus-pg/"
    if [[ -d "$pg_dir" ]] && [[ "$pg_dir" == "${pg_prefix}"* ]]; then
        log_info "Stopping ephemeral Postgres..."
        pg_ctl -D "$pg_dir" stop -m fast 2>/dev/null || true
        rm -rf "$pg_dir"
        log_success "Ephemeral data directory removed"
    else
        log_info "No ephemeral data directory to remove"
    fi

    # sed replacement: escape \ and & in the source line so it's literal
    _escape_sed_repl() {
        local s="$1"
        s=${s//\\/\\\\}
        s=${s//&/\\&}
        s=${s//|/\\|}
        printf '%s' "$s"
    }

    for rel in packages/prisma-db/.env apps/backend/.env; do
        local wt_env="$worktree_path/$rel"
        local main_env="$repo_path/$rel"
        if [[ ! -f "$main_env" ]]; then
            log_warn "Main repo missing $rel — skipping"
            continue
        fi
        if [[ ! -f "$wt_env" ]]; then
            log_warn "Worktree missing $rel — skipping"
            continue
        fi
        local db_line direct_line
        db_line=$(grep '^DATABASE_URL=' "$main_env" | head -1)
        direct_line=$(grep '^DIRECT_URL=' "$main_env" | head -1)
        if [[ -n "$db_line" ]]; then
            sed -i '' "s|^DATABASE_URL=.*|$(_escape_sed_repl "$db_line")|" "$wt_env"
        fi
        if [[ -n "$direct_line" ]]; then
            sed -i '' "s|^DIRECT_URL=.*|$(_escape_sed_repl "$direct_line")|" "$wt_env"
        fi
        log_success "Reset refs in $rel"
    done

    echo ""
    log_success "Worktree now uses remote DB from main repo"
    print_kv "Host" "$remote_host"
    echo ""
}

# Print the 'wt db use-remote' help page to stdout.
show_db_use_remote_help() {
    cat << 'EOF'
Stops the ephemeral Postgres for a worktree and rewrites its env files so DATABASE_URL / DIRECT_URL
point at the main repo's remote DB.

Prompts "Proceed? [y/N]" before touching anything, unless -y is given; declining prints "Aborted."
and exits 0, the same as running nothing.

Usage: wt db use-remote [branch] [options]

Arguments:
  [branch]           Full branch name (default: the current git branch)

Options:
  -y, --yes            Skip the confirmation prompt (default: off — prompts)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt db use-remote                      # Prompt, then detach current worktree
  wt db use-remote -y                   # Detach without prompting
  wt db use-remote yann-lauwers/nex-123 # Detach a specific worktree

Aliases: wt db detach

Exit codes:
  0  detached, or the confirmation was declined
  1  worktree or main repo not found, or the main repo's env file is missing DATABASE_URL/DIRECT_URL
  2  usage error: unknown option, missing option argument, or missing branch
EOF
}

# Print the 'wt db reset' help page to stdout.
show_db_reset_help() {
    cat << 'EOF'
Stops, wipes, and recreates the ephemeral Postgres for a worktree, rewires its env files at
DATABASE_URL/DIRECT_URL, and by default runs prisma migrate deploy for a clean migration state.

Usage: wt db reset [branch] [options]

Arguments:
  [branch]           Full branch name (default: the current git branch)

Options:
  --seed              Restore from the cached seed-source dump instead of migrating (default: off
                      — migrates)
  --fresh              Re-dump the seed source before restoring; requires --seed (default: off —
                       uses the cached dump)
  -p, --project <name>   Project to act on (default: detected from the current directory)
  -h, --help              Show this page

Examples:
  wt db reset                           # Fresh DB + replay all migrations
  wt db reset --seed                    # Restore from cached seed-source dump
  wt db reset --seed --fresh            # Re-dump the seed source first, then restore
  wt db reset yann-lauwers/nex-1663     # Reset for specific branch

Exit codes:
  0  database reset
  1  PostgreSQL not found, no slot for the branch, Postgres failed to start, or no DIRECT_URL to
     dump from
  2  usage error: unknown option, missing option argument, or missing branch
EOF
}
