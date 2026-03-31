# wt — Git Worktree Manager

A CLI tool for managing git worktrees with tmux integration, automatic port allocation, and smart commands for teams using Linear and GitHub.

## Features

- **Smart create** — `wt new NEX-1500` fetches the Linear issue title and creates a properly named branch + worktree
- **Cross-project listing** — `wt ls` shows all worktrees across all projects with PR status badges
- **Interactive pickers** — `wt open`, `wt rm`, `wt prune` use fzf for fast selection
- **Service management** — start/stop dev servers per worktree with automatic port allocation (no collisions)
- **tmux integration** — each worktree gets its own tmux session with configured panes
- **Setup automation** — env files, dependencies, builds run automatically on worktree creation
- **PR awareness** — see PR status (open, draft, merged) inline with `wt ls` and `wt rm`

## Install

### Prerequisites

**Required:**
- git
- [yq](https://github.com/mikefarah/yq) v4+ (`brew install yq`)
- tmux (`brew install tmux`)

**Optional (for smart commands):**
- [fzf](https://github.com/junegunn/fzf) (`brew install fzf`) — interactive pickers
- [jq](https://github.com/jqlang/jq) (`brew install jq`) — JSON parsing
- [gh](https://cli.github.com/) (`brew install gh`) — PR status

### Setup

```bash
git clone git@github.com:yann-lauwers/tmux-worktree-manager.git ~/.local/share/wt-cli
cd ~/.local/share/wt-cli
./install.sh
```

The installer will:
1. Check dependencies
2. Create a `wt` symlink in `~/bin` (configurable with `--prefix`)
3. Install shell completions (bash/zsh)
4. Create config directories

Restart your shell, then verify:

```bash
wt --version
```

### Uninstall

```bash
rm ~/bin/wt
rm -rf ~/.local/share/wt-cli
rm -rf ~/.config/wt
rm -rf ~/.local/share/wt
```

## Quick Start

```bash
# 1. Initialize a project
cd ~/my-project
wt init

# 2. Edit the generated config
wt config --edit

# 3. Create a worktree
wt new feature/auth          # plain branch
wt new NEX-1500              # from Linear ticket (requires API key)
wt new                       # scratch worktree

# 4. Open it
wt open                      # fzf picker
wt open feature/auth         # direct

# 5. Start services
wt start feature/auth

# 6. When done
wt stop feature/auth --all
wt delete feature/auth
```

## Commands

### Smart Commands

| Command | Description |
|---------|-------------|
| `wt new [ID\|branch]` | Smart create — Linear ticket, plain branch, or scratch |
| `wt open [query]` | Open worktree in cmux/tmux (fzf picker) |
| `wt ls [-q]` | List all worktrees across projects with PR status |
| `wt rm [branch]` | Smart delete with fzf multi-select |
| `wt prune [-y]` | Delete worktrees whose PRs have been merged |
| `wt code [branch]` | Open worktree in editor (fzf picker) |
| `wt pr [branch]` | Open PR in browser for a branch |

### Core Commands

| Command | Description |
|---------|-------------|
| `wt create <branch> --from <base>` | Create a worktree (basic) |
| `wt delete <branch>` | Delete a worktree (basic) |
| `wt list` | List worktrees (single project) |
| `wt start [branch]` | Start services |
| `wt stop <branch> --all` | Stop services |
| `wt status <branch>` | Show worktree status |
| `wt attach <branch>` | Attach to tmux session |
| `wt ports <branch>` | Show port assignments |
| `wt doctor` | Run diagnostic checks |
| `wt init` | Initialize project configuration |
| `wt config [--edit]` | View/edit configuration |

Run `wt <command> --help` for detailed usage of any command.

## Configuration

### Project Config

Each project needs a YAML config at `~/.config/wt/projects/<name>.yaml`. Run `wt init` inside a repo to generate one, then customize it:

```yaml
name: my-app
repo_path: ~/Code/my-app
base_branch: main

ports:
  reserved:
    range: { min: 3100, max: 3139 }
    slots: 10
    services:
      frontend: 0    # slot 0 → 3100, slot 1 → 3102, ...
      backend: 1     # slot 0 → 3101, slot 1 → 3103, ...
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}

setup:
  - name: install-deps
    command: npm install
    working_dir: "."
    on_failure: abort

  - name: copy-env
    command: cp "$PROJECT_REPO_PATH/.env" .env
    working_dir: "."
    on_failure: continue

services:
  - name: frontend
    command: npm run dev -- --port ${PORT_FRONTEND}
    port_key: frontend
    health_check:
      type: tcp
      port: "${PORT_FRONTEND}"
      timeout: 60

  - name: backend
    command: npm run dev:api -- --port ${PORT_BACKEND}
    port_key: backend
    health_check:
      type: tcp
      port: "${PORT_BACKEND}"
      timeout: 60

tmux:
  session: my-app
  layout: services-top
  windows:
    - name: dev
      panes:
        - service: frontend
        - service: backend
        - command: ""
```

### Global Config

Optional settings at `~/.config/wt/config.yaml`:

```yaml
# Editor for 'wt code' (default: $VISUAL > $EDITOR > open)
editor: cursor

# Opener for 'wt open' (default: auto-detect cmux > tmux > cd)
opener: cmux

# Linear API key for 'wt new NEX-xxx'
linear:
  api_key: lin_api_xxxxx
```

The Linear API key can also be set via `WT_LINEAR_API_KEY` environment variable.

## Port Allocation

Each worktree gets a **slot** (0-9 by default). Ports are calculated deterministically:

```
port = range.min + (slot * num_services) + service_offset
```

For example with `range.min: 3100` and 2 services (frontend=0, backend=1):
- Slot 0: frontend=3100, backend=3101
- Slot 1: frontend=3102, backend=3103
- Slot 2: frontend=3104, backend=3105

This means multiple worktrees never collide on ports.

## Hooks

Project configs support lifecycle hooks:

| Hook | When |
|------|------|
| `pre_create` | Before worktree creation |
| `post_create` | After worktree + setup complete |
| `pre_start` | Before services start |
| `post_start` | After services start |
| `post_stop` | After services stop |
| `pre_delete` | Before worktree removal |
| `post_delete` | After worktree removal |

```yaml
hooks:
  post_start: |
    echo "Frontend: http://localhost:${PORT_FRONTEND}"
    echo "Backend:  http://localhost:${PORT_BACKEND}"
```

## Diagnostics

```bash
wt doctor
```

Checks dependencies, config validity, state consistency, tmux health, and port conflicts.

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core):

```bash
brew install bats-core
bats tests/
```

## Compatibility

- macOS (bash 3.2+) and Linux
- No GNU-only flags — uses POSIX-compatible `sed`, `awk`, `tr`
- `yq` is mikefarah v4

## License

MIT
