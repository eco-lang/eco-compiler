# Typechecker Simplification — "More" (Step 8, items 3 & 4)

Two small, low-risk cleanups deferred out of `plans/typechecker-simplification.md` (its
**Out of scope** section, "step-8 optional bets"). They are grouped here because they are
**mechanical, local, and independently verifiable** — the safe warm-up that lands *before* the
two larger, mutually-exclusive DSL rewrites (`typechecker-design-b.md`,
`typechecker-design-c.md`).

- **Item 3** — collapse the single-constructor **record-wrapper** types to bare `type alias`es.
- **Item 4** — add `traverseArray`/`foldMArray` combinators to `System.TypeCheck.IO` and route the
  two hand-rolled `Array`-in-`IO` sites through them.

**Do this plan first, confirm green, then attempt Design B and Design C independently** (each on
its own branch/worktree from the post-`typechecker-more` baseline). Nothing here touches the DSL,
the union-find `Array` IO, or the `IO.loop` trampoline, so it will not conflict with either.

Prerequisite: S1–S7 of `typechecker-simplification.md` are **done and green** (see the memory
`typechecker-simplification-progress`). This plan assumes that baseline (one merged
`Compiler.Type.Constrain.Typed.*` generator; `Record1` already on elm/core `Dict`; `Strict.elm`
already gone).

---

## Guiding principle

Same as the parent plan: **do not touch the two properties that justify the typechecker's shape**
— the mutable `Array`-backed union-find speed and the `IO.loop` constant-stack safety. Both items
below are representation/plumbing tidy-ups with **no behavioral change** and **no change to
constraint output** (so `TypedErasedCheckingParity` and all `elm-tests` stay byte-for-byte green).

---

## Item 3 — Collapse record-wrapper types to bare aliases

### Finding

The typechecker has several `type X = X XProps` custom types whose single constructor wraps a
single record alias. Each one forces a heap box plus an explicit wrap at construction and an
unwrap (`case`/destructure) at every read — pure noise, since the constructor carries no
discriminating tag and the record already *is* the value. Candidates (single-constructor over a
record):

| Type | Defined at | Wrap/unwrap churn | Hotness |
|------|-----------|-------------------|---------|
| `Descriptor = Descriptor DescriptorProps` | `System/TypeCheck/IO.elm:441-458` (ctor `makeDescriptor:463`) | ~85 sites across the compiler | **Hot** — boxed/unboxed on every union-find `get`/`set`/`modify`/`union` and every `variableToCanType` |
| `NameState = NameState NameStateData` | `System/TypeCheck/IO.elm:159-160` | ~41 sites | Warm — every naming pass; added in S2 |
| `Context = Context ContextProps` | `Compiler/Type/Unify.elm:236-245` (ctor `makeContext:250`) | ~32 refs, module-local | Warm — unwrapped in `merge`/`fresh`/`reorient` per unify |
| `Args = Args ArgsProps` | `Compiler/Type/Constrain/Common.elm:220-245` (ctor `makeArgs:243`) | local | Cool — per function-def arg processing |

`Descriptor` is the highest-value target: `UnionFind.get/set/modify/union`
(`UnionFind.elm:87-219`), `Unify.merge` (`Unify.elm:265-278`, which unwraps `desc1`/`desc2`),
`Type.variableToCanType` (`Type.elm:489-`), and `Solve` all pay for the box on the hot path.

### Change

For each wrapper, `type X = X XProps` → `type alias X = XProps` (fold `XProps` into `X`, or keep
`XProps` and make `X` an alias of it — prefer keeping the descriptive `…Props` name and aliasing:
`type alias Descriptor = DescriptorProps`). Then:

- The smart constructor becomes a plain record literal: `makeDescriptor content rank mark copy =
  { content = content, rank = rank, mark = mark, copy = copy }` (keep the function — it is the
  positional-construction API and shields call sites from field-name churn).
- Delete every wrap `Descriptor { … }` / `X (makeX …)` box and every unwrap
  `(Descriptor props) = …` / `case d of Descriptor props ->` / `\(IO.Descriptor p) -> …`, replacing
  with direct field access on the record.
- Update the module export lists: `Descriptor(..)` → `Descriptor` (it is now an alias, no
  variants). Update importers that pattern-match `IO.Descriptor …` (e.g. `Unify.merge`,
  `Type.variableToCanType`, `Occurs`, `Solve`, `SolverRoots`, `SolverSnapshot`).

**Recommended scope / order** (each independently green-able; stop-and-verify between):
1. `Descriptor` — the win. Broadest churn (IO.elm, UnionFind.elm, Type.elm, Solve.elm, Unify.elm,
   Occurs.elm, SolverRoots.elm, SolverSnapshot.elm, Data/IORef.elm reads).
2. `Context` and `Args` — module-local, trivial.
3. `NameState` — trivial; do it last (recently added, least payoff).

**Explicitly out of scope for item 3:** the *scalar* newtypes `Point = Pt Int` (`IO.elm:415`),
`Mark = Mark Int` (`IO.elm:514`), and `IORef a = IORef Int` (`Data/IORef.elm:52`). These are not
record-wrappers — they carry a **nominal distinction** (a `Variable`/`Point` must not be confused
with a bare `Int` index, and `IORef` phantom-types the ref target). Collapsing them trades a real
type-safety guard for a negligible unbox and is **not** part of this item.

### Watch-outs

- **Structural `==`:** records compare structurally, exactly as the single-ctor wrapper did, so
  any `desc1 == desc2` / `content ==` comparisons keep the same result. Verify none relied on
  constructor identity (none should).
