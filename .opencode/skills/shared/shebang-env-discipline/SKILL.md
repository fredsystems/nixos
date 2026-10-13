---
name: shebang-env-discipline
description: Use whenever creating or editing any file that starts with a shebang (`#!`) line -- shell scripts (`.sh`, `.bash`, `.zsh`), Python (`.py`), Perl, Ruby, Node, `nix-shell` scripts, or any extension-less executable -- in any of fred's repos. Mandates the `#!/usr/bin/env <interpreter>` form and forbids hardcoded interpreter paths such as `#!/bin/bash`, `#!/bin/sh`, `#!/usr/bin/python3`, or `#!/usr/local/bin/node`, which do not exist (or point at the wrong binary) on NixOS and nix-darwin.
---

# Shebangs: always `#!/usr/bin/env <interpreter>`

Every script with a shebang line uses `env` to locate its interpreter
via `PATH`. Hardcoded interpreter paths are forbidden.

```bash
#!/usr/bin/env bash
```

```python
#!/usr/bin/env python3
```

## Why

fred's machines are NixOS and nix-darwin. On NixOS the only paths
guaranteed to exist are `/bin/sh` and `/usr/bin/env`; there is no
`/bin/bash`, no `/usr/bin/python3`, no `/usr/bin/perl`. On macOS,
`/bin/bash` exists but is the ancient 3.2 Apple ships, not the bash
from the flake. Inside a `nix develop` shell, the correct interpreter
is whichever one the dev shell put on `PATH` -- `env` finds it, a
hardcoded path silently bypasses it.

`#!/bin/sh` is still forbidden even though it technically exists on
NixOS: use `#!/usr/bin/env sh` so every script in the repo follows a
single rule and a reviewer never has to reason about which absolute
paths happen to be safe.

## The rule

1. The first line of any script that has a shebang is exactly
   `#!/usr/bin/env <interpreter>`.
2. Name the interpreter you actually require: `bash` (not `sh`) if the
   script uses bash-isms, `python3` (not `python`), `zsh`, `perl`,
   `node`, `ruby`, etc.
3. When editing an existing script that has a non-compliant shebang,
   fix the shebang in the same change. It is a one-line fix and the
   script is already being touched.
4. Do not add a shebang to files that are never executed directly
   (sourced shell fragments, Python modules imported as libraries).

## Forbidden forms

| Wrong                         | Right                        |
| ----------------------------- | ---------------------------- |
| `#!/bin/bash`                 | `#!/usr/bin/env bash`        |
| `#!/bin/sh`                   | `#!/usr/bin/env sh`          |
| `#!/usr/bin/bash`             | `#!/usr/bin/env bash`        |
| `#!/bin/zsh`                  | `#!/usr/bin/env zsh`         |
| `#!/usr/bin/python3`          | `#!/usr/bin/env python3`     |
| `#!/usr/bin/python`           | `#!/usr/bin/env python3`     |
| `#!/usr/local/bin/node`       | `#!/usr/bin/env node`        |
| `#!/usr/bin/perl`             | `#!/usr/bin/env perl`        |
| `#!/run/current-system/sw/..` | `#!/usr/bin/env <name>`      |
| `#!/nix/store/<hash>-bash/..` | `#!/usr/bin/env bash` (file) |

## Interpreter flags

Linux passes everything after the interpreter path as a single
argument, so `#!/usr/bin/env bash -e` does not work. Either:

- set the option in the script body (preferred):

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  ```

- or use `env -S` to split arguments when a flag genuinely must be on
  the shebang line (GNU coreutils 8.30+ and macOS both support it):

  ```text
  #!/usr/bin/env -S python3 -u
  ```

## `nix-shell` scripts

The `nix-shell` interpreter form is compliant as long as the first
line uses `env`. The second `#!nix-shell` line is a directive parsed
by `nix-shell`, not a shebang, and is left as is:

```bash
#!/usr/bin/env nix-shell
#!nix-shell -i bash -p jq curl
```

## Scripts generated inside Nix expressions

This skill governs shebangs written by hand in source files. Scripts
that Nix itself builds follow different, equally strict rules:

- Prefer `pkgs.writeShellApplication` / `pkgs.writeShellScript` /
  `pkgs.writers.writePython3Bin` etc. They emit a correct store-path
  shebang themselves -- do not put a shebang in the text you pass them.
- If you must hand-write a shebang inside a Nix string (e.g. raw
  `pkgs.writeScript`), interpolate the interpreter:
  `#!${pkgs.bash}/bin/bash`. A literal `#!/bin/bash` in a Nix string
  is a bug; so is `#!/usr/bin/env bash` in a script that runs inside
  the build sandbox (where `PATH` is not what you expect).
- Store-path shebangs produced by `patchShebangs` during a package
  build are correct. Never rewrite them, and never commit a file whose
  shebang was copied out of a built store path.

## Verifying

Before committing, list every shebang in changed files and confirm
each starts with `#!/usr/bin/env` followed by the interpreter name:

```bash
git diff --cached --name-only --diff-filter=ACMR \
  | xargs -r rg -H -n --no-heading '^#!' \
  | rg -v 'binary file matches' \
  | rg -v '^[^:]+:1:#!/usr/bin/env ' \
  | rg -v ':2:#!nix-shell '
```

Any output is a violation to fix.

## When to stop and ask

- A third-party file is vendored verbatim (e.g. a script copied from
  upstream and tracked for updates). Changing its shebang creates diff
  noise on every resync; surface it rather than editing.
- A script must run in an environment where `/usr/bin/env` genuinely
  does not exist (some minimal containers, initrd, early-boot
  scripts). That is rare and should be an explicit, commented
  exception, not a silent one.
