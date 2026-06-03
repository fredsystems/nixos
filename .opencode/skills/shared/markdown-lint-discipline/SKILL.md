---
name: markdown-lint-discipline
description: Use whenever writing or editing any `.md` / `.mdx` / `.markdown` file (AGENTS.md, agents.md, README.md, agent-docs/*.md, SKILL.md frontmatter bodies, RFCs, design docs, anything). Codifies the markdownlint rules that bite fred's repos most often (MD031, MD040, MD024, MD058, MD012, MD041), the table-column-width rule, the no-emoji-in-tables rule, and the pre-commit fix loop. Prevents the common "pre-commit rejected your commit because of trailing whitespace / missing language tag / unbalanced table" round trip.
---

# Markdown: lint-clean on the first try

Every one of fred's repos runs a strict markdownlint pre-commit hook
(usually via `fredsystems/precommit-base` + prettier). Most lint
failures are mechanical and predictable. This skill lists the rules
that bite most often and the small habits that avoid them.

If a commit gets rejected by the markdown lint anyway, jump to
`precommit-fix-loop`. This skill is about not getting rejected in
the first place.

## The rules that bite

### MD040 — fenced code blocks must declare a language

Every fenced code block needs a language identifier. Use `text` (or
`plain`) for output that has no language.

````text
Wrong:

​```
some output
​```

Right:

​```text
some output
​```
````

Common languages used in these repos: `bash`, `sh`, `zsh`, `nix`,
`rust`, `toml`, `typescript`, `tsx`, `json`, `jsonc`, `yaml`,
`scss`, `markdown`, `text`, `diff`.

### MD031 — blank lines around fenced code blocks

A fenced block needs a blank line above AND below it. Same for
lists (MD032) and headings (MD022).

````text
Wrong:

Here's the command:
​```sh
do-the-thing
​```
And then ...

Right:

Here's the command:

​```sh
do-the-thing
​```

And then ...
````

### MD058 — blank lines around tables

A table needs a blank line above and below. Same shape as MD031.

### MD024 — no duplicate heading content

Two headings with identical text break anchor links and trip the
linter. Most repos configure this as `siblings_only: true` (only
siblings under the same parent collide), but it's safer to just
make every heading unique.

If you genuinely need two "## Examples" sections (e.g. one per
section), prefix them: "## Examples (TypeScript)" / "## Examples
(Rust)".

### MD012 — no consecutive blank lines

One blank line between blocks. Never two. Editors that auto-format
on save will collapse them; if you're hand-editing, watch for them.

### MD041 — first line should be a top-level heading

The first non-frontmatter line of every `.md` file is a single `#
Heading`. After that, only one H1 per file (MD025). All subsequent
sections use `##`, `###`, etc.

Frontmatter (the `---` block at the top of SKILL.md files) does
NOT count as content for MD041 purposes — the H1 comes after the
closing `---`.

### MD034 — no bare URLs

Wrap bare URLs in angle brackets or markdown links:

```text
Wrong: see https://example.com for more

Right: see <https://example.com> for more
Right: see [more docs](https://example.com)
```

### MD033 — inline HTML

Most configs allow a small allowlist (`<br>`, `<sub>`, `<sup>`,
sometimes `<details>` / `<summary>`). Don't sprinkle other HTML;
use markdown equivalents.

## Tables: the rule prettier won't always fix for you

### Column widths must be uniform across every row

Each column in a markdown table must be padded to the same width
on every row, including the header separator. Prettier and most
formatters do this on save, but if you're hand-writing a table or
adding one row to an existing table, mirror the existing column
widths exactly.

```text
Wrong (column 2 widths differ row to row):

| Skill            | When it fires           |
| ---------------- | -------------------- |
| short-name       | always                                    |
| longer-name-here | sometimes |

Right:

| Skill            | When it fires |
| ---------------- | ------------- |
| short-name       | always        |
| longer-name-here | sometimes     |
```

Pick the longest cell in each column, add one space of padding on
each side, pad every other cell in that column with trailing
spaces to match.

### Separator row dashes must match column width

The `| --- |` row should use dashes wide enough to match the
column. Prettier normalises this; don't fight it.

### Do NOT put emojis in table cells

Emojis (✅, ❌, 🚀, 🔥, etc.) have ambiguous display widths.
Markdown linters compute table column widths using character
counts; the rendered width in a browser or terminal is different,
which causes:

- linter rejecting a table the human eye sees as aligned, or
- prettier "fixing" widths in a way that breaks linter alignment,
  causing a fix-loop ping-pong.

Use plain text markers instead:

```text
Wrong:                            Right:

| Feature  | Status |             | Feature  | Status      |
| -------- | ------ |             | -------- | ----------- |
| Login    | ✅     |             | Login    | done        |
| Signup   | ❌     |             | Signup   | not started |
```

This skill does not ban emojis in prose — only in tables and in
heading text (which is also flaky in some TOC generators).

## Lists

- One blank line between the prose above and the list (MD032).
- One blank line after the last bullet before the next prose
  block.
- Indent continuation lines with **2 spaces** (or whatever the
  repo's prettier config uses — check `.prettierrc` /
  `prettier.config.*` if unsure).
- Use `-` for unordered (consistent within a file) and `1.`,
  `2.`, ... for ordered. Don't mix `*` and `-`.

## Headings

- Use ATX-style headings (`#`, `##`, `###`), not setext (underline
  style).
- Blank line above and below every heading (MD022).
- Don't skip levels (`#` → `###` without `##`) — MD001.
- No trailing punctuation in heading text (MD026). "## Conclusion"
  not "## Conclusion:".

## SKILL.md frontmatter (specifically)

The frontmatter block:

```markdown
---
name: my-skill
description: ...
---
```

- The opening `---` must be the very first line of the file. No
  blank line, no BOM, no comment above it.
- The closing `---` must be on its own line.
- Inside the block: `key: value` only. No nested objects, no
  multi-line strings unless you use proper YAML block scalars (`>`
  or `|`).
- `description:` on a single line — if it gets long, wrap inside
  one quoted YAML string rather than spilling onto multiple lines.

After the closing `---`, leave one blank line, then the H1, then
the body.

## Prettier auto-normalizations (write it this way the first time)

Prettier runs alongside markdownlint in fred's pre-commit setup and
will silently rewrite your file on commit, then re-stage. The fixes
don't reject the commit on the first round, but the file ends up
modified again and the next round of hooks runs against the new
content. Writing markdown the way prettier wants it from the start
avoids that ping-pong.

The normalizations to anticipate:

- **Emphasis with underscores, not asterisks.** Write `_italic_`,
  not `*italic*`. Strong (`**bold**`) keeps the asterisks.
- **Unordered lists use `-`.** Not `*`, not `+`. Stay consistent
  within a file.
- **Numbered lists keep literal `1.`, `2.`, ...** Prettier does not
  renumber, and it expects a single space after the dot before the
  item text.
- **Blank line between numbered-list items that contain fenced code
  blocks.** Prettier and MD031 disagree about list-with-fence
  formatting otherwise — prettier will add the blank line, so just
  write it that way:

  ````markdown
  1. Step one.

     ```sh
     do-thing
     ```

  2. Step two.
  ````

- **Tables get re-padded.** Don't waste time hand-aligning a table
  to pixel-perfect widths; prettier will redo it on commit. Just
  make sure every row has the same number of `|` separators and
  prettier handles the rest.
- **Trailing whitespace stripped.** Don't leave it.
- **Final newline at EOF.** Always end the file with one newline.

## codespell (sibling hook, runs alongside markdownlint)

`codespell` is a separate pre-commit hook that scans for common
typos. It is **not** markdownlint and will reject the commit
independently. Frequent offender patterns (written with a space
to dodge codespell flagging this file itself — in real prose the
hyphenated or misspelled form is what trips the hook):

- The `re- use` / `re- uses` / `re- used` family → collapse to
  `reuse` / `reuses` / `reused` (no hyphen).
- `sep arately` (with the missing `a` in the wrong place) →
  `separately`.
- `occ ured` (single `r`) → `occurred`.
- `rec ieve` (i-before-e violation) → `receive`.
- `acc omodate` (single `m`) → `accommodate`.
- `pre- existing` is often allowed; check the repo's wordlist.

If a flagged word is a genuine proper noun, a domain term, or a
deliberate spelling, add it to the repo's `.codespellrc`
`ignore-words-list` or `typos.toml` rather than working around it
case by case. New additions should be real exceptions — don't
pollute the wordlist to dodge typos.

## When to stop and ask

- The repo's `.markdownlint.json` (or `.markdownlint.jsonc`, or
  `markdownlint.yaml`) disables one of the rules above. Defer to
  the repo config — don't fight it. Surface only if the repo
  config seems wrong.
- Prettier and markdownlint disagree (e.g. prettier wants 2-space
  list indent, markdownlint wants 4). That's a config bug;
  surface it to fred rather than picking a side per-file. See
  `precommit-fix-loop`.
- A table genuinely needs an emoji for content reasons (a doc
  about emoji support, an aviation status board where the emoji
  IS the data). Surface — there are escape valves
  (`<!-- markdownlint-disable MD013 -->`-style) but they should
  be an exception, not a habit.
