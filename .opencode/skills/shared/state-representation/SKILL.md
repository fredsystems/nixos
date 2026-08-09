---
name: state-representation
description: Use when about to add a bool field or bool parameter, pass a bare true/false at a call site, add a second bool that cannot legally be true at the same time as an existing one, transport a bool across a crate/thread/process/API boundary, or reach for an excessive-bools lint suppression. Applies in every one of fred's repos regardless of language. Codifies the named-domain-enum rule, the three cases where a bool MUST become an enum, and the three cases where a bool is correct.
---

# State representation: name the state

A `bool` says a value has two cases. It does not say **what the cases
mean**. `true` at a call site is unreadable, unsearchable, and silently
swappable with the argument next to it.

The rule: **state is a named domain enum, not a bare `bool`.**

Repos may add their own high-risk sites and exemplars on top of this;
the rules below are the common core.

## Name the enum for its domain, never generically

The enum's name says what the state _is_. Its variants say what the
cases _are_ in that domain's language.

```text
Bad:   Enabled / Disabled          (shared, meaningless, collides)
Bad:   Flag, State, Mode, Status   (says nothing)
Good:  BlinkState::{Enabled, Disabled}
Good:  CursorVisibility::{Visible, Hidden}
Good:  WrapMode::{Wrap, NoWrap}
```

A single shared generic `Enabled`/`Disabled` type used for a dozen
unrelated concepts is barely better than a `bool`: it type-checks when
you pass cursor visibility to a blink parameter.

## When a bool MUST become a named enum

### 1. Bool parameters -- always, no exceptions

A `bool` in a parameter list is illegible at the call site:

```text
render(surface, true, false, true)
```

Nobody can read that, and the arguments can be transposed silently.
Every boolean parameter becomes a named enum -- or, when there are
several, a small options struct with named fields.

This applies even to private functions. "It's only called twice" is how
it becomes called nine times.

### 2. Two or more bools that cannot legally both be true

Two bools encode four states. If only three are legal, the type permits
an unrepresentable one, and every reader must reconstruct that rule
from context:

```text
Bad:   is_loading: bool, is_error: bool     (what does true/true mean?)
Good:  LoadState::{Idle, Loading, Error}
```

Make the illegal state unrepresentable rather than documenting that it
must not happen.

### 3. Bools crossing a boundary

A bool that crosses a crate, module, thread, process, serialization, or
public-API boundary loses whatever local context made it readable. At
the far side it is just `true`.

If the value is transported -- through a snapshot, a channel, a
message, a public signature, a stored record -- create the enum. Locality
of the definition does not survive the boundary.

## Where bools stay -- do NOT convert these

Three cases where a `bool` is the correct type:

### Independent simultaneous signals

Several conditions that are genuinely independent and may all hold at
once are not one state machine. A struct of named bool fields is
correct; forcing them into one enum would misrepresent them.

The test: can any combination legally occur? If yes, they are
independent signals, not an enum.

### Modifier and flag sets

Sets like keyboard modifiers (`shift`, `ctrl`, `alt`) are independent
by nature, are usually consumed as a set, and often map to an external
protocol's bit layout. Leave them as bools or a bitflags type.

### Config toggles deserialised from an external format

A `true`/`false` in TOML, JSON, or YAML that maps directly to a config
field stays a bool at the deserialisation boundary. The external format
has no enum. Convert to a domain enum _after_ parsing if the value then
drives internal state.

## Existing suppressions are evidence, not permission

A lint suppression (`excessive_bools`, `fn_params_excessive_bools`, or
equivalent) already in the tree is a record that someone hit this rule
and deferred it. It is **not** precedent for adding another.

When you touch code carrying such a suppression, the default is to fix
the underlying representation and delete the suppression. Adding a new
one requires a real justification that fits one of the three
"bools stay" cases above -- and should be stated in a comment.

## The cost is not the argument

The runtime cost of a fieldless enum versus a bool is zero in every
language fred's repos use. Performance is never the reason to keep a
bool. If someone reaches for that argument, the real reason is that the
change is tedious -- which is a scheduling question, not a design one.

## When to stop and ask

- The conversion would ripple through a large public API surface. That
  is a real cost; surface it and let the user schedule it rather than
  doing it inline as a drive-by.
- You cannot find a good domain name for the enum. That usually means
  the state is not actually one concept and the code needs a different
  split.
- An external protocol or wire format dictates a boolean layout that a
  domain enum would fight.
