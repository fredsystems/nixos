---
name: nixos-track-upstream-fix
description: Use ONLY in the fred/nixos flake repo when adding, reverting, or reasoning about a TEMPORARY workaround that exists solely because of an unfixed upstream bug -- a package overlay (`overrideAttrs`, `doCheck = false`, `postPatch`, CFLAGS pins), a `permittedInsecurePackages` entry, a polkit/module workaround, a disabled feature (`*.enable = false`), or a gh-dash/app keybind hack. Covers the `.github/tracked-upstream-fixes.json` manifest, the `check-upstream-fixes.sh` checker, the `track-upstream-fixes.yaml` workflow, choosing the right check type (issue-closed vs release-contains-commit vs pkgs-min-version vs nixpkgs-pin-contains-commit), and the FIXME-comment convention that ties code to a manifest entry.
---

# NixOS: track upstream fixes for temporary workarounds

This repo carries a number of **temporary workarounds** that exist only
because of an unfixed (or unreleased, or not-yet-in-our-pin) upstream
bug. Left untracked, these rot: the upstream fix ships, nobody notices,
and the hack lives forever. This repo has machinery to prevent that.

When you add a workaround that is waiting on an upstream fix, you MUST
register it so the monitoring workflow can flag it for removal once the
fix lands. When you touch an existing workaround, check whether its
manifest entry needs updating.

## The three moving parts

| File                                          | Role                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `.github/tracked-upstream-fixes.json`         | The manifest: one entry per tracked workaround. Source of truth.     |
| `.github/scripts/check-upstream-fixes.sh`     | The checker: evaluates each entry, emits resolved ones as JSON.      |
| `.github/workflows/track-upstream-fixes.yaml` | The workflow: runs the checker weekly, opens/updates a sticky issue. |

Plus a convention: the code carrying the workaround has a
`FIXME(<id>)` comment whose `<id>` matches the manifest entry's `id`,
and the manifest entry's `workaround` field points back at that code.

## When this fires

Adding any of these means you owe a manifest entry:

- A package overlay in `overlays/default.nix` that exists to dodge an
  upstream build/test break (`overrideAttrs`, `doCheck = false`,
  `configureFlags`/CFLAGS pins, `postPatch`, `fetchpatch`).
- A `nixpkgs.config.permittedInsecurePackages` /
  `allowInsecure` / `meta.broken` allowance added because of an
  upstream lag.
- A polkit rule, systemd override, or other NixOS-module-level
  workaround for an upstream module bug.
- A feature switched off (`<thing>.enable = false`) because the build
  or runtime is broken upstream.
- An app-level config hack (e.g. the gh-dash `keybindings` override
  that works around a TUI stderr leak).

NOT trackable (do not add a manifest entry, just a normal comment):

- Intentional, permanent design choices (e.g. a darwin-vs-linux split,
  a deliberate `mkForce`, a Go-vendor override). These have no
  "revert when upstream fixes X" condition.
