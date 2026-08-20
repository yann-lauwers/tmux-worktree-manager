<role>The safety contract for the wt worktree-CLI in this directory — a direction and scope-reminder so the next edit fixes what's asked without silently widening what gets deleted or forced. This is the guardrail; the per-command and per-lib comments are the behavioral spec.</role>

<context>
**Mission.** wt manages git worktrees across projects — create and delete them with tmux windows, port slots, an optional ephemeral Postgres, and Cloudflare tunnels wired through per-project hooks. Deletion is broadly destructive: one `wt delete` drops the checkout, the branch, the ephemeral DB, and the tunnel together, and several paths do it force-by-default.
</context>

## Hard invariants

<context>
The guarantees an edit must preserve. Invariants 1–3 hold on the direct `wt delete <branch>` path and are the tool's real protection for uncommitted work; this list is the reminder so a change doesn't quietly drop one.
</context>

<constraints>
1. **Direct delete confirms.** `wt delete <branch>` prompts before it removes anything; only `-f` / `--force` skips the prompt.
2. **Non-force removal honors git's guards.** Without `--force`, `git worktree remove` refuses a dirty or untracked tree, and branch deletion uses `-d` (an unmerged branch is kept with a warning). The uncommitted work survives the refusal.
3. **`--force` is the explicit opt-in.** It drops both guards at once — the dirty-tree refusal and the unmerged-branch check (`-d` becomes `-D`). One flag discards uncommitted work and an unmerged branch together, so it stays behind an explicit user request.
</constraints>

<context>
**Why the guards default to refusing (2–3):** a worktree may hold the user's only copy of uncommitted or unpushed work, and its removal is unrecoverable. The safe path is to refuse and surface the dirty state rather than discard on a guess.
</context>

## Known sharp edges

<context>
Current behavior that is destructive by construction, not a guarantee. The tests pin these as-is; the fixes are tracked as proposals, not applied here. An edit in this area must not deepen either window.

- **The bulk paths are force-by-default.** The interactive picker (`wt rm` / `wt delete` with no branch) and `wt prune -y` route through `_delete_batch → cmd_delete … -f`, so they force-remove even a dirty worktree — the uncommitted state is only *labelled* `⚠N uncommitted`, never refused. Invariant 2 does not hold here; this is the tool's riskiest surface.
- **Teardown runs before the removal guard.** `pre_delete` hooks (ephemeral-DB wipe, tunnel destroy, per-project profile delete) fire before `git worktree remove`. On a non-force refusal the checkout survives but its DB, tunnel, and profile are already gone — an irreversible partial teardown on the path that "safely" refused.
</context>

## Glossary — the load-bearing terms

<context>
Confusing these is how an edit turns a scoped fix into a wider deletion. `--force` and the bulk paths discard uncommitted work; the direct path guards it.
</context>

| Term | Meaning | Destructive? |
|---|---|---|
| **worktree** | a linked git checkout under `.worktrees/<dir>`, one branch per directory | the target of every delete |
| **slot** | a per-worktree port allocation (`FRONTEND_PORT` / `BACKEND_PORT`), released on delete | released, not destructive |
| **ephemeral DB** | an isolated Postgres data dir wiped by `wt db reset` / `use-remote` / the `pre_delete` hook (`pg_ctl stop` + `rm -rf`) | **yes** — data dir removed |
| **tunnel** | a Cloudflare named tunnel torn down by a `pre_delete` hook | destroyed on delete |
| **`pre_delete` / `post_delete` hook** | project-config commands run around removal; `pre_delete` fires **before** `git worktree remove` | runs teardown early |
| **`cmd_delete`** | the single delete entry point; `-f` skips the confirm and forces `git worktree remove --force` | **yes** under `-f` |
| **`_delete_batch`** | the picker/prune executor — calls `cmd_delete … -f` per entry, then a raw `git worktree remove --force` + `git branch -D` fallback | **yes** — force-by-default |
| **dirty label** | the `⚠N uncommitted` marker in the picker — a display hint only, not a refusal | never blocks a delete |

## Before editing