- **Elm ambiguity:** a bare `type alias X = { … }` also generates a *record constructor function*
  `X : a -> b -> … -> X`. If any positional `X a b c` construction exists that is **not** the
  wrapper (unlikely here), it will now build a record positionally — audit for it. Using the
  explicit `makeDescriptor`/`makeContext`/`makeArgs` constructors avoids this.
- **Array default/`Maybe`:** `Array Descriptor` and `Array.get` behavior are unaffected by aliasing.

### Risk

Low, but **broad** for `Descriptor` (touches the whole union-find + solve + annotate chain). Purely
mechanical; no constraint-output change. **Verify:** full `elm-tests` (`Failed: 0`) — especially
union-find/unify/annotation exercises — plus E2E `--target full` (`Result: PASSED`). Because output
is unchanged, `TypedErasedCheckingParity` must stay green untouched.

---

## Item 4 — `traverseArray`/`foldMArray` combinators in `System.TypeCheck.IO`

### Finding

There are exactly **two** genuinely `IO`-monadic `Array` traversals in the typechecker, and both
hand-roll an `Array.toList` → list-combinator → `Array.fromList` round-trip:

- `Type.arrayTraverseMaybe` (`Type.elm:474-486`) — `Array.toList >> IO.traverseList (…) >>
  IO.map Array.fromList`, preserving `Nothing` holes.
- `Type.toCanTypeBatch` (`Type.elm:448-468`) — `IO.foldM (…) Dict.empty (Array.toList nodeVars)`
  for the first (name-collection) pass.

(For contrast, the other `Array` uses are **pure**, not `IO` — `NodeIds.elm:154-159`
`Array.set/append/push`, `SolverRoots.elm:44` `Array.map`, `PostSolve.elm:1276-1281`,
`SolverSnapshot.elm:40`, `SolverRoots.elm:218` `Array.get`. Leave those; they are not traversal
candidates.)

### Change

Add, next to `traverseList`/`foldM` in `System/TypeCheck/IO.elm`, stack-safe `Array` analogues
built on the existing `IO.loop` (so they inherit constant-stack safety):

- `traverseArray : (a -> IO b) -> Array a -> IO (Array b)`
- `foldMArray : (b -> a -> IO b) -> b -> Array a -> IO b`
- (optional, if it cleans `arrayTraverseMaybe`'s call site) keep `arrayTraverseMaybe` but
  reimplement it in terms of `traverseArray`, or add
  `traverseArrayMaybe : (a -> IO b) -> Array (Maybe a) -> IO (Array (Maybe b))`.

Implementation note: the simplest correct form mirrors the current code —
`Array.toList >> loop >> Array.fromList` internally. That already keeps the *public* call sites
clean while confining the round-trip to one place. An index-based variant
(`IO.loop` over `Array.get idx`, accumulating, then `Array.fromList`) avoids the intermediate
`toList` allocation but buys little here (both sites run once per compile, at annotation time, not
on the hot union-find path). **Recommend the `toList`/`fromList`-based implementation** unless a
profile later shows these sites matter; do not over-engineer.

Then route the two sites:
- `arrayTraverseMaybe` → `traverseArrayMaybe` (or express via `traverseArray`).
- `toCanTypeBatch`'s first pass → `foldMArray` (drop the explicit `Array.toList`).

Export the new combinators from `System.TypeCheck.IO` (extend the `@docs` line at `IO.elm:3-4`).

### Risk

Very low; local to `IO.elm` + `Type.elm`. Honest note: the payoff is **small** (two call sites, off
the hot path) — the value is removing the hand-rolled round-trips and giving the module a
consistent `Array` traversal vocabulary alongside its list one, not a speed win. **Verify:**
`elm-tests` (`Failed: 0`), E2E `--target full` (`Result: PASSED`). Annotation-rendering tests
exercise `toCanTypeBatch`.

---

## Test protocol (after each item; per `CLAUDE.md`, run each suite **once**, tee, grep)

1. `cmake --build build --target elm-tests 2>&1 | tee /tmp/more_elmtests.txt` → require `Failed: 0`.
2. `cmake --build build --target full 2>&1 | tee /tmp/more_e2e.txt` → require `Result: PASSED`.
   Use `full` (not `check`): these are Elm/front-end changes that regenerate MLIR.

Do the two items as separate, independently-green commits (and within item 3, the four wrappers as
separate commits) so a regression is trivially bisected. A step is done only when both suites are
green.

Note: adding a *new* file is not required here (no new test module), so no `cmake --preset build`
reconfigure is needed — but if you split a combinator into a new module or add a regression test
file, remember the glob-reconfigure gotcha (memory `eco-cmake-preset-and-glob-reconfigure`).

## Success criteria

1. The chosen record-wrappers (`Descriptor` at minimum; ideally also `Context`, `Args`,
   `NameState`) are bare `type alias`es; all wrap/unwrap boilerplate gone; `make…` constructors
   retained.
2. `traverseArray`/`foldMArray` (+ maybe-variant) live in `System.TypeCheck.IO`; the two `Type.elm`
   `Array`-`IO` sites use them; no hand-rolled `Array.toList … Array.fromList` round-trips remain in
   the typechecker's `IO` code.
3. `elm-tests`: `Failed: 0`. E2E `--target full`: `Result: PASSED`. `TypedErasedCheckingParity`
   green and **unchanged** (zero constraint-output drift).
4. Union-find `Array` IO and the `IO.loop` trampoline untouched.

## Out of scope

The DSL rewrites (Designs B and C) — see `typechecker-design-b.md` and `typechecker-design-c.md`.
The scalar newtypes `Point`/`Mark`/`IORef` (keep their nominal distinction).
