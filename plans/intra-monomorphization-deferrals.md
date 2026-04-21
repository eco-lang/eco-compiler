# Intra-Monomorphization Refinements: Destructured Value-Multi + Kernel ABI Result Types

## Status: PLAN (not yet implemented)

## Framing

Two related changes, both inside Monomorphize:

- **Part A (Issue #1)** — *extend the existing intra-pass deferral machinery to
  destructured tuple paths.* Mirrors what `TOpt.Access` already does for record fields.
- **Part B (Issues #8 / #9)** — *make kernel call result typing follow the kernel ABI
  function type*, so we don't lose already-known concreteness by re-deriving from the
  call expression's canonical type.

Part A is a genuine new deferral point; Part B is not — it's a correction to which
already-computed type we trust at an existing call site.

## Problem

Two related bugs share a root cause: **we commit to SSA/heap layout while the `MonoType`
at that point still contains `MVar`s, and we never revisit that decision once the `MVar`s
become concrete.**

### Issue #1 — polymorphic record-update lambda inside a destructured tuple

```elm
let
    pair =
        case loc of
            First  -> ( .a, \x m -> { m | a = x } )
            Second -> ( .b, \x m -> { m | b = x } )
in
let
    (getter, setter) = pair
in
...
```

`pair` is `shouldUseValueMulti`-eligible (contains lambdas + unconstrained CEco type vars),
so a `ValueMultiState` is created. But the destructor `(getter, setter) = pair` does NOT
currently refine `subst` against the root value's canonical type, so the lambdas inside
each instance see underdetermined record parameter types. The record-update lambda
therefore computes the wrong unboxed bitmap, and the heap layout mismatches what the
caller expects.

### Issues #8 and #9 — kernel tuple3 result projected as `!eco.value`

`Elm.Kernel.Parser.findSubString` returns `(Int, Int, Int)`. At MLIR codegen time,
`Patterns.generateMonoPathHelper` in the `Mono.Tuple3Container` branch projects elements
as `!eco.value` (boxed) when `resultType` is an `MVar`. The runtime tuple layout actually
stores three unboxed i64s, so `-1` gets interpreted as a raw HPointer and crashes.

Root cause: at the `TOpt.Call` site for the kernel, the enclosing expression's
`meta.tipe` still has TVars (the outer lambda is polymorphic), so `callResultMonoType`
produces a result `MonoType` with `MVar`s even though the kernel wrapper itself has a
fully monomorphic ABI.

## Existing machinery (what we build on)

- **`ValueMultiState`** (`State.elm:302`): tracks let-bound values containing lambdas;
  instances keyed by `Mono.toComparableMonoType`.
- **`shouldUseValueMulti`** (`Specialize.elm:358`): triggers on
  `typeContainsLambda && hasCEcoTVar`.
- **`getValueMultiVar`** (`Specialize.elm:373`): pattern matches `TOpt.VarLocal` /
  `TOpt.TrackedVarLocal` roots against the valueMulti stack. Already used at
  `TOpt.Access` (`Specialize.elm:2272`).
- **`getOrCreateValueInstance`** (`Specialize.elm:396`): allocates/reuses an instance
  for `(defName, monoType)` via `updateValueMultiStack`. Keyed by
  `Mono.toComparableMonoType`; same key → same `freshName`, first instance keeps the
  bare `defName`, subsequent get `$v1`, `$v2`, …
- **`TypeSubst.unifyExtend`**: extends substitution by unifying a canonical type with a
  partial mono type. Already used at `TOpt.Access` with a *partial* `MRecord` container
  (`Specialize.elm:2287-2291`).
- **`deriveKernelAbiType`** (`Specialize.elm:3844`): computes the fully monomorphic ABI
  type for a kernel call using `KernelAbiMode` policy.
- **`Mono.resultTypeOf`** (`Monomorphized.elm:277`): unwraps curried `MFunction` into the
  final result type.

## Design

### Part A — Value-multi for destructured tuples (Issue #1)

Add a destructor hook that mirrors the existing `TOpt.Access` hook for record fields.
**Critical correction from the original sketch:** the refinement must unify the *root's*
canonical type against a *partial container* reconstructed from the path, NOT unify the
destructor's canonical type against its own image under `subst` (which is a no-op).

The `TOpt.Access` analog uses `MRecord { fieldName: fieldMonoType }` as the partial
container. For destructors we generalize: given a path and the destructor's mono type,
walk the path outward building a partial container with the destructor's mono type at
the leaf position and fresh `MVar`s for sibling positions. Unifying this partial
container against `rootCanType` under `subst` pushes constraints (e.g., `a ~ Int`) back
into the root's instantiation — including into the lambdas nested inside it.

**New helpers in `Specialize.elm`** (next to `getValueMultiVar`):

```elm
-- Walk a TOpt.Path to its TOpt.Root, return root name + canonical type if
-- the root is a valueMulti target. Root is always the leaf (confirmed: the
-- TOpt.Path type has Root as its only non-recursive constructor).
getValueMultiRootFromPath :
    TOpt.Path -> MonoState -> Maybe ( Name, Can.Type MVarId )

-- Rewrite the Root of a TOpt.Path to a new name, preserving the Index/Field/
-- ArrayIndex/Unbox chain around it.
rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path

-- Build a partial MonoType container from a path outward from the Root,
-- placing `leafMonoType` at the Root position and fresh MVars for siblings.
-- Examples:
--   Index 0 HintTuple2 (Root n)         -> MTuple [leafMonoType, MVar fresh CEcoValue]
--   Index 1 HintTuple3 (Root n)         -> MTuple [MVar, leafMonoType, MVar]
--   Field "a" (Root n)                  -> MRecord (Dict.singleton "a" leafMonoType)
--   Unbox (Root n)                      -> leafMonoType (wrapper's payload is the leaf)
--   Index i (HintCustom ctor) (Root n)  -> <constructor layout with leaf at i, MVars elsewhere>
-- Nested paths compose by wrapping from outside in.
buildPartialContainer :
    TOpt.Path -> Mono.MonoType -> MonoState -> ( Mono.MonoType, MonoState )
```

`buildPartialContainer` may need to allocate fresh `MVarId`s for sibling positions; the
state thread lets it do so.

**Modify `TOpt.Destruct` branch of `specializeExpr`** (`Specialize.elm:2168-2202`):

1. Detect `getValueMultiRootFromPath path state` returning `Just (rootName, rootCanType)`.
2. Compute the destructor's tentative `monoType0` as today
   (`Mono.forceCNumberToInt (applySubstFV state subst canType)`).
3. Build a partial container matching the destructor's path:
   ```elm
   ( partialContainerMono, stateP ) =
       buildPartialContainer path monoType0 state
   ```
4. Refine the substitution by unifying the root's canonical type against the partial
   container:
   ```elm
   refinedSubst =
       Tuple.first
           (TypeSubst.unifyExtend
               stateP.ctx.mvarEnv
               rootCanType
               partialContainerMono
               subst)
   ```
5. Apply `refinedSubst` to `rootCanType` to derive `rootInstanceMonoType`.
6. Call `getOrCreateValueInstance rootName rootInstanceMonoType refinedSubst stateP`
   to obtain a fresh root name.
7. Rewrite the path's root via `rewriteRootInPath` and call `specializeDestructor`
   with `refinedSubst` + the rewritten path.
8. Specialize the body under `refinedSubst`.

**Fall back to the existing non-valueMulti path** when
`getValueMultiRootFromPath` returns `Nothing`.

### Part B — Kernel ABI result types (Issues #8/#9)

**Modify `TOpt.VarKernel` arm inside `TOpt.Call`** (`Specialize.elm:1536-1564`):

Replace:
```elm
resultMonoType =
    callResultMonoType state1a.ctx.mvarEnv state1a.ctx.currentFreeVars callSubst canType
```

with:
```elm
-- Kernel call result MonoType must equal the kernel ABI's result type; the
-- ABI drives heap layout and codegen, and the enclosing canType can only
-- be less concrete (it may still carry MVars from a polymorphic wrapper).
resultMonoType =
    Mono.resultTypeOf funcMonoType
```

**Apply the identical change to `TOpt.VarDebug` arm** (`Specialize.elm:1566+`), which
mirrors the VarKernel logic (same `deriveKernelAbiType` + `callResultMonoType` pattern).

**Stated invariant (new):** For kernel and debug-kernel calls, the `MonoCall` result
type must be exactly `Mono.resultTypeOf funcMonoType`. Any test relying on the older,
weaker behavior (enclosing canType result) was implicitly relying on an inconsistent
view of the kernel's representation.

**Validation in `KernelAbi` / kernel type env**: confirm
`( "Parser", "findSubString" )` resolves to `UseSubstitution` mode and that the
canonical type stored in the kernel type env (populated by PostSolve) is the expected
`String -> Int -> Int -> Int -> String -> (Int, Int, Int)` with no free vars. If the
entry is missing or polymorphic, Part B alone will not fully close #8/#9 — must fix the
env first.

### Part C — Diagnostic attribute on `eco.project.tuple3` (optional)

In `Patterns.generateMonoPathHelper`'s `Mono.Tuple3Container` branch
(`Patterns.elm:446-491`), attach:

```elm
"mono.element_type" -> StringAttr Nothing (Mono.monoTypeToDebugString resultType)
```

to the `eco.project.tuple3` op's attribute dict. `monoTypeToDebugString` already exists
(`Monomorphized.elm:627`). This is debugging-only — it does not affect codegen behavior.

## Implementation steps

1. **Add helpers** `getValueMultiRootFromPath`, `rewriteRootInPath`, and
   `buildPartialContainer` to `Specialize.elm` near `getValueMultiVar` (~line 392).
   Start `buildPartialContainer` covering the common shapes:
   `Index + HintTuple2`, `Index + HintTuple3`, `Field`, `Unbox`. Leave
   `Index + HintCustom` and `ArrayIndex` to follow-up unless a test demands them;
   for the first implementation, fall back to the non-valueMulti path when
   `buildPartialContainer` encounters an unsupported shape.

2. **Rewrite `TOpt.Destruct` branch** (`Specialize.elm:2168-2202`) to branch on
   `getValueMultiRootFromPath`. Keep the non-valueMulti path byte-identical to today.
   Store `refinedSubst` into `ValueInstanceInfo` — not load-bearing today (the
   emission phase uses only `info.monoType` to build `mergedSubst`), but this keeps
   the most-refined subst available for any future extension.

3. **Swap `resultMonoType` in `TOpt.VarKernel` call arm** (`Specialize.elm:1558-1559`)
   to use `Mono.resultTypeOf funcMonoType`. Add a one-line comment tying to the new
   invariant.

4. **Apply the same swap to the `TOpt.VarDebug` call arm** (`Specialize.elm:1566+`).

5. **Verify `KernelAbi` classification of `Parser.findSubString`**: inspect the kernel
   type env (`KernelTypes.lookup`) and `deriveKernelAbiMode` for this identifier.
   Add explicit `numberBoxedKernels` / `alwaysPolymorphicModules` exclusions only if
   verification fails.

6. **(Optional) Attach `mono.element_type` debug attribute** to
   `Ops.ecoProjectTuple3` in `Patterns.generateMonoPathHelper`'s `Tuple3Container` arm.

7. **Test**:
   - Isolate the Issue #1 repro (the `LetDestructFuncTupleTest`-style case) and confirm
     the generated MLIR uses the concrete record MonoType in the update lambda.
   - Run `cmake --build build --target full` with `TEST_FILTER` scoped first to the
     parser/tuple3 tests (Issues #8/#9), then the broader E2E suite.
   - Re-run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` to catch any
     frontend regressions in Specialize.

## Invariants / safety

- **REP_BOUNDARY_001 / 002**: by making MonoTypes at destruct/kernel sites fully
  concrete sooner, heap and ABI layouts are guaranteed to match codegen decisions.
- **MONO_024 (no CEcoValue MVar in fully monomorphic specs)**: this change *reduces*
  MVar leakage, so invariant tests should strengthen, not weaken.
- **New invariant (kernel call result ≡ ABI result)**: for `TOpt.VarKernel` and
  `TOpt.VarDebug` calls, `MonoCall.resultType == Mono.resultTypeOf funcMonoType`.
- **No new passes**: all changes stay inside Monomorphize; GlobalOpt sees a
  MonoGraph where layout/ABI decisions are already consistent.

## Resolved questions / assumptions

### Q1 — Path shape and root rewriting — RESOLVED

`TOpt.Root` is always the leaf of every `TOpt.Path`. The type is inductive with `Root
Name` as the only non-recursive constructor (`Index … Path | ArrayIndex … Path | Field
… Path | Unbox Path | Root Name`). `specializePath` is written assuming that structure.
A helper that rewrites only the `Root` node and recurses structurally is sound.

### Q2 — Refinement direction in `unifyExtend` — RESOLVED (spec corrected)

The original sketch (`unifyExtend destrCanType destrMonoType0 subst`) would be a no-op
in the common case. The correct pattern mirrors `TOpt.Access`: build a **partial
container MonoType** from the path and unify the **root's canonical type** against it.
The container has the destructor's mono type at the leaf position and fresh `MVar`s
for sibling positions (for tuples / custom types). This pushes the learned constraints
back into the root's instantiation, including into nested lambdas. The plan's design
section has been updated to specify `buildPartialContainer` accordingly.

### Q3 — Multiple destructors sharing a root — RESOLVED

`updateValueMultiStack` keys instances by `Mono.toComparableMonoType monoType`. If two
destructors derive the *same* `rootInstanceMonoType`, they collapse to a single
instance with a single `freshName`. If they derive different MonoTypes (e.g., one
destructor refines more than the other), they get separate instances — not a
correctness problem, just potential code-size growth. In practice, because
`unifyExtend` walks all tuple/record positions when given the full container, both
destructors are likely to converge on the same fully concrete key once a few
destructors have run.

### Q4 — Body-level uses of the destructed root — RESOLVED (with caveat)

`Can.LetDestruct` lowers to a `TOpt.Let` binding plus a chain of `TOpt.Destruct` nodes
whose paths all root at that let variable; the body is wrapped inside the destructs.
Typical code doesn't also refer to the bound tuple/record directly after destructing.
**Caveat:** if a particular test shape *does* reference `pair` directly in the body
after destructuring, those uses will keep the preliminary MonoType and may reintroduce
layout mismatches. Eyeball the Issue #1 TOpt dump during implementation; if that
pattern appears, plan a follow-up to also rewrite direct `VarLocal` uses of the root
within the destruct scope.

### Q5 — `ValueInstanceInfo.subst` reuse — RESOLVED

Today, `info.subst` is not consulted by the emission phase — only `info.monoType` is
fed back into `unifyExtend` with `defCanType` to build `mergedSubst`. So whether we
pass `subst` or `refinedSubst` into `getOrCreateValueInstance` is observably the same
today. Store the **most refined** substitution (`refinedSubst`) for future-proofing;
mirror the record-access choice at `Specialize.elm:2297`.

### Q6 — `Parser.findSubString` kernel type env entry — VERIFY AT IMPLEMENTATION TIME

Part B depends on the kernel type env producing
`String -> Int -> Int -> Int -> String -> (Int, Int, Int)` for
`("Parser", "findSubString")` under `UseSubstitution` mode. The `KernelTypes` map was
not visible in the inspected excerpts. During implementation, dump
`KernelTypes.lookup ("Parser", "findSubString")` in a debug build and confirm. If the
entry is missing or polymorphic, fix the env first.

### Q7 — Regressions from always using ABI result type — RESOLVED

`callResultMonoType` can only be *less* specific than the ABI type (it may keep MVars
from a polymorphic wrapper); it cannot be more specific, because the ABI drives actual
heap layout and codegen for the kernel implementation. Switching the result type to
`Mono.resultTypeOf funcMonoType` is aligned with the existing ABI model and should be
treated as *the* source of truth. Any test depending on the older, weaker behavior
was implicitly relying on an inconsistent view and should be updated.

### Q8 — `TOpt.VarDebug` call arm — RESOLVED (apply the same change)

The `TOpt.VarDebug` arm mirrors `VarKernel`: `getOrBuildSchemeInfo` +
`unifyCallSiteDirect` + `deriveKernelAbiType` + `callResultMonoType`. Apply the
identical swap (use `Mono.resultTypeOf funcMonoType`) there for consistency.

### Q9 — Naming of the fresh destructor-triggered instance — RESOLVED

`updateValueMultiStack`: first instance gets the bare `defName`; subsequent get
`defName$v1`, `defName$v2`, etc. Whichever use site first triggers
`getOrCreateValueInstance` for a given `monoType` owns the plain `defName`. If a
destructor is first, it gets `pair` and later accesses with the same `monoType` reuse
that name — no collision.

### Q10 — Framing — RESOLVED

Title and framing updated: Part A is "extending the existing intra-pass deferral
machinery to destructured tuple paths"; Part B is "making kernel call result typing
follow the kernel ABI function type, avoiding loss of already-known concreteness."
Plan title reflects this: "Intra-Monomorphization Refinements" rather than "Deferrals".
