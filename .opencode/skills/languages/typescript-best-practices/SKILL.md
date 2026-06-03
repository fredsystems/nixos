---
name: typescript-best-practices
description: Use when editing `.ts` or `.tsx` files, when running `tsc`, `biome`, `eslint`, `vitest`, `playwright`, or `npm`/`pnpm`/`yarn` test/lint commands in any of fred's TypeScript projects. Codifies the strict-mode, no-`any`, no-`@ts-ignore`, explicit-return-types, structured-logger policy.
---

# TypeScript: strict mode, no escape hatches

The standing policy for every TS/TSX file in fred's projects:

## Type discipline

- **`strict: true` in `tsconfig.json`** is required. If the project's
  tsconfig has it off, that's a bug to fix, not a license to skip
  types.
- **No `any`.** Use `unknown` plus a type guard, or define an
  interface. `any` in new code is a review-rejecting finding.
- **No `// @ts-ignore`, no `// @ts-expect-error` without a comment
  explaining exactly why and a linked issue.** If a type error is
  genuinely correct ("the library types are wrong"), the right fix is
  a typed wrapper or a `.d.ts` augmentation, not an ignore.
- **Explicit function return types** on every exported function and
  every non-trivial internal function. Inference is OK only when the
  type is obvious at the call site.
- **Explicit parameter types.** Always.
- **Interfaces for complex objects.** A function that takes 4+
  properties on a parameter object should take a named interface, not
  an inline structural type.
- **Generics where they earn their keep.** Don't make everything
  generic; do reach for generics when a function genuinely operates
  uniformly over multiple types.

Example:

```typescript
// Wrong
function processData(data: any): any {
  return data.value;
}

// Right
interface MessageData {
  uid: string;
  text: string;
  timestamp: number;
}

function processData(data: MessageData): string {
  return data.text;
}
```

## Logging

**Use the project's structured logger, never `console.*`** in
application code. Most of fred's TS projects expose a `createLogger`
or equivalent factory; consult the project's own skills/AGENTS.md for
the exact namespace convention.

General rules:

- `error` — critical failures preventing functionality
- `warn` — potential issues, degraded functionality
- `info` — important state changes, major events
- `debug` — detailed debugging, state transitions
- `trace` — very verbose, high-frequency events

`console.log` / `console.error` are not allowed in shipping code; the
biome / eslint config will flag them.

## Verification ritual

```sh
# Whatever the project's aggregated lint+typecheck+test target is
# (e.g. `just ci`, `npm run check`, `pnpm verify`, ...).
```

Or, when iterating:

```sh
npx biome check .
npx tsc --noEmit
npx vitest run
```

If any step fails, fix it before reporting done. New code that
triggers a biome / eslint rule is a bug in the code — do not add
`// biome-ignore` or `// eslint-disable` to silence it. The only
acceptable suppression is for a genuine false positive, with a
comment on the next line explaining why.

## When to stop and ask

- A library you must use ships untyped or with `any`-laden types.
  Stop — propose either a wrapper module with proper types, or a
  `.d.ts` augmentation. Don't infect the codebase with `any` just to
  use it.
- The type the codebase has for X is genuinely wrong and fixing it
  cascades into many call sites. Surface the cascade size to the
  user before doing a large rewrite.
- A biome / eslint rule is firing on a pattern that looks correct
  for this codebase. The rule might genuinely not fit; that's a
  precommit-base or `biome.json` change, not a per-call-site
  suppression. See `precommit-fix-loop`.
