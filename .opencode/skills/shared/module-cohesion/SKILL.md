---
name: module-cohesion
description: Use when about to add a type, struct, enum, or trait to an existing file whose name describes a different concept, add a second unrelated test module to a file, or add code to a file you had to scroll to the end of to find the insertion point. Applies in every one of fred's repos regardless of language. Codifies one CONCEPT per module (not one type per file), the path-names-the-concept rule, and the prohibition on splits that widen visibility.
---

# Module cohesion: one concept per module

A module holds **one concept**. Not one type -- one concept. A concept
may need several types to express it, and those belong together.

The inverse is what this skill prevents: a file that accumulated a
second, unrelated concept because it was the file already open.

Repos may add their own exemplars and high-risk files on top of this;
the rules below are the common core.

## The trigger

Load this skill when any of these is true:

- You are adding a type to a file whose **name describes a different
  concept** than the type you are adding.
- You are adding a **second unrelated test module** to a file.
- You had to **scroll to the end of the file** to find where to put the
  new code. That scroll is the signal: you no longer hold the file's
  shape in your head, and neither will the next reader.
- You are adding to a file that already carries a length suppression.

## Rules

1. **The path names the concept.** A reader should predict a file's
   contents from its path alone. If the path says `parser` and the file
   also holds a colour table, one of them is in the wrong place.

2. **A concept may be several types.** Do not split a struct from its
   builder, its error type, and its iterator just to make files
   smaller. Cohesion beats file count. "One type per file" is not the
   rule and produces a directory of fragments that must all be opened
   together.

3. **Unrelated means unrelated to the module's concept**, not
   "unrelated to the type next to it". Two types that jointly express
   one idea belong together even if they share no fields.

4. **Test modules follow their subject.** Tests for a concept live with
   that concept. A second test module covering something else is the
   same smell as a second production concept.

5. **Length is a symptom, not the rule.** A long file about one
   coherent concept is fine. A short file about two concepts is not.
   Do not split by line count; split by concept.

6. **A new concept gets a new module.** Rather than making the
   already-large file larger, create the module the concept deserves --
   and say that you are doing so, rather than doing it silently.

## What this does not license

- **Do not split a module to dodge a length lint.** Moving half a
  concept into `foo_extra` to get under a threshold makes the code
  worse and the lint quieter. Fix the concept boundary or leave it.

- **Do not widen visibility to enable a split.** If extracting a type
  into its own module forces internals from private to public, the
  split is wrong. A split that damages encapsulation costs more than
  the large file it fixed. This is the most common failure mode:
  the mechanical move succeeds, and the module's invariants are now
  enforceable by nobody.

- **Do not create a `utils` / `helpers` / `misc` module.** Those names
  describe no concept, so nothing can ever be predicted from the path,
  and they accumulate without limit. If a helper has no home, it is
  usually a hint that its concept has not been named yet.

- **Do not reorganise unrelated code while you are in there.** Improving
  cohesion is worthwhile, but it is its own task with its own review.
  See `autonomy-boundaries` -- an opportunistic reorganisation is scope
  creep even when it is an improvement.

## When to stop and ask

- The correct split is obvious but large, touching many call sites.
  Surface it as a proposal; do not fold a wide mechanical refactor into
  an unrelated change.
- You cannot name the concept a module would hold. That means the
  boundary is not understood yet -- naming it is the actual work.
- Splitting would require making internals public. Stop; surface the
  tension rather than choosing encapsulation loss silently.
