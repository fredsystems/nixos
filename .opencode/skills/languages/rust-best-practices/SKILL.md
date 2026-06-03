---
name: rust-best-practices
description: Use when editing `.rs` files, running `cargo`, `cargo clippy`, `cargo test`, `cargo xtask`, or before declaring any Rust change complete. Codifies the "lints maxed, no bypasses, no panics in production" Rust policy that applies across every Rust crate in fred's repos.
---

# Rust: lints maxed, no bypasses

The standing policy for **every** Rust crate in fred's projects:

- Clippy is run with `--all-targets --all-features -- -D warnings`. Any
  warning is a failure.
- `unwrap()` and `expect()` are **forbidden in production code** and
  enforced via `#![deny(clippy::unwrap_used, clippy::expect_used)]`.
  Test code (`#[cfg(test)]` modules, files under `tests/`, benches) is
  the only place they are allowed.
- `#[allow(dead_code)]` is forbidden in production modules. Test-only
  helpers and code gated behind an explicit `TODO` comment for a known
  transient refactor are the only acceptable uses.
- Raw `as` casts for **numeric** conversions are forbidden in production.
  Prefer fallible conversions (`TryFrom`/`TryInto`) and crate-specific
  numeric-conversion helpers when the project provides them. `as` is OK
  only for casts the type system guarantees lossless (e.g. `u8 -> u32`),
  and in test/bench code. Project-specific skills may name the exact
  conversion crate or helper to use.
- `anyhow` is OK in binary / orchestration code (e.g. `xtask`) and never
  in library crates. Libraries return domain-specific typed error enums.

If a lint is firing in new code, **fix the code**. Adding `#[allow(...)]`,
`// clippy::allow`, or sprinkling `#[allow(clippy::unwrap_used)]` to
silence the panic-free policy is the wrong move and will be reverted at
review. The only acceptable suppression is a `#[allow(...)]` with a
comment on the next line explaining _why_ the rule is genuinely wrong
for this specific call site.

## Verification ritual (run before reporting done)

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all
cargo machete                # detect unused dependencies
```

If the crate has an `xtask` target, prefer `cargo xtask ci` which wraps
the above plus benchmarks-compile and `cargo deny`.

If any step fails, fix it before reporting. "Existing failures unrelated
to my change" is not a valid reason to ship — either fix them, or stop
and surface the situation with the user before continuing.

## When `unwrap` / `expect` "must" happen in production

It does not. Convert the panic into a typed error:

```rust
// Wrong (production):
let value = map.get(&key).unwrap();

// Right (production):
let value = map.get(&key).ok_or(MyError::MissingKey(key))?;
```

If the invariant _is_ unreachable by construction, encode that in the
type system (e.g. `NonZeroUsize`, a newtype that can only be constructed
through a validating constructor) so the unwrap is structurally
unnecessary, rather than papering over it.

## When to stop and ask

- A clippy lint fires that the codebase clearly cannot satisfy without
  changing behavior (e.g. a new `clippy::pedantic` rule from a toolchain
  bump that disagrees with an existing pattern across hundreds of
  sites). Stop and surface it; do not bulk-suppress.
- The MSRV in `rust-toolchain.toml` / `Cargo.toml`'s `rust-version`
  conflicts with a fix that needs a newer language feature. Stop —
  bumping the MSRV is a user decision.
