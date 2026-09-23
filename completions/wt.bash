#!/bin/bash
# Bash completion for wt (Git Worktree Manager)

_wt_completions() {
    # shellcheck disable=SC2034  # words/cword are populated by _init_completion (bash-completion API); not read directly here.
    local cur prev words cword
    _init_completion || return

    local commands="create c open o ls rm prune code cursor pr delete list start up stop down status st health hc attach a run exec init config ports send s logs log panes doctor doc db help version"

    # Get current word and previous word
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Determine the command (first non-option argument)
    local cmd=""
    for ((i=1; i < COMP_CWORD; i++)); do
        if [[ "${COMP_WORDS[i]}" != -* ]]; then
            cmd="${COMP_WORDS[i]}"
            break
        fi
    done

    # Fill COMPREPLY from compgen's candidates, one per array element, bash-3.2-safe.
    # Args: $1 wordlist passed to `compgen -W`, $2 the word being completed
    # Side: sets COMPREPLY
    _wt_compreply_from() {
        local wordlist="$1" cur_word="$2" candidate
        COMPREPLY=()
        while IFS= read -r candidate; do
            COMPREPLY+=("$candidate")
        done < <(compgen -W "$wordlist" -- "$cur_word")
    }

    # Helper: get service names from project config
    _wt_service_names() {
        local project_dir="$HOME/.config/wt/projects"
        local repo_root
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return
        local project_name
        project_name=$(basename "$repo_root")
        local config="$project_dir/${project_name}.yaml"
        if [[ -f "$config" ]] && command -v yq &>/dev/null; then
            yq -r '.services[].name // empty' "$config" 2>/dev/null
        fi
    }

    # Complete options for specific flags
    case "$prev" in
        -p|--project)
            # Complete with project names
            local projects=""
            if [[ -d "$HOME/.config/wt/projects" ]]; then
                projects=$(find "$HOME/.config/wt/projects" -maxdepth 1 -name '*.yaml' 2>/dev/null | sed 's|.*/||; s/\.yaml$//')
            fi
            _wt_compreply_from "$projects" "$cur"
            return
            ;;
        --from)
            # Complete with branch names
            local branches
            branches=$(git branch -a 2>/dev/null | sed 's/^[* ]*//' | sed 's|remotes/origin/||' | sort -u)
            _wt_compreply_from "$branches" "$cur"
            return
            ;;
        -s|--service)
            # Complete with service names from config
            local services
            services=$(_wt_service_names)
            _wt_compreply_from "$services" "$cur"
            return
            ;;
        -w|--window)
            # Complete with window names
            COMPREPLY=()
            return
            ;;
        --lines|-n)
            # Numeric argument, no completion
            COMPREPLY=()
            return
            ;;
    esac

    # Complete based on command
    case "$cmd" in
        "")
            # No command yet, complete with commands
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-h --help -v --version" "$cur"
            else
                _wt_compreply_from "$commands" "$cur"
            fi
            ;;
        open|o)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-p --project -a --all -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        prune)
            _wt_compreply_from "-y --yes -p --project -h --help" "$cur"
            ;;
        code|cursor|pr)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        ls)
            _wt_compreply_from "-p --project -q --quick -s --status --json -h --help" "$cur"
            ;;
        rm)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-m --merged -y --yes -f --force --keep-branch -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        create|c)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "--from --no-setup --skip-groups --no-db --db -p --project -h --help" "$cur"
            else
                # Complete with remote branches not yet checked out locally
                local branches
                branches=$(git branch -r 2>/dev/null | sed 's|origin/||' | grep -v HEAD | sort -u)
                _wt_compreply_from "$branches" "$cur"
            fi
            ;;
        start|up)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-s --service --front --back --tmux --attach -p --project -h --help" "$cur"
            else
                # Complete with worktrees and service names
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services
                services=$(_wt_service_names)
                _wt_compreply_from "$worktrees $services" "$cur"
            fi
            ;;
        stop|down)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-s --service -a --all -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services
                services=$(_wt_service_names)
                _wt_compreply_from "$worktrees $services" "$cur"
            fi
            ;;
        delete)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-f --force --keep-branch -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        status|st)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "--services --json -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        health|hc)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-t --timeout --json -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        attach|a)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-w --window -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        run)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        exec)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        ports)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-c --check --json -p --project -h --help" "$cur"
            else
                # First positional could be set/clear subcommand or branch
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "set clear $worktrees" "$cur"
            fi
            ;;
        db)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "reset url dump use-remote detach $worktrees" "$cur"
            fi
            ;;
        send|s)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services
                services=$(_wt_service_names)
                _wt_compreply_from "$worktrees $services" "$cur"
            fi
            ;;
        logs|log)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "--lines -n --all -a -p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services
                services=$(_wt_service_names)
                _wt_compreply_from "$worktrees $services" "$cur"
            fi
            ;;
        panes)
            if [[ "$cur" == -* ]]; then
                _wt_compreply_from "-p --project -h --help" "$cur"
            else
                local worktrees
                worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                _wt_compreply_from "$worktrees" "$cur"
            fi
            ;;
        doctor|doc)
            _wt_compreply_from "-p --project --json -h --help" "$cur"
            ;;
        list)
            _wt_compreply_from "-p --project -s --status --json -h --help" "$cur"
            ;;
        init)
            _wt_compreply_from "-n --name -f --force -h --help" "$cur"
            ;;
        config)
            _wt_compreply_from "-e --edit -g --global -p --project --path -h --help" "$cur"
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

complete -F _wt_completions wt
