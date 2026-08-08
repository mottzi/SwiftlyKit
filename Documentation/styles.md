# Swift style

Use `stepdown.md` for declaration ordering. 

Apply these rules to statement layout.

- A line is horizontally long when its final character is at column 125 or later. Indentation counts toward the column.
- Place one blank line immediately inside the opening and closing braces of every type and extension declaration. Keep case-only enums compact, without those blank lines.
- Place one blank line immediately after a function's opening brace when its body contains more than three nonblank lines.
- Separate consecutive semantic phases with one blank line.
- In chronological workflows, reject invalid states with `guard` so the successful path remains unnested.
- Prefer one predicate per `guard`.
- Combine predicates in one `guard` only when separate guards would duplicate the same multiline `else` body.
- Before formatting a `guard`, bind evaluated subexpressions to meaningfully named local constants when its condition would be horizontally long.
- After extracting those values, keep a `guard` with a one-statement `else` body on one line when the complete statement ends before column 125.
- If that complete statement remains horizontally long, place `else` on the following line while keeping its one-statement body on that line.
- When an `else` body contains multiple statements, place `else {` on the same line as the final condition and place each body statement on a subsequent indented line.
- Indent every `case` one level inside its `switch`.
- Keep a case containing exactly one non-compound statement on the same line as its case label.
- Place a compound case body on subsequent indented lines. Compound statements include conditionals, switches, loops, and `do` blocks.
- When nested fallible operations produce separately meaningful domain values, bind the inner result before performing the outer operation.
