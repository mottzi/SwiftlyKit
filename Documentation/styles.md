# Swift style

Use `stepdown.md` for declaration ordering. Apply these rules to statement layout.

- Separate consecutive semantic phases with one blank line.
- In chronological workflows, reject invalid states with `guard` so the successful path remains unnested.
- Prefer one predicate per `guard`.
- Combine predicates in one `guard` only when separate guards would duplicate the same multiline `else` body.
- Keep a `guard` on one line when its `else` body is one short statement.
- When a one-statement `else` body makes the complete guard difficult to scan, keep the body on one line and place `else` on the line after the condition.
- When an `else` body contains multiple statements, place `else {` on the same line as the final condition and place each body statement on a subsequent indented line.
- Indent every `case` one level inside its `switch`.
- Keep a case containing exactly one non-compound statement on the same line as its case label.
- Place a compound case body on subsequent indented lines. Compound statements include conditionals, switches, loops, and `do` blocks.
- When nested fallible operations produce separately meaningful domain values, bind the inner result before performing the outer operation.
