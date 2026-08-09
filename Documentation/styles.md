# Swift style

Use `stepdown.md` for declaration ordering. 

Apply these rules to statement layout.

- A line is horizontally long when its final character is at column 125 or later. Indentation counts toward the column.
- Place one blank line immediately inside the opening and closing braces of every type and extension declaration. Keep case-only enums compact, without those blank lines.
- Place one blank line immediately after a function's opening brace when its body contains more than three nonblank lines.
- Keep a function declaration header on one line when its final character would occur before column 125.
- Separate consecutive semantic phases with one blank line.
- Treat cancellation checks, input construction, operation execution, result validation, and result transformation as separate semantic phases.
- In a chronological workflow, do not pass a value produced by a multiline initializer directly into another operation. Bind it to a meaningfully named local constant first.
- Keep a readable one-use expression inline when it is consumed immediately by a `guard`, `switch`, `return`, or non-multiline call. Do not extract it merely to name a Boolean, expose a raw value, isolate a throwing call, or create a semantic-phase boundary. The multiline-initializer, horizontally-long-guard, and nested-fallible-operation rules take precedence when they apply.
- In chronological workflows, reject invalid states with `guard` so the successful path remains unnested.
- Prefer one predicate per `guard`.
- Combine consecutive predicates in one `guard` when and only when their separate `else` blocks would be identical and nontrivial.
- An `else` block is trivial only when it contains exactly one of these statements: `return`, `break`, `continue`, `return true`, `return false`, `return nil`, `return` followed by a simple reference, or `throw` followed by a simple reference.
- A simple reference is an identifier or dot-separated member chain, optionally beginning with a dot, containing no call, subscript, operator, closure, or literal.
- Every other `else` block is nontrivial, including a block with multiple statements or a statement that constructs or transforms a value, calls a function, or contains diagnostic text.
- Never combine predicates whose `else` blocks differ.
- In a combined `guard`, place each predicate on its own aligned line.
- Before formatting a `guard`, bind evaluated subexpressions to meaningfully named local constants when its condition would be horizontally long.
- After extracting those values, keep a `guard` with a one-statement `else` body on one line when the complete statement ends before column 125.
- If that complete statement remains horizontally long, place `else` on the following line while keeping its one-statement body on that line.
- When an `else` body contains multiple statements, place `else {` on the same line as the final condition and place each body statement on a subsequent indented line.
- Indent every `case` one level inside its `switch`.
- Keep a case containing exactly one non-compound statement on the same line as its case label.
- Place a compound case body on subsequent indented lines. Compound statements include conditionals, switches, loops, and `do` blocks.
- When a `do` block and an associated `catch` clause each contain exactly one non-compound statement, keep each complete block on its own single line only when that line ends before column 125. Expand any horizontally long block, placing its statement on subsequent indented lines. Apply the line-length decision independently to the `do` block and every clause in a `catch` chain.
- When nested fallible operations produce separately meaningful domain values, bind the inner result before performing the outer operation.
