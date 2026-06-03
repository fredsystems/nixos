---
name: precommit-fix-loop
description: Use when a git commit is rejected by pre-commit hooks, when the user mentions "pre-commit", "lint failed", "hook failed", or before running `git commit` in any of fred's repos that share the fredsystems/precommit-base ruleset (nixos, freminal, docker-acarshub, and downstream projects). Covers diagnosing which hook fired, fixing the underlying issue (never the symptom), and the strict no-bypass policy.
---

# Pre-commit fix loop

All of fred's repos source their pre-commit configuration from
`fredsystems/precommit-base` (pinned via `flake.nix` as the `precommit-base`
input). The hooks are deliberately strict. They are the contract for "this
code is allowed to enter main".

## Non-negotiable rules

- **`git commit --no-verify` is forbidden.** Do not pass `--no-verify`,
  `-n`, or set `HUSKY_SKIP_HOOKS=1` / `PRE_COMMIT_ALLOW_NO_CONFIG=1` /
  any equivalent escape hatch. The only exception is when the user
  explicitly tells you to bypass on a specific commit.
- **Fix the cause, not the symptom.** If a hook fails, the problem is in
  the code (or in a missing dev-shell tool), never in the hook. Do not
  add `# noqa`, `// eslint-disable`, `#[allow(...)]`, `// biome-ignore`,
  `<!-- markdownlint-disable -->`, etc. to silence a rule that fired
  on new code.
- **If a hook genuinely needs to change**, the change goes in
  `fredsystems/precommit-base` via a PR, not in the consuming repo's
  config. Stop and tell the user.
- **A failed commit is not a committed commit.** If a hook rejected the
  commit, fix the issue and create a new commit. Do NOT `git commit
--amend` onto a commit that the hooks already rejected (you'd be
  hiding the failure from history).

## Diagnostic loop

1. Read the hook output top-to-bottom. Pre-commit prints one section per
   hook. Find the first hook that says `Failed` and start there \u2014
   downstream failures are often consequences of the first.
2. Note the hook's `id:` line (e.g. `id: clippy`, `id: biome`,
   `id: nixfmt-rfc-style`, `id: markdownlint`). That tells you which
   tool, which file types, and which config.
3. Reproduce the failure outside the commit context so you can iterate
   fast:
   - `nix develop` (or `direnv allow`) to enter the dev shell so the
     exact tool versions the hook uses are on PATH.
   - Run the hook in isolation: `pre-commit run <hook-id> --files
<paths>` for just the files you changed, or `pre-commit run -a
<hook-id>` if the failure looks repo-wide.
4. Fix the underlying issue.
5. Re-stage (`git add`) and re-run `pre-commit run <hook-id> --files
<paths>` to confirm green before re-attempting the commit.
6. `git commit` again (no flags).

## Common hook failure classes

| Symptom in output                           | Likely hook              | Real cause                                                                                                                                                                  |
| ------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `error: ...clippy::...`                     | clippy                   | Lint violation in `.rs` change. Fix the code; do NOT add `#[allow]`.                                                                                                        |
| `Formatted N files`                         | rustfmt / nixfmt / biome | A formatter rewrote files. Re-stage them and commit again \u2014 this is not a "failure" so much as a "you forgot to format".                                               |
| `error: typos found`                        | typos                    | A real typo, or a project-specific word missing from `typos.toml` / `.dictionary.txt`. Adding to the dictionary is acceptable only for genuine proper nouns / domain terms. |
| `MD0xx ... markdownlint`                    | markdownlint             | A real markdown rule violation. See the rule reference: <https://github.com/DavidAnson/markdownlint/blob/main/doc/Rules.md>.                                                |
| `evaluation warning:` from a nix build      | flake check              | A nixpkgs deprecation surfaced during eval. Update the call site.                                                                                                           |
| `tool not found` / `command not found: <x>` | (any)                    | Dev shell not entered. `nix develop` and retry. Do NOT work around by skipping the hook.                                                                                    |

## When to stop and ask

- The failing rule looks wrong for this codebase (e.g. a new rule from a
  precommit-base bump that doesn't fit the repo). Stop \u2014 the right
  fix is upstream.
- A hook is asking for a tool that isn't in the dev shell. Stop \u2014
  the right fix is either adding the tool to `flake.nix` (then re-enter
  the shell) or removing the hook's requirement.
- Fixing the lint requires meaningfully changing behavior. Stop, surface
  the situation, do not silently rewrite behavior to satisfy a lint.
