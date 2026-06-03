---
name: flake-dev-shell-discipline
description: Use whenever a task in a Nix-flake-managed repository (freminal, docker-acarshub, nixos, or any future flake-managed project) requires a system-level tool — compiler, linker, system library, test runner, CLI utility — that may not already be in the dev shell. Mandates the "add to flake.nix, then STOP and tell the user to run `nix develop` / `direnv allow`, then wait for confirmation" protocol. Forbids working around missing tools by modifying application logic or installing out-of-band.
---

# Nix flake dev shells: add the tool, stop, wait

In any of fred's flake-managed repositories, the dev environment is
fully described by `flake.nix` (and any module it imports). Adding a
required tool is a config change, not a side-channel install.

## The rule

**Adding language-level dependencies** (npm packages, cargo crates,
PyPI packages where the project uses them):

1. Add to the appropriate manifest (`package.json`, `Cargo.toml`, ...).
2. Run the install / lock command (`npm install`, `cargo build`, ...).
3. Continue working.

**Adding system tools** (compilers, system libraries, test runners,
CLI utilities — anything that ends up on `PATH` rather than in a
language-level lockfile):

1. Add to `flake.nix` in the appropriate package list (usually a
   `devShells.default` `packages = [...]`, or an equivalent
   project-local helper module).
2. **STOP.** Tell the user:
   > "Please run `nix develop` or `direnv allow` to pick up the new
   > tool, then let me know when ready."
3. **Wait for the user to confirm** the new shell is active.
4. Continue.

## Why the stop-and-wait

The shell the agent is running in **does not auto-reload** when
`flake.nix` changes. If the agent adds a tool and then immediately
tries to use it, the tool isn't on `PATH` and the agent gets
confused ("but I just added it!"). The right answer is the same as
for any nix-managed dev shell: re-enter it.

The user is the one who controls when their shell re-enters. The
agent does not get to assume.

## What NOT to do

- **Do NOT work around a missing tool by modifying application
  logic.** If the tests need `sqlite3` on `PATH` and it's missing,
  the fix is "add sqlite to `flake.nix`", not "rewrite the tests to
  avoid needing sqlite".
- **Do NOT silently install via `apt` / `brew` / `pip install
--user` / `cargo install --global`**, etc. The dev shell is the
  only sanctioned source of system tools; out-of-band installs
  break reproducibility for everyone else and for CI.
- **Do NOT proceed past step 2 without confirmation.** Even if the
  tool _seems_ available in your shell (because of a stale env),
  CI / other contributors won't have it until the flake commit
  lands.

## When the addition itself needs review

- Large packages (multi-gigabyte downloads, kernel modules,
  cross-arch toolchains) deserve a one-line "I'm about to add X
  which pulls Y MB" before adding.
- Adding a new package set that overlaps with existing ones (e.g.
  another node version, another python interpreter) is usually
  wrong. Stop and confirm the existing one isn't sufficient.
- Adding a tool that already exists under a different name is a
  rename, not an addition. Surface that.

## When to stop and ask

- The tool requirement comes from a transitive dep (e.g. an npm
  package's build script needs `cmake`). That's still a `flake.nix`
  addition, but worth a quick note explaining the chain.
- The tool exists in nixpkgs only in an old version. Check whether
  the project genuinely needs newer; if so, surface and discuss
  (overlay vs unstable-pin vs upstreaming a bump).
- The project also has a project-specific skill (e.g. an
  `acarshub-tool-additions` catalog naming exactly which list to
  append to). Defer to it for the exact mechanical step.