<constraints>
1. Read this file and the doc-comment directly above the function you're changing (plus the file header) — the comments carry the behavioral detail this file omits.
2. Run the whole suite before and after: `bats tests/` (needs `bats-core`; per `CONTRIBUTING.md`). Green is the ship gate. The destructive-path pins live in `tests/test_zz_delete_safety.bats` — run them directly (`bats tests/test_zz_delete_safety.bats`) when touching delete/prune.
3. Widening what gets deleted or forced lands together with a bats test pinning the new boundary — the boundary is only as safe as its test.
4. A guard that looks wrong gets surfaced to the user, not routed around — correct it with a test, don't bypass it.
5. Behavior stays as-is unless the user asked to change it: the sharp edges above are pinned by tests, and their fixes are proposals, not edits to slip in alongside an unrelated change.
</constraints>

## Traps this repo has already paid for

<context>
Each of these cost a session. None is deducible from the source: the code reads as
correct, the suite stays green, and the failure surfaces somewhere else.
</context>

<constraints>
**`tmux` answers "accepted" and "alive" the same way, and both are exit 0.** A window
created with `-c` pointing at a directory that does not exist runs in `$HOME` instead,
reporting success; a window whose command exits at once is reaped, also reporting
success. A caller that treats exit 0 as "a process is running where I asked" is wrong
twice. Check the directory before, and the window after.

**The bats suite mocks `tmux`, so a green suite proves the mock agrees with itself.**
A mock returning 0 satisfies both readings above. Anything whose correctness depends on
what tmux actually did needs a case against the real binary — `tests/test_lane.bats`
carries three, on a private socket (`-L`) so they never touch a live server.

**Command files are `bash`, and one construct silently differs under `zsh`.** The
single-quote escape `${var//\'/\'\\\'\'}` yields the correct `'\''` in bash and
garbage in zsh. Sourcing a command file into an interactive zsh to try a function
produces wrong output with no error. Test through `bash -c`.

**`sanitize_branch_name` is lossy in two ways that collide silently.** It deletes every
character outside `[a-zA-Z0-9_-]` rather than replacing it, so `feature/some thing` and
`feature/something` produce one name, and accented text is stripped byte by byte —
`été` becomes `t`. Anything deriving an identifier from a branch inherits both.

**`wt logs` and `wt panes` address the worktree's service window only.** Both resolve
through `get_session_name`, which is `worktree_dirname` — so they read the window `wt
start` created and no other. On a worktree that never started services they exit with
`die`, naming a window the caller never asked about.

**`scripts/gen-docs.sh` and `COMMANDS.md` do not exist on `main`.** They live on the
unmerged branch `refactor/resolve-command-context`. The doc-comment convention below is
still the rule; its regeneration step cannot run here until that branch lands.
</constraints>

## Doc-comment convention

<context>
Every function carries a doc-comment directly above its definition, so the source reads as the CLI's own reference. The first line is the function's one-line purpose and becomes its entry in the generated `COMMANDS.md`; the tiers below carry the args and effects a caller needs.
</context>

<constraints>
1. Every function — a `cmd_*`, a lib helper, a private `_helper`, a `show_*_help` — has a contiguous comment block directly above `name() {` (no blank line between comment and function), shaped:
   - `# <one-line imperative purpose>` — required for every function.
   - `# Args: $1 x, $2 y` — when it reads positional arguments.
   - `# Out: <stdout the caller captures>` — when it returns a value on stdout (the `log_*` helpers write to stderr, so that is not `Out`).
   - `# Side: <files/state written, vars exported, git/tmux/db ops, dies>` — when it has side effects.
   A tiny pure helper takes the purpose line alone.
2. Add or refine the doc-comment in the same edit that adds or changes the function — the comment is part of the function, not a follow-up.
3. `COMMANDS.md` is generated from these comments (`scripts/gen-docs.sh --write`) — regenerate it after any purpose or signature change; never hand-edit it.
</constraints>

<context>
**Why generated, not hand-kept:** the doc-comment is the single source of truth. `scripts/gen-docs.sh --check` — run by `tests/test_docs.bats` and CI — fails when `COMMANDS.md` drifts from the source, so the index cannot silently fall out of date.
</context>

<scope_boundary>
This file governs the wt runtime scripts in this directory (`wt.sh`, `commands/*.sh`, `lib/*.sh`, `completions/`, and `tests/`). It does not govern per-project hook configs under `~/.config/wt/projects/*.yaml` (a project whose hook wipes an ephemeral database carries its own contract), nor the shells and tools wt drives (git, tmux, fzf, cloudflared, Postgres).
</scope_boundary>
