---
status: accepted
---

# Worktrees live outside the checkout, in a central per-user tree

`worktree_dir` points every project at `~/worktrees/<project>/<branch>` rather than at a
directory inside the checkout. This is deliberate, and it disagrees with this tool's own
fallback — `worktrees_dir()` returns `<repo>/.worktrees` when a project config omits the key,
which is the layout the evidence below argues against. The default is what a reader meets
first, so without this record the override looks like an accident.

## Considered options

**A — inside the checkout**, `<repo>/.worktrees/<branch>`. What Claude Code does by default.
**B — beside the checkouts**, `<product>/.worktrees/<repo>/<branch>`.
**C — a central per-user tree**, `~/worktrees/<repo>/<branch>`. Chosen.

## Why C

**No command run in the checkout can reach it.** Under A, `git clean -dxff` deletes every
worktree and all uncommitted work in them. Measured flag by flag: `-df`, `-dxf` and (with the
directory ignored) `-dff` all leave it intact — `-x` defeats the ignore rule and the second
`-f` defeats git's refusal to touch a nested repository, and together they take the tree.
Ignoring the directory fixes `git status` and `git add .` and does not fix this. Under C,
`git clean`, `git add .`, `git reset --hard` and `rm -rf <product folder>` all leave the
worktrees untouched.

**Every project-rooted tool pays for A.** Measured at 50 worktrees: 3,650 files and 89 MB under
the repo directory against 550 files and 4.8 MB, and `grep -r` at 0.99 s against 0.15 s.
`git status` is unaffected because git does not descend into a nested repository — the cost
lands on indexers, watchers, linters and any Docker build context rooted at the project.

**Editors do not register a nested worktree as its own repository.** VS Code's
`git.repositoryScanMaxDepth` defaults to 1, and `<repo>/.worktrees/x` is two levels down, so its
files are treated as belonging to the parent. JetBrains states the same conclusion outright and
calls it broken integration. Neither vendor documents a recommended location.

**One backup-exclusion rule covers the whole class.** `~/worktrees` is a single path for
`tmutil addexclusion` or an Arq rule. A and B need one rule per repo or per product folder,
re-added whenever a repo is added.

## Consequences

**C is the worst of the three on relocatability, and this is the cost we accept.** With
`worktree.useRelativePaths=true`, the stored link names three ancestors, and every name in it is
a rename that breaks it. Measured over six relocations: A survives 6, B survives 4, C survives 1
— only a rename of `$HOME`. Renaming the repo directory, its parent folder, or `~/Code` breaks
every worktree of that project, and a cross-volume move resolves to a plausible wrong path rather
than failing loudly.

That breakage is one-directional and quiet: `git worktree list` keeps listing the worktree from
the repo side while `git status` inside it answers `fatal: not a git repository`. Recovery is one
command per worktree — `git -C <repo> worktree repair <path>` — and `wt doctor` reports the
condition under **Worktree Links**. The destruction and traversal costs above are not recoverable
and are paid continuously; this one is recoverable and paid only when something moves.

**Navigation is solved with a symlink, not by moving the worktrees.** A link from the product
folder into the central tree gives `cd <product>/worktrees/<repo>/<branch>` while every traversal
tool ignores it: `grep -r` and `find` do not follow it, `du` reports the link, and removing a
symlink never follows it — so no `clean` or `rm` can reach the worktrees through it.

**Migration between all three layouts is one command per worktree.** `git worktree move` rewrites
both pointers and converts the relative path to the new geometry, so this decision is reversible
if the trade-off is ever judged differently.
