# Step-down style

Code should read from intent to detail.

A reader should understand the main behavior before reaching mechanics or constants.

## Preferred order

1. Stored instance properties, ordered from externally visible to private state.
2. Initializers.
3. The principal entry point or main algorithm.
4. The remaining module interface.
5. Subordinate state-dependent instance behavior, ordered by first use.
6. Subordinate pure or type-level behavior, such as static parsing and transformations.
7. Live or environment-dependent adapters used by default implementations.
8. Nested helper modules that contain behavior or state.
9. Domain vocabulary such as private raw-value enums and decoding types.
10. Passive static constants and shared error values.

## Rules

- The primary type declaration owns the type's stored state, initialization, and principal behavior.
- When a type has a clear main entry point or main algorithm, declare it in the primary type declaration immediately after its stored properties and initializers.
- Do not move the principal behavior into an extension merely to separate state from behavior.
- Use extensions as semantic chapter boundaries for behavior subordinate or additional to the principal behavior.
- Keep each semantic chapter homogeneous in role. Do not combine remaining interface, state-dependent instance mechanics, pure static transformations, and live adapters in one extension.
- Within extensions, group declarations by access level and dispatch kind. By default, do not mix static and instance declarations or declarations with different access levels in one extension.
- Make an exception only when the declarations jointly implement one inseparable semantic role and separating them would obscure that relationship.
- When a principal algorithm and its subordinate member helpers share a file, place the helpers in a following extension so the transition from intent to implementation is visible.
- An extension may contain a single declaration when that declaration forms a meaningful semantic chapter. Do not create one extension per function when multiple functions belong to the same layer.
- Put access control on individual declarations, never on extensions.
- Keep implementation helpers private unless a production caller needs them or they form an intentional internal seam.
- Do not widen a helper's visibility solely so `@testable` tests can call it directly. Prefer testing through the module interface. If the helper deserves direct callers and tests, extract a coherent helper module with an interface worth learning.
- Keep live adapters used only to provide default dependency behavior private unless they have independent production callers.
- Declare every stored instance property at the top of the primary type declaration.
- If a type has no clear principal operation, do not invent or arbitrarily designate one merely to satisfy this ordering.
- Put callers before the functions they call, unless a larger behavioral layer deserves priority.
- Give behavior more weight than passive declarations. Swift does not require definitions before use.
- Keep tightly coupled private helpers nested and in the same file. Extract them only if they gain independent callers, behavior, or an interface worth learning.
- Use domain names that let a non-expert follow the main algorithm. Keep numeric encodings and other lookup details near the bottom.
- Do not split files, introduce abstractions, or add boilerplate only to shorten a declaration.
