# Plan: Compile Value-Only Cycles as Separate MonoDefine Nodes

## Problem

Value-only recursive cycles (e.g., `typeDecoder`) are compiled via `Mono.MonoCycle` →
`generateCycle`, which wraps all cycle bindings in an `eco.construct.record`. This produces
a `Record(Custom(PAP))` at runtime instead of `Custom(PAP)`, causing type mismatches when
callers try to project fields from what they expect to be a Custom value.

## Goal

Compile each zero-arg binding in a value-only cycle as its own `Mono.MonoDefine` node (one
thunk per binding), eliminating the record wrapper. This mirrors how `specializeFunctionCycle`
handles mixed cycles: one `MonoNode` per function.

## Key Insight

Elm forbids direct recursive values — all allowed recursion goes through lambdas. So
value-only cycles don't need runtime fixpoint objects. Each binding's RHS is a finite
expression tree that can be compiled as a normal zero-arg thunk, with cross-references
resolved via `func.call` to the other thunks.

---

## Step-by-Step Plan

### Step 1: Replace `specializeValueOnlyCycle` in Specialize.elm

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

1a. **Change `specializeCycle`** to dispatch value-only cycles through `currentGlobal`,
    mirroring the function-cycle path:

    ```
    ( True, Just (Mono.Global canon name) ) -> specializeValueCycle canon name valueDefs requestedMonoType state
    ( True, Nothing )                        -> ( Mono.MonoExtern requestedMonoType, state )
    ( True, Just (Mono.Accessor _) )         -> crash (same as existing)
    ```

    The `( True, _ )` wildcard that ignores `currentGlobal` is replaced with explicit
    pattern matching.

1b. **Write `specializeValueCycle`** — new function that:
    - Finds the requested value's expression in `valueDefs`
    - Derives a `sharedSubst` via `TypeSubst.unify` of the expression's canonical type
      with `requestedMonoType` (same pattern as `specializeFunctionCycle`)
    - Folds over all `valueDefs` with a helper `specializeValueInCycle`, accumulating
      `(Dict SpecId MonoNode)` into `state.accum.nodes`
    - Returns the node for `requestedSpecId`

1c. **Write `specializeValueInCycle`** — helper that for each `(name, expr)`:
    - Creates `Global requestedCanonical name`
    - Applies `sharedSubst` via `TypeSubst.applySubst` to get `monoTypeFromExpr`
    - Uses `requestedMonoType` as the SpecId key for the requested binding, and
      `monoTypeFromExpr` for sibling bindings (same as `specializeFunc`)
    - Calls `Registry.getOrCreateSpecId` to get/create the SpecId
    - If SpecId already in `accNodes`, skips (dedup)
    - Otherwise: calls `specializeExpr expr sharedSubst state` to get `monoExpr`,
      creates `Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)`, inserts into `accNodes`

1d. **Delete `specializeValueOnlyCycle`** (now dead code).

### Step 2: Remove `MonoCycle` branch from MLIR generation

**File:** `compiler/src/Compiler/Generate/MLIR/Functions.elm`

2a. **Remove** the `Mono.MonoCycle definitions monoType -> ...` branch from
    `generateNodeInner` (lines ~165-171). With no producer of `MonoCycle`, this becomes
    dead code. Removing it ensures any accidental future `MonoCycle` fails loudly.

2b. **Optionally remove `generateCycle`** (lines ~1064-1113). It has no callers after 2a.
    Can be removed entirely or marked `-- DEPRECATED`.

### Step 3: Remove `MonoCycle` branch from MLIR Context

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

3a. Remove the `Mono.MonoCycle _ monoType -> ...` branch at line ~777 (used for type
    extraction). This is dead code after Step 1.

### Step 4: Leave downstream `MonoCycle` branches as dead code (lowest risk)

The following files have `MonoCycle` branches that will never be reached:

- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` (lines 328-337, 640-645, 2518)
- `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` (lines 147-162)
- `compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm` (line 95)
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` (lines 1064-1065, 1141-1148, 1534)
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` (lines 583, 633)
- `compiler/src/Compiler/Monomorphize/ResolveAccessorValues.elm` (lines 125-139)
- `compiler/src/Compiler/Monomorphize/Analysis.elm` (line 365)

**For this change:** leave them in place. They are harmless and removing them is a separate
cleanup task (would also involve removing `MonoCycle` from the `MonoNode` type union in
`Monomorphized.elm`).

### Step 5: Build and test

5a. Build: `cmake --preset ninja-clang-lld-linux && cmake --build build`
5b. Run frontend tests: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
5c. Run E2E tests: `cmake --build build --target full`
5d. Verify the Bytes decoder case no longer produces `eco.construct.record` wrapping

---

## Architecture Notes

### How cycle lookup works (critical context)

`addRecDefs` in `Module.elm` (line 555-585):
1. Creates synthetic `cycleName = Global home (Name.fromManyNames allNames)`
2. Registers each individual member as `TOpt.Link cycleName`
3. Registers the `TOpt.Cycle` node under `cycleName`

When the worklist processes member `typeDecoder`:
1. `currentGlobal` is set to `Just (Mono.Global canonical "typeDecoder")`
2. Looks up `toptNodes["typeDecoder"]` → finds `TOpt.Link cycleName`
3. `specializeNode` follows the Link → finds the `Cycle` node
4. Calls `specializeCycle` with `currentGlobal` still set to the individual name

So `currentGlobal` correctly identifies *which* binding we're specializing, even though
the `Cycle` node contains all bindings. This is the same mechanism `specializeFunctionCycle`
relies on.

### Substitution handling

- Current `specializeValueOnlyCycle` uses `Dict.empty` as substitution — no type
  unification with `requestedMonoType`. This works only if all types are already concrete.
- New `specializeValueCycle` will derive `sharedSubst` from `TypeSubst.unify`, ensuring
  polymorphic value cycles are correctly monomorphized. This mirrors `specializeFunctionCycle`.

### VarCycle references between cycle members

When member A references member B within a value-only cycle, the expression contains
`TOpt.VarCycle region canonical "B" meta`. During `specializeExpr`, this calls `enqueueSpec`
for B's `Global`, which adds B to the worklist. B will then be independently specialized
as another `MonoDefine` node. The `specializeValueInCycle` fold also pre-creates nodes for
all siblings, so B may already exist by the time the worklist reaches it (dedup via
`Dict.member specId accNodes`).

---

## Resolved Questions

### 1. Polymorphic value-only cycles (substitution change)

No existing tests exercise polymorphic value-only cycles. The front-end rejects "bad
recursion" on values, so any surviving value-only SCC has recursion going through lambdas.
Moving from `Dict.empty` to `unify`-derived `sharedSubst` mirrors `specializeFunctionCycle`
and is more principled.

**Action:** Optionally add a targeted test — a module with a polymorphic value-only cycle
specialized at two concrete types — and run MONO_024 to ensure no residual `CEcoValue` leaks.

### 2. Worklist dedup / overwriting pre-created nodes

`enqueueSpec` deduplicates **scheduling** via the `scheduled` bitset, but `processWorklist`
always does `Dict.insert specId monoNode nodes` (blind overwrite). This is already how
function cycles work: `specializeFunctionCycle` pre-creates nodes for all siblings, and the
main worklist may later recompute and overwrite them with equivalent nodes.

**Conclusion:** Redundant work, not semantically unsafe. Same pattern as function cycles.
No special handling needed.

### 3. Shared canonical for siblings

Confirmed. `Module.addRecDefs` builds all cycle members from a single `home : IO.Canonical`.
All bindings in a `TOpt.Cycle` share the same module. Using `requestedCanonical` for all
siblings matches `specializeFunctionCycle` exactly.

### 4. Alias maps for value expressions

Alias maps (`computeCycleDefAliasMap`, `computeDefAliasMap`) exist only for `TOpt.Def` /
`TOpt.TailDef` — i.e. for functions in cycles. Value defs are `(Name, TOpt.Expr)` and have
never used alias maps. `specializeValueOnlyCycle` today calls `specializeValueDefs` which
runs `specializeExpr expr subst` per value with no alias map involvement.

**Conclusion:** Not a concern. The switch from `Dict.empty` to `sharedSubst` doesn't
remove any aliasing behavior, because values never had alias maps. Type alias handling is
done upstream by `specializeExpr` + `applySubstFV`.

---

## Assumptions

- **Elm's recursion restriction holds**: All allowed value cycles have recursion only
  through lambdas, so no runtime fixpoint is needed. This is enforced by the front-end.

- **`currentGlobal` is always `Just (Mono.Global ...)` for value-only cycles**: Since
  value bindings are reached via `VarCycle` → `enqueueSpec` → worklist → `Link` →
  `specializeNode`, `currentGlobal` is always set. The `( True, Nothing )` case is a
  defensive fallback only.

- **All members of a value-only cycle share the same `IO.Canonical`**: Confirmed via
  `Module.addRecDefs` — single `home` for all members.

- **No downstream pass relies on `MonoCycle` semantics**: The optimization passes
  (`MonoInlineSimplify`, `Rewriter`, etc.) handle `MonoCycle` but don't require it — they
  simply won't encounter it anymore.

- **`generateDefine` already handles zero-arg values correctly**: It generates a normal
  zero-arg `func.func` that evaluates the expression and returns the result. No special
  handling needed for cycle members.
