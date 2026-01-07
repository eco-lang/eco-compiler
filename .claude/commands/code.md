# `/code` – Code Style & Comment Review

This command runs a **code style and comment review** over the C++ and Elm codebases, focusing on readability, consistency, and high‑quality comments, without changing program behavior.

For full language and project conventions, always consult:

- **C++**: `@STYLE.md`
- **Elm**: `@compiler/STYLE.md`

This file only adds command‑specific guidance, especially around comment refactoring.

---

## Scope and Locations

When running a `/code` style cycle, the assistant should consider **all C++ and Elm code**, not just the most recently touched files.

- **C++ code**
  - `@runtime/`
  - `@elm-kernel-cpp/`
- **Elm code**
  - `@compiler/src`

During a code style cycle, **ALL C++ and Elm code in these locations should be examined and improved**, with emphasis on:

1. Readability
2. Consistency with the existing style guides
3. High‑quality, concise, and accurate comments

---

## Responsibilities of `/code`

The `/code` command is specialized for:

- Reviewing and improving **comments and documentation**
- Reviewing and cautiously improving **variable and identifier names**
- Improving **readability and consistency** (section headers, struct/record field comments, etc.)

It must:

- **Follow**:
  - `@STYLE.md` for C++
  - `@compiler/STYLE.md` for Elm
- **Not** change:
  - Control flow
  - Data structures or algorithms
  - Function signatures, return types, or public interfaces
  - Observable behavior or side effects

The goal is that the code compiles and behaves exactly the same, but is **easier to understand and maintain**.

---

## High‑Quality Comment Refactoring

Comment refactoring is the most important responsibility of `/code`. The assistant should systematically walk through the code and:

- **Remove** comments that are:
  - Redundant (“explains what each obvious line does”)
  - Incorrect or misleading
  - Restating the code literally without adding insight
- **Improve** comments that:
  - Are partially correct but unclear or vague
  - Explain *what* the code does but not *why* the approach is taken
  - Use inconsistent terminology relative to the rest of the project
- **Add** comments where:
  - The logic, invariants, or data flow are not obvious from reading the code
  - There are important **pre‑conditions** or **locking requirements**
  - There are subtle **edge cases**, **performance considerations**, or **GC interactions** (for C++)
  - There is an intentional trade‑off or non‑obvious design decision

All comments, in both C++ and Elm, should:

- Be **proper English sentences** ending with a period.
- Be **accurate** with respect to the actual code.
- Be **concise**: no unnecessary verbosity.
- Emphasize **intent and reasoning** (“why”) over line‑by‑line narration (“what”).
- Use terminology consistent with the rest of the project (GC, heap, nursery, AST, etc.).

### What Good Refactoring Looks Like (Conceptual Examples)

#### 1. Replace “what” with “why”

**Before**

```cpp
// loop through items
for (auto &item : items) {
    process(item); // process the item
}
```

**After**

```cpp
// Process each item to update its evacuation status before minor GC.
for (auto &item : items) {
    process(item);
}
```

The improved comment explains *why this loop exists* in the context of GC, not just that it loops.

#### 2. Clarify pre‑conditions and ownership

**Before**

```cpp
// Allocate memory
void* ptr = allocateFromNursery(size);  // May trigger GC
```

**After**

```cpp
// Allocate from the current thread's nursery. May trigger a minor GC if space is exhausted.
void* ptr = allocateFromNursery(size);
```

This version clarifies the allocation source, the thread context, and when GC might occur.

#### 3. Document invariants and state machines (Elm)

**Before**

```elm
type RemoteData data
    = NotAsked
    | Loading
    | Success data
    | Failure Http.Error
```

No comments can leave the meaning of states ambiguous in a complex UI.

**After**

```elm
type RemoteData data
    = NotAsked   -- No request has been made yet.
    | Loading    -- Request in flight; response not yet available.
    | Success data
    | Failure Http.Error
```

This helps future maintainers understand which transitions are valid and what each state represents.

---

## C++‑Specific Guidance (Brief)

Full rules are in `@STYLE.md`. `/code` should:

- Ensure **class, struct, and public method doc comments** follow the patterns in `@STYLE.md`.
- Prefer comments that explain:
  - Heap layout, GC phases, and color invariants.
  - Threading and locking requirements.
  - Ownership and lifetime of heap regions or pointers.
- Use section headings (e.g., `// ========== Allocation ==========`) to organize large files when appropriate.
- Improve **member and local names** only when they are genuinely unclear or misleading, always respecting existing conventions (snake_case, PascalCase, etc.).

---

## Elm‑Specific Guidance (Brief)

Full rules are in `@compiler/STYLE.md`. `/code` should:

- Ensure each **module**, exposed **type**, and exposed **function** has documentation comments in the expected Elm style (`{-| ... -}`).
- Add or refine comments for:
  - Important record fields in the compiler model and AST.
  - Non‑trivial transformations, type inference steps, and codegen passes.
  - State machines and TEA flows.
- Use section headers (`-- MODEL`, `-- UPDATE`, `-- VIEW`, etc.) where useful for clarity and consistency.

---

## Summary for `/code`

When invoked, `/code` should:

1. Look at **all relevant C++ and Elm code** under:
   - `@runtime/`, `@elm-kernel-cpp/` (C++)
   - `@compiler/src` (Elm)
2. Apply the detailed rules in:
   - `@STYLE.md` (C++)
   - `@compiler/STYLE.md` (Elm)
3. Focus on:
   - Comment refactoring (add/remove/clarify to improve understanding).
   - Conservative renaming for clarity.
   - Consistent sectioning and documentation of public APIs and data structures.
4. Never alter observable behavior, algorithms, or control flow.

The outcome should be a codebase that **reads clearly, explains itself at the right level, and follows a consistent commenting style across both C++ and Elm.**