- Local data placeholders (a TODO email, a naming question).
- Self-resolving channel migrations ("remove when all our hosts are
  > = 26.05") -- these depend on OUR config, not upstream.

If you are unsure whether something is trackable, ask: "is there a
specific upstream issue / PR / release whose landing tells me I can
delete this?" If yes -> trackable. If the trigger is our own config or
taste -> not trackable.

## Choosing the check type

The manifest supports four check types. Pick the one that matches the
HONEST signal for "the fix is installable in a channel we build" --
not merely "the bug report was acknowledged".

| Check type                    | Resolves when ...                                                                       | Use for                                                                                   |
| ----------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `issue-closed`                | the tracked issue's state is `closed`                                                   | weakest signal; fine for "this regression is acknowledged fixed and I'll re-test" cases   |
| `release-contains-commit`     | the upstream repo's LATEST release tag contains `fix_commit`                            | fix merged to a project's `main` but not yet released (the gh-dash case)                  |
| `pkgs-min-version`            | `pkgs.<package>.version` in OUR pinned nixpkgs (eval'd on `eval_host`) >= `min_version` | nix/nixpkgs daemon- or package-level fixes where "installable in our pin" is the real bar |
| `nixpkgs-pin-contains-commit` | `fix_commit` is contained in the nixpkgs rev OUR `flake.lock` pins (`pin_node`)         | NixOS MODULE changes with no single package version to gate on (the fwupd polkit case)    |

Key principle, learned the hard way: **a merged PR or a closed issue
does NOT mean the fix is in a channel you install.** For anything that
must actually ship in our nixpkgs pin before we can revert (daemon
fixes, module fixes), prefer the channel-aware types
(`pkgs-min-version`, `nixpkgs-pin-contains-commit`) over
`issue-closed`. `issue-closed` will flag the moment the report closes,
which can be long before it's installable.

### The "fix is coming but not yet merged" case

For `pkgs-min-version`, set `min_version: null` when you know a fix is
coming but not yet which release carries it. The checker treats a null
target as **BLOCKED** -- it never falsely resolves -- and, if you set
`upstream_pr`, it reports whether that PR has merged yet so you get
nudged to fill in the real version later. This is exactly how
`nix-15638-opencode-darwin` is modeled: PR open, `min_version` null,
entry permanently quiet until you act.

## Procedure: adding a new tracked workaround

1. Write the workaround in the relevant `.nix` (or app config) file.
   Add a `FIXME(<id>)` comment that:
   - states it is a WORKAROUND, not a fix;
   - links the upstream issue/PR;
   - says exactly what to delete and under what condition;
   - points at `.github/workflows/track-upstream-fixes.yaml`.

   Use a stable, descriptive `<id>` like
   `nixpkgs-526476-fwupd-polkit` or `gh-dash-829-browser-stderr`.

2. Add an entry to `.github/tracked-upstream-fixes.json` `fixes[]`:

   ```json
   {
     "id": "<same id as the FIXME>",
     "done": false,
     "summary": "<one line: what breaks and why the hack exists>",
     "repo": "owner/repo",
     "check": "<one of the four types>",
     "<type-specific fields>": "...",
     "tracking": ["https://github.com/owner/repo/issues/NNN"],
     "workaround": "<file:path -- what the hack is, mention the FIXME id>",
     "revert_action": "<exact steps to revert and how to confirm it's safe>"
   }
   ```

   Type-specific fields:
   - `issue-closed`: `issue` (number).
   - `release-contains-commit`: `fix_commit` (full sha).
   - `pkgs-min-version`: `package`, `eval_host` (a nixosConfiguration
     attr on the right channel), `min_version` (or null), optional
     `upstream_pr`.
   - `nixpkgs-pin-contains-commit`: `fix_commit`, `pin_node`
     (`nixpkgs` for unstable, `nixpkgs-stable` for stable -- gate on
     the channel the affected hosts actually use).

3. Validate and dry-run locally:

   ```sh
   jq -e . .github/tracked-upstream-fixes.json >/dev/null
   shellcheck .github/scripts/check-upstream-fixes.sh
   .github/scripts/check-upstream-fixes.sh        # needs gh auth + nix
   ```

   The checker prints per-entry diagnostics to stderr and the resolved
   set as JSON on stdout. Confirm your new entry reports the state you
   expect (usually "not resolved yet"). A `pkgs-min-version` or
   `nixpkgs-pin-contains-commit` check needs Nix available (the
   workflow installs it; locally you already have it).

4. Lint the `.nix` change (`nixfmt`, `statix check`, `deadnix --fail`)
   per `nix-best-practices`, and eval impacted hosts per
   `nixos-eval-impacted-hosts` if you edited host/feature config.

## Procedure: reverting a workaround the workflow flagged

When the sticky tracking issue says an entry resolved:

1. Do the `revert_action` from the manifest entry: delete the
   workaround code AND its `FIXME(<id>)` comment.
2. Verify the revert is actually safe -- build/eval the affected
   hosts (per `nixos-eval-impacted-hosts`), or for a darwin/test hack,
   confirm the previously-failing build now passes.
3. Set the manifest entry's `"done": true` (preferred -- keeps the
   historical record) or remove the entry entirely.
4. Commit per `commit-discipline`.

Do NOT mark `done: true` before the revert is verified green. The
flag mutes the entry; muting an unreverted workaround defeats the
purpose.

## How the checker and workflow behave

- `check-upstream-fixes.sh` skips entries with `"done": true`,
  evaluates the rest, and prints the resolved ones (annotated with an
  `evidence` string) as a JSON array on stdout. Exit code is 0 unless
  the manifest is malformed or an unknown check type is used.
- `track-upstream-fixes.yaml` runs weekly (Sun 06:00, after the flake
  auto-update so a just-landed release is reflected), on
  `workflow_dispatch`, and on pushes that touch the manifest / script /
  workflow. When the checker resolves anything, it opens or **updates a
  single sticky issue** (idempotent via the hidden
  `track-upstream-fixes:sticky` marker) listing what is ready to
  revert. It never spams a new issue per run.

## When to stop and ask

- You're tempted to use `issue-closed` for a daemon/module fix that
  must ship in our pin. Prefer the channel-aware check; surface if you
  think `issue-closed` is genuinely sufficient.
- A workaround has no identifiable upstream signal at all (no issue,
  no PR, no release to wait on). It may not be trackable -- or the
  upstream report needs to be filed first. Surface it.
- You want to add a NEW check type to the script. That's a real
  change to `check-upstream-fixes.sh`; design it so a null/missing
  target is BLOCKED, never falsely resolved, and document it in the
  manifest's `$comment` header.

Base directory for this skill: file:///home/fred/GitHub/nixos/.opencode/skills/projects/nixos-track-upstream-fix
