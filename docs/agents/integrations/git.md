---
tool: git
role: vcs
defaults:
  pr_draft: false
  merge_actor: agent
---
# Git defaults — wt

<role>Deltas from the `git` floor (`~/.agents/docs/integrations/git.md`) for this repo. Keys absent here keep the floor's values.</role>

<context>
Single-author repository: the pull request stores the change and gives CI its run on both platforms, and the author is the only reviewer. A PR therefore opens ready and the run merges it itself once the machine loop is clean. `base_branch` stays `auto`, which derives `main`.
</context>

## Commit scopes

<context>
Common scopes in this repo (illustrative, not an allowlist): `delete`, `create`, `ci`. Refresh from the log: `git log --oneline -200 --pretty=%s | grep -oE '\(([a-z0-9/-]+)\)' | sort | uniq -c | sort -rn`.
</context>
