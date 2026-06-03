---
name: nix-best-practices
description: Use when editing `.nix` files in any of fred's flake-managed repos (nixos, freminal, docker-acarshub, and downstream). Codifies the active, strict Nix lint stack — `nixfmt` (auto-format), `statix check` (anti-patterns), `deadnix --fail` (unused bindings) — that runs on every `.nix` commit via the `fredsystems/precommit-base` pre-commit ruleset. Lists the common rejections (empty `{ ... }:` patterns, unused `let` / function args, `with` abuse, anti-patterns flagged by statix) and how to write Nix that passes on the first commit. No bypasses, no per-file disables without a real reason.
---

# Nix Best Practices — Lints Are Strict and Active

## The non-negotiable

Every `.nix` file in fred's flake repos is run through three lints on
every commit. They are **enabled, strict, and not optional**:

| Tool    | Command          | What it does on failure                  |
| ------- | ---------------- | ---------------------------------------- |
| nixfmt  | `nixfmt <file>`  | Auto-formats and re-stages.              |
| statix  | `statix check`   | Reports anti-patterns; rejects commit.   |
| deadnix | `deadnix --fail` | Reports unused bindings; rejects commit. |

All three are configured in `fredsystems/precommit-base`
(`checks/base.nix`) and inherited by every flake-managed repo. None
of them accepts a `# noqa` / `# nolint` style escape hatch in source;
disabling a rule means editing the shared `precommit-base`
configuration, which is a deliberate, surface-it-first decision.

There is no `--no-verify`. There is no "just this once". If a hook
fires, fix the underlying Nix.

## nixfmt (auto-format, re-stages)

nixfmt 1.2.x runs with default settings. It is unopinionated about
your logic but very opinionated about whitespace and bracket layout.
It does not reject the commit on the first failure — it rewrites the
file, re-stages it, and then later hooks run against the reformatted
content. That means a "clean" commit attempt can still trigger
follow-up hook failures on the reformatted text, so it pays to write
in nixfmt's preferred style from the start.

Rules of thumb:

- Two-space indentation, no tabs.
- Attribute sets and lists break onto multiple lines when they get
  long — let nixfmt decide where; don't fight it.
- Trailing semicolons on attribute-set bindings.
- One space around `=`, `:`, and `?`.
- Function arguments aligned by nixfmt — don't hand-align.

If you find yourself reformatting after nixfmt, you're losing the
fight. Re-stage and move on.

## statix check (anti-patterns, hard reject)

statix flags Nix anti-patterns. It does not auto-fix in our setup —
it fails the commit and prints the offending location with a rule
ID. Fix the source, don't suppress.

The rejections that bite fred's repos most often:

### Empty function pattern: `{ ... }:` → `_:`

```nix
# Rejected (statix: empty_pattern)
{ ... }: {
  services.foo.enable = true;
}

# Accepted
_: {
  services.foo.enable = true;
}
```

The `{ ... }:` form is only meaningful when you actually destructure
something out of it. If the body uses none of the module arguments,
use `_:`. This bit the `features/ai/opencode/default.nix` rewrite
during the skills work.

### Unquoted URLs

```nix
# Rejected (statix: legacy_let_syntax / unquoted_uri depending on context)
src = https://example.com/file.tar.gz;

# Accepted
src = "https://example.com/file.tar.gz";
```

### `let in` without bindings, or single-use `let` you could inline

statix doesn't reject every single-use `let`, but it will flag
patently dead ones. If statix complains about a `let`, the binding is
either unused (and deadnix will also yell) or pointlessly indirect.

### Manual `if ... then true else false`

```nix
# Rejected (statix: bool_simplification)
enable = if cfg.useFoo then true else false;

# Accepted
enable = cfg.useFoo;
```

### `with` in module scopes

`with pkgs;` and `with lib;` at the top of a module are flagged
(`with` makes name resolution opaque and hides shadowing). Prefer
explicit references or a tight `let` binding:

