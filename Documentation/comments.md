# Code Comment Guide

Reference comment policy for LLM coding agents. Follow every rule below when
generating or modifying comments. See [STYLES.md](STYLES.md) for Swift layout.

You must use ASD-STE100 Simplified Technical English for comments.

## Comment-task scope

- For a task that asks to add comments to a target file using this guide, scan
  the complete target file for placeholder comments before editing it. A
  placeholder comment is a line whose trimmed content is exactly `//` or `///`.
- If the target file contains one or more placeholder comments, fill only those
  placeholders. Do not create, adjust, move, or remove any other comment in the
  file.
- If the target file contains no placeholder comments, create or adjust comments
  only for:
  - Type declarations, including structures, classes, enumerations, protocols,
    actors, and equivalent type definitions.
  - `public` or `internal` function declarations, including functions whose
    effective access is implicitly `internal`.
  - `public` or `internal` computed-property declarations, including properties
    whose effective access is implicitly `internal`.
- Never create or adjust a comment for an empty initializer or an initializer
  whose body contains only direct stored-property assignments, regardless of its
  access level. In placeholder-only mode, preserve a placeholder attached to
  such an initializer without filling it.
- In the no-placeholder case, do not create, adjust, move, or remove comments
  for any other declaration or implementation detail.

## Required codebase research

- Before creating or adjusting each comment, identify the declaration or
  implementation group it documents and inspect every relevant call site or use
  site across the codebase. For a type, inspect its construction, conformances,
  and other references; for a function, inspect every caller; for a computed
  property, inspect every read and write; for a local implementation comment,
  inspect the callers of its enclosing function and the uses of the state it
  affects.
- Read the complete implementation of the documented declaration or enclosing
  function. Recursively follow every project-owned function or method it calls
  until reaching the bottom of each implementation path. For dynamically
  dispatched calls, inspect the relevant overrides or protocol conformances.
  Stop a path only at a leaf implementation, a system or external-dependency
  boundary, or a previously inspected cycle.
- If the documented declaration has no implementation body, inspect its concrete
  implementations and the implementation paths that establish its behavior.
- Ground the comment only in behavior verified by these call-site and
  implementation-path inspections. Do not fill gaps with assumptions; describe
  the narrowest useful contract supported by the codebase.

## Formatting and wording

- Inline comments (`//`) start with lowercase and have no terminal punctuation.
- Documentation comments (`///`) use standard English capitalization and
  terminal punctuation.
- Treat lines containing only `//` or `///` as deliberate placeholder comments.
  During a style-only pass, preserve them exactly—including their location—and
  do not remove, rewrite, or replace them unless the user explicitly requests
  it.
- Keep both styles to one line in nearly all cases. Two lines are allowed when
  context requires them; three lines are the absolute maximum and reserved for
  extreme cases.
- Prefer concise technical action verbs such as `abort` and `return` over
  conversational phrases such as “quit immediately.” Omit adverbs such as
  “immediately” when control flow already conveys them.
- Map language directly to logic: use `if`, not temporal wording such as `when`,
  for boolean evaluations and guard checks.
- Use ASD-STE100 Simplified Technical English.

## Meaning and scope

- Place `///` above function, class, or other declarations. Describe the
  declaration's high-level systemic purpose, macro behavior, or side effects.
- Use `//` only inside function bodies for local mechanical actions specific to
  the immediately following code.
- Document types with direct noun phrases; omit filler openings such as “Defines
  the” and “Represents a.”
- For an early exit, state the business or state condition that causes the exit
  rather than narrating syntax or an abstract requirement.
- Format early-exit comments as `[action] if [condition]`, for example:

```swift
// abort if user didn't confirm quitting
```

- When creating comments in a nontrivial function body, describe semantic groups
  rather than individual obvious statements. Put each comment immediately above
  its group and keep the group short enough that the comment remains clearly
  connected to every line it describes. If that connection becomes unclear, use
  a more local comment or split the function.

## Declaration placement

- Put declaration attributes and macros (for example, `@main`, `@available`,
  `@MainActor`, and `@Observable`) above the documentation comment, never
  between the documentation and its declaration:

```swift
@main
/// Single window app and its shared lifecycle model.
struct TripleApp: App {
```

- Put a property's documentation comment above its property wrapper. Keep the
  wrapper and property declaration on the same line:

```swift
/// Routes native termination events through coordinated shutdown.
@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

/// Preserves one observable model for the window's lifetime.
@State private var model = AppSession()
```
