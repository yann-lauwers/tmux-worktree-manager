# wt Configuration Reference

This document provides a complete reference for the YAML configuration files used by `wt`.

## Table of Contents

- [File Locations](#file-locations)
- [Configuration Schema](#configuration-schema)
  - [Basic Settings](#basic-settings)
  - [Port Configuration](#port-configuration)
  - [Environment Variables](#environment-variables)
  - [Setup Steps](#setup-steps)
  - [Services](#services)
  - [tmux Configuration](#tmux-configuration)
  - [Hooks](#hooks)
- [Variable Substitution](#variable-substitution)
- [Complete Example](#complete-example)

---

## File Locations

```
~/.config/wt/
├── config.yaml              # Global defaults (optional)
└── projects/
    └── <project-name>.yaml  # Per-project configuration

~/.local/share/wt/
└── state/
    ├── slots.yaml           # Port slot assignments (auto-managed)
    └── <project>.state.yaml # Runtime state (auto-managed)
```

---

## Configuration Schema

### Basic Settings

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Project identifier (used in tmux session names) |
| `repo_path` | string | Yes | Path to the main git repository (supports `~`) |
| `worktree_dir` | string | No | Where this project's worktrees live (supports `~`). Omitted → `<repo_path>/.worktrees/`, which nests them inside the checkout. See **Where worktrees should live** below. |
| `base_branch` | string | No | Branch new worktrees are cut from. Omitted → the repo's current HEAD. |
| `linear_prefix` | string | No | Issue-tracker prefix, so `wt create 1234` resolves to a `<prefix>-1234` branch. |

```yaml
name: my-project
repo_path: ~/code/my-project
worktree_dir: ~/worktrees/my-project
base_branch: main
```

### Where worktrees should live

**Set `worktree_dir` to a path outside the checkout.** The default when it is
omitted — `<repo_path>/.worktrees/` — nests every worktree inside the main
working tree, and that carries costs no configuration removes:

- `git clean -dxff` deletes every nested worktree **and all uncommitted work in
  them**. `.gitignore` does not protect against this; `-x` is what overrides the
  ignore, and the second `-f` is what overrides git's refusal to touch a nested
  repository.
- Without a `.gitignore` entry, `git add .` stages the worktree as a gitlink. It
  warns and exits 0 rather than refusing.
- Editors index it twice. VS Code's file watcher does not read `.gitignore`
  ([microsoft/vscode#102829](https://github.com/microsoft/vscode/issues/102829),
  closed as by-design), so a nested worktree is watched and searched as part of
  the parent unless `files.watcherExclude` is set separately. JetBrains states it
  outright: *"it is not recommended to create a worktree inside the directory of
  your current project… IntelliJ IDEA misidentifies such projects as multi-root
  projects, which breaks the worktree integration."*

A central tree per project (`~/worktrees/<project>/<branch>`) is what this repo's
own configs use, and matches what `gwq` and Cursor default to.

### Worktree links and moving trees

`wt create` sets `worktree.useRelativePaths=true` on the repo, so both sides of
every worktree link are relative and a move preserving the geometry between the
two trees survives.

Worktrees created before this, or created with raw `git worktree add`, link
absolutely and break on any rename of either tree — one-directionally, which is
what makes it worth checking rather than noticing: `git worktree list` keeps
listing the worktree from the repo side while `git status` inside it answers
`fatal: not a git repository`.

`wt doctor` reports this under **Worktree Links**. To repair an existing one:

```bash
git -C <repo_path> config worktree.useRelativePaths true
git -C <repo_path> worktree repair <worktree_path>
```

Requires git 2.48+. Setting it implies `extensions.relativeWorktrees`, which
makes older git refuse the repository.

---

### Port Configuration

The `ports` section defines how ports are allocated to services across worktrees.

#### Reserved Ports

For services requiring specific ports (OAuth callbacks, Privy integration, etc.), use reserved ports. Each worktree claims a "slot" that maps to a set of ports.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ports.reserved.range.min` | integer | `3000` | Start of reserved port range |
| `ports.reserved.range.max` | integer | `3005` | End of reserved port range |
| `ports.reserved.slots` | integer | `3` | Maximum concurrent worktrees using reserved ports |
| `ports.reserved.services` | object | `{}` | Service name to offset mapping |

**How slot allocation works:**

Each worktree claims a slot (0, 1, 2, ...). The port for a service is calculated as:

```
port = range.min + (slot * services_per_slot) + service_offset
```

Example with `min: 3000`, `slots: 3`, and 2 services:

| Slot | Service (offset 0) | Service (offset 1) |
|------|--------------------|--------------------|
| 0 | 3000 | 3001 |
| 1 | 3002 | 3003 |
| 2 | 3004 | 3005 |

```yaml
ports:
  reserved:
    range: { min: 3000, max: 3007 }
    slots: 4
    services:
      frontend: 0      # Gets port 3000, 3002, 3004, or 3006
      admin-panel: 1   # Gets port 3001, 3003, 3005, or 3007
```

#### Dynamic Ports

For services that don't require specific ports, use dynamic allocation. Ports are determined by hashing the branch name, ensuring the same branch always gets the same port.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ports.dynamic.range.min` | integer | `4000` | Start of dynamic port range |
| `ports.dynamic.range.max` | integer | `5000` | End of dynamic port range |
| `ports.dynamic.services` | object | `{}` | Service names to enable dynamic ports |

```yaml
ports:
  dynamic:
    range: { min: 4000, max: 5000 }
    services:
      api-server: true    # Hash-based port assignment
      background-worker: true
```

---

### Environment Variables

Global environment variables exported for all commands (setup steps, services, hooks).

| Field | Type | Description |
|-------|------|-------------|
| `env` | object | Key-value pairs of environment variables |

Variables support substitution (see [Variable Substitution](#variable-substitution)).

```yaml
env:
  NODE_ENV: development
  NEXT_TELEMETRY_DISABLED: "1"
  DATABASE_URL: "postgres://localhost:5432/${BRANCH_NAME}"
```

---

### Setup Steps

The `setup` section defines steps executed during `wt create`. Steps run sequentially with dependency resolution.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | - | Unique identifier for the step |
| `description` | string | No | `name` | Human-readable description |
| `command` | string | Yes | - | Shell command(s) to execute |
| `working_dir` | string | No | `.` | Directory relative to worktree root |
| `depends_on` | array | No | `[]` | List of step names that must complete first |
| `on_failure` | string | No | `abort` | Action on failure: `abort`, `continue`, or `retry` |
| `condition` | string | No | - | Shell condition; step skipped if exits non-zero |
| `always` | bool | No | `false` | Step runs even under `--no-setup`; `--skip-groups` still applies |
| `env` | object | No | `{}` | Step-specific environment variables |

#### on_failure Options

| Value | Behavior |
|-------|----------|
| `abort` | Stop setup immediately, mark as failed |
| `continue` | Log warning, continue with next step |
| `retry` | Retry once, abort if retry fails |

```yaml
setup:
  - name: init-submodules
    description: "Initialize git submodules"
    command: git submodule update --init --recursive
    working_dir: "."
    on_failure: abort

  - name: install-deps
    description: "Install Node.js dependencies"
    command: npm install
    working_dir: "."
    depends_on: [init-submodules]
    on_failure: continue

  - name: install-optional
    description: "Install optional tools"
    command: npm install -g some-tool
    condition: "[ -f .use-some-tool ]"
    on_failure: continue

  - name: setup-env
    description: "Configure environment"
    command: |
      cp .env.example .env
      sed -i '' "s/PORT=.*/PORT=${PORT}/" .env
    working_dir: backend
    depends_on: [install-deps]
    env:
      SKIP_VALIDATION: "true"
```

---

### Services

The `services` section defines processes managed by `wt start` and `wt stop`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | - | Unique service identifier |
| `description` | string | No | - | Human-readable description |
| `command` | string | Yes | - | Command to start the service |
| `working_dir` | string | No | `.` | Directory relative to worktree root |
| `port_key` | string | No | - | Key in `ports.reserved.services` or `ports.dynamic.services` |
| `env` | object | No | `{}` | Service-specific environment variables |
| `pre_start` | array | No | `[]` | Commands to run before starting (in service's working_dir) |
| `health_check` | object | No | - | Health check configuration |

#### Health Check Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | - | Check type: `tcp` or `http` |
| `port` | string | - | Port to check (supports variable substitution) |
| `url` | string | - | URL for HTTP checks (supports variable substitution) |
| `timeout` | integer | `30` | Maximum seconds to wait for healthy status |
| `interval` | integer | `2` | Seconds between check attempts |

```yaml
services:
  - name: api-server
    description: "Backend API server"
    command: npm run dev
    working_dir: backend
    port_key: api-server
    env:
      PORT: "${PORT}"
      DATABASE_URL: "postgres://localhost:5432/mydb"
    pre_start:
      - "docker start postgres redis 2>/dev/null || true"
      - "npx prisma migrate dev"
    health_check:
      type: http
      url: "http://localhost:${PORT}/health"
      timeout: 60
      interval: 2

  - name: frontend
    description: "React frontend"
    command: npm run dev
    working_dir: frontend
    port_key: frontend
    env:
      PORT: "${PORT}"
      REACT_APP_API_URL: "http://localhost:${PORT_API_SERVER}"
    health_check:
      type: tcp
      port: "${PORT}"
      timeout: 45
```

---

### tmux Configuration

The `tmux` section defines how tmux windows and panes are created for each worktree.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tmux.session` | string | `karma` | tmux session name (shared across worktrees) |
| `tmux.layout` | string | `tiled` | Layout algorithm (see below) |
| `tmux.windows` | array | `[]` | Window configurations |

#### Layout Options

| Value | Description |
|-------|-------------|
| `tiled` | Standard tmux tiled layout |
| `even-horizontal` | Equal-width horizontal panes |
| `even-vertical` | Equal-height vertical panes |
| `main-horizontal` | Large pane on top, others below |
| `main-vertical` | Large pane on left, others right |
| `services-top` | **Custom**: 3 services on top row (35%), 2 command panes on bottom (65%) |
| `services-top-2` | **Custom**: 2 services on top row (35%), 2 command panes on bottom (65%) |

#### services-top Layout

The `services-top` layout creates a specific arrangement for development workflows:

```
+----------+----------+----------+
| service1 | service2 | service3 |  <- 35% height (service panes)
+----------+----------+----------+
|     main (80%)      |  aux(20%)|  <- 65% height (command panes)
+---------------------+----------+
```

#### services-top-2 Layout

The `services-top-2` layout is a variant for 2-service workflows:

```
+----------+----------+
| svc1 50% | svc2 50% |  <- 35% height (service panes)
+----------+----------+
| main 65% | aux  35% |  <- 65% height (command panes)
+----------+----------+
```

4 panes total: 2 service panes (top row), 2 command panes (bottom row).

#### Window Configuration

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Window name |
| `panes` | array | Pane configurations |

#### Pane Configuration

Each pane can be either a service pane or a command pane:

**Service Pane** - Links to a defined service:

| Field | Type | Description |
|-------|------|-------------|
| `service` | string | Name of service from `services` section |

**Command Pane** - Runs an arbitrary command:

| Field | Type | Description |
|-------|------|-------------|
| `command` | string | Command to run (empty string for shell) |
| `working_dir` | string | Directory relative to worktree root |

```yaml
tmux:
  session: myproject  # Optional: defaults to 'karma'
  layout: services-top
  windows:
    - name: dev
      panes:
        # Service panes (top row with services-top layout)
        - service: api-server
        - service: frontend
        - service: worker

        # Command panes (bottom row with services-top layout)
        - command: claude           # Run claude CLI
        - command: ""               # Empty shell for orchestration
```

**Note on pane ordering with `services-top`:**
- Panes 0-2 (or however many services): Top row, left to right
- Remaining panes: Bottom row, left to right
- tmux renumbers panes by visual position (left-to-right, top-to-bottom)

---

### Hooks

The `hooks` section defines scripts run at specific lifecycle events.

| Hook | Trigger | Available Variables |
|------|---------|---------------------|
| `pre_create` | Before worktree creation (after config validation) | `BRANCH_NAME` |
| `post_create` | After worktree creation and setup | `BRANCH_NAME`, `WORKTREE_PATH`, `PORT_*` |
| `pre_start` | Before services are started | `BRANCH_NAME`, `WORKTREE_PATH`, `PORT_*` |
| `post_start` | After all services started | `BRANCH_NAME`, `WORKTREE_PATH`, `PORT_*` |
| `post_stop` | After services are stopped | `BRANCH_NAME` |
| `pre_delete` | Before worktree deletion | `BRANCH_NAME`, `WORKTREE_PATH` |
| `post_delete` | After worktree deletion | `BRANCH_NAME`, `WORKTREE_PATH` |

Hooks have access to all environment variables including:
- `BRANCH_NAME` - Current branch/worktree name
- `WORKTREE_PATH` - Path to the worktree directory
- `PORT_*` - All exported port variables (when available)

If a hook exits with a non-zero status, a warning is logged but execution continues.

```yaml
hooks:
  pre_create: |
    echo "Creating worktree for ${BRANCH_NAME}..."

  post_create: |
    echo ""
    echo "Worktree ready!"
    echo "Ports: API=${PORT_API_SERVER}, Frontend=${PORT_FRONTEND}"

  pre_start: |
    docker start postgres redis 2>/dev/null || true

  post_start: |
    echo ""
    echo "All services running for ${BRANCH_NAME}"
    echo "  API: http://localhost:${PORT_API_SERVER}"
    echo "  App: http://localhost:${PORT_FRONTEND}"

  post_stop: |
    echo "Services stopped for ${BRANCH_NAME}"

  pre_delete: |
    echo "Cleaning up ${BRANCH_NAME}..."
    docker-compose down 2>/dev/null || true

  post_delete: |
    echo "Worktree deleted for ${BRANCH_NAME}"
```

---

## Variable Substitution

The following variables are available in `env`, `command`, `pre_start`, and hook scripts:

### Port Variables

| Variable | Description |
|----------|-------------|
| `${PORT}` | Port for current service (in service context) |
| `${PORT_<SERVICE>}` | Port for any service (uppercase, dashes to underscores) |

Examples:
- Service `api-server` → `${PORT_API_SERVER}`
- Service `gap-app-v2` → `${PORT_GAP_APP_V2}`

### Context Variables

| Variable | Description |
|----------|-------------|
| `${BRANCH_NAME}` | Current worktree branch name |

### Environment Variables

All variables from the `env` section and system environment are available.

---

## Complete Example

```yaml
# ~/.config/wt/projects/my-fullstack-app.yaml

name: my-fullstack-app
repo_path: ~/code/my-fullstack-app

# Port allocation strategy
ports:
  reserved:
    range: { min: 3000, max: 3005 }
    slots: 3
    services:
      frontend: 0
      admin: 1
  dynamic:
    range: { min: 4000, max: 4500 }
    services:
      api: true
      worker: true

# Global environment
env:
  NODE_ENV: development
  LOG_LEVEL: debug

# Setup automation
setup:
  - name: install-deps
    description: "Install all dependencies"
    command: npm install
    working_dir: "."
    on_failure: abort

  - name: setup-database
    description: "Initialize database"
    command: |
      docker-compose up -d postgres
      npm run db:migrate
    working_dir: "."
    depends_on: [install-deps]
    on_failure: abort

  - name: setup-env
    description: "Configure environment files"
    command: |
      cp .env.example .env
      echo "PORT=${PORT_API}" >> .env
      echo "FRONTEND_URL=http://localhost:${PORT_FRONTEND}" >> .env
    working_dir: "."
    depends_on: [install-deps]

# Service definitions
services:
  - name: api
    description: "Backend API"
    command: npm run dev:api
    working_dir: packages/api
    port_key: api
    pre_start:
      - "docker start postgres redis || true"
    env:
      PORT: "${PORT}"
    health_check:
      type: http
      url: "http://localhost:${PORT}/health"
      timeout: 60

  - name: frontend
    description: "React frontend"
    command: npm run dev:frontend
    working_dir: packages/frontend
    port_key: frontend
    env:
      PORT: "${PORT}"
      REACT_APP_API_URL: "http://localhost:${PORT_API}"
    health_check:
      type: tcp
      port: "${PORT}"
      timeout: 45

  - name: worker
    description: "Background job processor"
    command: npm run dev:worker
    working_dir: packages/worker
    port_key: worker
    env:
      PORT: "${PORT}"

# tmux layout
tmux:
  layout: services-top
  windows:
    - name: dev
      panes:
        - service: api
        - service: frontend
        - service: worker
        - command: claude
        - command: ""

# Lifecycle hooks
hooks:
  post_create: |
    echo ""
    echo "Worktree created successfully!"
    echo "Run 'wt start ${BRANCH_NAME} --all' to start services"

  post_start: |
    echo ""
    echo "Services running:"
    echo "  API:      http://localhost:${PORT_API}"
    echo "  Frontend: http://localhost:${PORT_FRONTEND}"
```

---

## Tmux Integration Commands

In addition to `wt start` and `wt attach`, these commands interact with tmux panes:

### wt send

Send a command to a specific pane by service name or pane index:

```bash
wt send feature/auth api-server "npm restart"
wt send feature/auth 0 "ls -la"          # by pane index

# Inside a worktree, branch is auto-detected:
wt send api-server "echo hello"
```

### wt logs

Capture and display output from tmux panes:

```bash
wt logs feature/auth api-server            # specific service
wt logs feature/auth --all                  # all panes
wt logs feature/auth api-server --lines 100 # last 100 lines
```

### wt panes

List panes with service mapping, active status, and dimensions:

```bash
wt panes feature/auth
```

Output:

```
PANE   SERVICE/COMMAND      ACTIVE   SIZE
------------------------------------------------------
0      api-server           no       66x16
1      frontend             no       66x16
2      worker               no       66x16
3      claude               yes      133x32
4      bash                 no       33x32
```

### wt doctor

Run diagnostic checks on your project setup:

```bash
wt doctor
wt doctor -p myproject
```

Checks performed:
1. **Dependencies** - git, yq, tmux, envsubst (with versions)
2. **Project config** - YAML syntax, required fields, port ranges, service references
3. **State consistency** - orphaned worktree entries, stale service PIDs
4. **Tmux health** - session exists, windows match state
5. **Port conflicts** - reserved/dynamic overlap, duplicate assignments

---

## Tips

1. **Port conflicts**: Use `wt ports <branch> --check` to verify ports before starting
2. **Re-run setup**: Use `wt run <branch> <step-name>` to re-run a specific setup step
3. **Skip setup**: Use `wt create <branch> --no-setup` to create without running setup —
   except steps marked `always: true`, which run regardless (see the setup-step fields above)
4. **Debug**: Set `WT_DEBUG=1` for verbose logging
5. **Submodules**: a setup command reaching back to the main checkout must derive the path rather than assume a depth — the worktree sits wherever `worktree_dir` puts it, which is usually not `<repo>/.worktrees/<branch>/`. Use `git rev-parse --git-common-dir` and take its parent.
6. **Diagnose issues**: Run `wt doctor` to check config validity, state consistency, and tmux health
7. **Debug panes**: Use `wt logs <branch> --all` to see output from all tmux panes at once