```nix
# Rejected (statix: with_attr_set in many contexts)
{ pkgs, ... }: with pkgs; {
  environment.systemPackages = [ vim git curl ];
}

# Accepted
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [ vim git curl ];
}
```

The narrow `with pkgs;` directly in front of a list is typically
fine; the module-wide `with` at the top is not.

### Useless parens, useless `inherit`, find-and-replace style

statix will flag `inherit foo;` when `foo` is not in scope, redundant
parens around already-atomic expressions, and similar housekeeping
issues. Just fix them — they're always real.

## deadnix --fail (unused bindings, hard reject)

deadnix is run with `--fail`, so any unused `let` binding, unused
function argument, or unused `inherit` will reject the commit. It
does not auto-fix in this setup.

### Unused function arguments

```nix
# Rejected
{ pkgs, lib, config, ... }: {
  # only uses pkgs
  environment.systemPackages = [ pkgs.vim ];
}

# Accepted
{ pkgs, ... }: {
  environment.systemPackages = [ pkgs.vim ];
}
```

If you genuinely need a future-proof signature (e.g. you're
prototyping and will use `lib` shortly), don't add it speculatively
— add it when you use it.

### Unused `let` bindings

```nix
# Rejected
let
  unused = "value";
  pkg = pkgs.vim;
in
[ pkg ]

# Accepted
let
  pkg = pkgs.vim;
in
[ pkg ]
```

### Underscore-prefix to silence: only when intentional

deadnix respects `_name` (leading underscore) as an explicit
"intentionally unused" marker. Use it sparingly — for arguments
required by an interface but not consumed in this implementation:

```nix
# Acceptable when the signature is dictated by an upstream module
mkConfig = _config: {
  defaults = { /* ... */ };
};
```

Don't use `_` to dodge a real deadnix finding. If the binding is
actually unused, delete it.

## Other Nix hygiene (not lint-enforced, but expected)

- **Pin imports through the flake**, not by URL. New external code
  enters via `flake.nix` inputs, runs through the `# CI:` /
  `nixos-input-category-sync` workflow, and gets cached.
- **No `import <nixpkgs> {}`** — channels are not in scope; everything
  flows from flake inputs.
- **No `builtins.fetchurl` or `builtins.fetchTarball`** in committed
  code — they bypass the lock file and break reproducibility.
- **Module options get types and descriptions.** `mkOption { type =
types.bool; default = false; description = "..."; }` not
  `mkOption { default = false; }`.
- **Use `lib.mkIf` over inline `if ... then ... else { }`** for
  conditional config — it composes properly with the module merge
  algorithm.
- **Use `lib.mkDefault` / `lib.mkForce` deliberately**, not
  reflexively. Default priority is almost always what you want.

## Workflow when a Nix hook fires

1. Read the rule ID and the file:line from the hook output. statix
   and deadnix both give precise locations.
2. Fix the source, never the symptom. Don't add `_` prefixes to make
   deadnix shut up if the binding is genuinely unused; don't add a
   per-file statix disable comment without surfacing why.
3. Re-stage and re-commit. nixfmt may have rewritten the file in the
   meantime — that's expected; `git add` the result.
4. If you're stuck in a loop (statix and nixfmt seem to disagree, or
   deadnix keeps flagging something you swear is used), stop and
   load `precommit-fix-loop`. It is almost always a real bug in the
   source, not a tooling bug.

## When to stop and ask

- A statix rejection seems wrong for the specific case (e.g. a
  `with` is genuinely the cleanest form for a generated module).
  Surface it before adding a per-file disable.
- deadnix flags something you believe is used through a dynamic
  attrset access (`config.${name}` style). Surface — there may be a
  better refactor.
- You want to disable a rule globally. That's a `precommit-base`
  change, not a per-repo change. Surface and discuss before editing
  the upstream config.
- A new Nix lint (`nixpkgs-fmt`, `alejandra`, `nix-linter`) is being
  proposed. fred's stack is nixfmt + statix + deadnix; adding a
  fourth tool needs a deliberate decision, not a drive-by addition.
