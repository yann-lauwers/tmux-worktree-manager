#!/bin/bash
# commands/db.sh - Database management for worktrees

cmd_db() {
    local subcommand="${1:-}"

    if [[ -z "$subcommand" ]]; then
        show_db_help
        return 1
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
        *)
            log_error "Unknown db subcommand: $subcommand"
            show_db_help
            return 1
            ;;
    esac
}

cmd_db_reset() {
    local branch=""
    local project=""
    local fresh_dump=0
    local seed=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
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
                log_error "Unknown option: $1"
                show_db_reset_help
                return 1
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
            log_error "Branch name is required (could not auto-detect)"
            return 1
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
    local db_url="postgresql://$(whoami)@localhost:${pg_port}/postgres"

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
        # Seed mode: restore from staging dump
        local seed_dump="$HOME/.local/share/nexus/seed.dump"
        local seed_max_age=$(( 24 * 3600 ))

        # Auto-refresh if dump is missing or older than 24h
        if [[ $fresh_dump -eq 0 ]]; then
            if [[ ! -f "$seed_dump" ]]; then
                log_info "No cached dump found — refreshing from staging"
                fresh_dump=1
            else
                local seed_age=$(( $(date +%s) - $(stat -f%m "$seed_dump") ))
                if (( seed_age > seed_max_age )); then
                    local seed_hours=$(( seed_age / 3600 ))
                    log_info "Cached dump is ${seed_hours}h old (>24h) — refreshing from staging"
                    fresh_dump=1
                fi
            fi
        fi

        if [[ $fresh_dump -eq 1 ]]; then
            log_info "Refreshing staging dump..."
            rm -f "$seed_dump"

            local repo_path
            repo_path=$(yaml_get "$PROJECT_CONFIG_FILE" ".repo_path" "")
            repo_path="${repo_path/#\~/$HOME}"

            local staging_url
            staging_url=$(grep '^DIRECT_URL=' "$repo_path/packages/prisma-db/.env" 2>/dev/null | cut -d= -f2-)
            if [[ -z "$staging_url" ]]; then
                log_warn "No DIRECT_URL in main repo — cannot dump staging"
            else
                mkdir -p "$(dirname "$seed_dump")"
                pg_dump --format=custom --no-owner --no-acl "$staging_url" > "$seed_dump.tmp" \
                    && mv "$seed_dump.tmp" "$seed_dump" \
                    && log_success "Staging DB dumped ($(du -h "$seed_dump" | cut -f1))" \
                    || { log_warn "pg_dump failed — falling back to migrate deploy"; rm -f "$seed_dump.tmp"; }
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

cmd_db_url() {
    local branch=""
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                [[ -z "$branch" ]] && branch="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        [[ -z "$branch" ]] && { log_error "Branch name required"; return 1; }
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    if ! resolve_db_url "$PROJECT_CONFIG_FILE"; then
        log_error "No db.url_template in project config"
        return 1
    fi
}

cmd_db_dump() {
    local project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: wt db dump [-p project]"
                echo ""
                echo "Refresh the cached staging dump from the main repo's DIRECT_URL."
                echo "Reads connection string from the root worktree (not the current one)."
                echo ""
                echo "Cache: ~/.local/share/nexus/seed.dump"
                return 0
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

    local staging_url
    staging_url=$(grep '^DIRECT_URL=' "$repo_path/packages/prisma-db/.env" 2>/dev/null | cut -d= -f2-)
    if [[ -z "$staging_url" ]]; then
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

    log_info "Dumping staging DB from main repo..."
    print_kv "Source" "$repo_path/packages/prisma-db/.env"
    print_kv "Target" "$seed_dump"
    echo ""

    pg_dump --format=custom --no-owner --no-acl "$staging_url" > "$seed_dump.tmp" \
        && mv "$seed_dump.tmp" "$seed_dump" \
        && log_success "Staging DB dumped ($(du -h "$seed_dump" | cut -f1))" \
        || { log_error "pg_dump failed"; rm -f "$seed_dump.tmp"; return 1; }
}

show_db_help() {
    cat << 'EOF'
Usage: wt db <subcommand> [options]

Database management for worktrees.

Subcommands:
  reset [branch]     Stop, wipe, and recreate the ephemeral Postgres
  use-remote [branch] Stop the ephemeral and point env refs at main repo's remote DB
  dump               Refresh the cached staging dump from main repo
  url [branch]       Print the database connection URL

Options:
  -h, --help         Show this help message

Examples:
  wt db reset                    # Fresh DB + replay all migrations
  wt db reset --seed             # Restore from cached staging dump instead
  wt db reset --seed --fresh     # Re-dump staging first, then restore
  wt db use-remote               # Kill ephemeral + point env at remote DB
  wt db use-remote -y            # Same, skip confirmation
  wt db dump                     # Refresh staging dump cache
  wt db url                      # Print DB URL for current worktree
EOF
}

cmd_db_use_remote() {
    local branch=""
    local project=""
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
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
                log_error "Unknown option: $1"
                show_db_use_remote_help
                return 1
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
            log_error "Branch name is required (could not auto-detect)"
            return 1
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

show_db_use_remote_help() {
    cat << 'EOF'
Usage: wt db use-remote [branch] [options]

Stop the ephemeral Postgres for a worktree and rewrite its env files so
DATABASE_URL / DIRECT_URL point at the main repo's remote DB.

Arguments:
  [branch]           Branch name (defaults to current branch)

Options:
  -y, --yes          Skip the confirmation prompt
  -p, --project      Project name (auto-detected if not specified)
  -h, --help         Show this help message

Examples:
  wt db use-remote                      # Prompt, then detach current worktree
  wt db use-remote -y                   # Detach without prompting
  wt db use-remote yann-lauwers/nex-123 # Detach a specific worktree

Aliases: wt db detach
EOF
}

show_db_reset_help() {
    cat << 'EOF'
Usage: wt db reset [branch] [options]

Stop, wipe, and recreate the ephemeral Postgres for a worktree.
By default, runs prisma migrate deploy for a clean migration state.

Arguments:
  [branch]           Branch name (defaults to current branch)

Options:
  --seed             Restore from cached staging dump instead of migrating
  --fresh            Re-dump staging before restoring (requires --seed)
  -p, --project      Project name (auto-detected if not specified)
  -h, --help         Show this help message

Examples:
  wt db reset                           # Fresh DB + replay all migrations
  wt db reset --seed                    # Restore from cached staging dump
  wt db reset --seed --fresh            # Re-dump staging first, then restore
  wt db reset yann-lauwers/nex-1663     # Reset for specific branch
EOF
}
