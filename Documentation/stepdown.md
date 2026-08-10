# Step-down style

Code should read from intent to detail.

A reader should understand the main behavior before reaching mechanics or constants.

## Preferred order

1. Stored instance properties, ordered from externally visible to private state.
2. The remaining module interface.
3. The main algorithm.
4. Subordinate semantic helpers, ordered by first use.
5. Nested helper modules that contain behavior or state.
6. Domain vocabulary such as private raw-value enums.
7. Passive static constants and shared error values.

## Rules

- Use extensions as semantic chapter boundaries.
- When a main algorithm and its subordinate member helpers share a file, place the helpers in a following extension so the transition from intent to implementation is visible.
- A semantic chapter may contain only one declaration. Avoid one-extension-per-function layouts when the functions belong to the same semantic layer.
- Put access control on individual declarations, never on extensions.
- Declare every stored instance property at the top of the primary type declaration, before initializers, computed properties, and methods.
- Put callers before the functions they call, unless a larger behavioral layer deserves priority.
- Give behavior more weight than passive declarations. Swift does not require definitions before use.
- Keep tightly coupled private helpers nested and in the same file. Extract them only if they gain independent callers, behavior, or an interface worth learning.
- Use domain names that let a non-expert follow the main algorithm. Keep numeric encodings and other lookup details near the bottom.
- Do not split files, introduce abstractions, or add boilerplate only to shorten a declaration.
