# TypeSubst & Specialize Performance Refactoring

## Goal

Reduce repeated type traversals and redundant work in the monomorphization type-substitution pipeline (`TypeSubst.elm` ~806 lines, `Specialize.elm` ~2932 lines) through 10 refactorings, ordered by priority. The existing union-find + changed-flag optimization (plan `typesubst-union-find-optimization.md`) is already implemented; this plan builds on top of it.

## Priority Order

Based on expected impact vs. cost, the implementation order is:

1. **Phase A** (highest value, moderate cost): Items 3, 2, 4
2. **Phase B** (high value, higher cost): Items 5, 6
3. **Phase C** (moderate value, invasive): Item 1
4. **Phase D** (robustness / micro-opt): Items 8, 9
5. **Phase E** (architectural): Item 10
6. **Phase F** (speculative, deferred): Item 7

---

## Phase A: Reduce Repeated Traversals and Renames

### Step A1: Precompute SchemeInfo per callee definition (Item 2)

**Files:** `State.elm`, `Specialize.elm`, `TypeSubst.elm`

Add a cached metadata record for each top-level polymorphic callee:

```elm
type alias SchemeInfo =
    { varNames    : List Name
    , constraints : Dict Name Mono.Constraint   -- constraintFromName pre-applied
    , argTypes    : List Can.Type                -- flattened from TLambda chain
    , resultType  : Can.Type                     -- innermost non-TLambda
    , argCount    : Int
    }
```

**Cache key:** `TOpt.Global`, using the existing comparable-key pattern (`TOpt.toComparableGlobal : TOpt.Global -> List String`), consistent with `toptNodes` and the specialization registry. Concretely:

```elm
-- in MonoState:
schemeCache : Data.Map.Dict (List String) TOpt.Global SchemeInfo
```

**Scope:** Top-level globals only (including all `TOpt.Def`/`TailDef`s in global cycles). Not cached for let-bound locals, since those are short-lived and the `localMulti` mechanism already caches specialization results per local def. Computing `SchemeInfo` on demand for locals is cheap (their `Can.Type` is right there in `specializeLambda`). Can extend to locals later if profiling shows benefit.

**Substeps:**

1. **Define `SchemeInfo`** in a new section of `TypeSubst.elm` (or a small `SchemeInfo.elm` if preferred).

2. **Add `buildSchemeInfo : Can.Type -> SchemeInfo`** in `TypeSubst.elm`:
   - Walk the `TLambda` chain once to extract `argTypes` and `resultType`.
   - Call `collectCanTypeVars` once to get `varNames`.
   - Pre-compute `constraints` via `constraintFromName` for each var name.

3. **Add `schemeCache` to `MonoState`** in `State.elm`. Populate on first encounter of each callee in `specializeNode`/`specializeFunc`.

4. **Wire into `unifyCallSiteWithRenaming`**: Accept `SchemeInfo` instead of raw `funcCanType`/`resultCanType`. Use `info.varNames` instead of `collectCanTypeVars funcCanType []`. Use `info.argTypes` for arg matching.

5. **Wire into `fillUnconstrainedCEcoWithErased`**: Use `info.varNames` directly instead of calling `collectCanTypeVars` again.

**Invariant:** Semantics unchanged — same var names, same types, just precomputed.

### Step A2: Single-pass call-site unifier (Item 3)

**Files:** `Specialize.elm` (primary), `TypeSubst.elm` (new function)

Currently `unifyCallSiteWithRenaming` does:
1. Rename callee vars -> `funcCanTypeRenamed`, `resultCanTypeRenamed`
2. `unifyArgsOnly` renamed scheme vs `argMonoTypes` -> `subst1`
3. `applySubst subst1 resultCanTypeRenamed` -> `desiredResultMono`
4. `resolveMonoVars subst1` each arg -> `resolvedArgTypes`
5. Build `desiredFuncMono = MFunction resolvedArgTypes desiredResultMono`
6. `unifyExtend funcCanTypeRenamed desiredFuncMono subst1` -- re-traverses entire function type

**Refactor:** Replace steps 2-6 with a single function:

```elm
unifyCallSiteDirect :
    SchemeInfo            -- already renamed
    -> List Mono.MonoType -- argMonoTypes from call site
    -> Substitution
    -> ( Substitution, Mono.MonoType )  -- (updated subst, funcMonoType)
```

This function:
- Walks `info.argTypes` and `argMonoTypes` in lockstep once, calling `unifyHelp` and simultaneously building the `MFunction` arg list.
- Applies `applySubst` on `info.resultType` to get the result mono type.
- Constructs `MFunction resolvedArgs resultMono` in one pass.
- Returns `(subst, funcMonoType)` -- no second `unifyExtend` pass needed.

**Substeps:**

1. Add `unifyCallSiteDirect` to `TypeSubst.elm`.
2. Update `unifyCallSiteWithRenaming` in `Specialize.elm` to use it.
3. The 5 call sites of `unifyCallSiteWithRenaming` (lines ~1010, ~1044, ~1072, ~1128, ~1157 in `Specialize.elm`) are unchanged since they go through that wrapper.

### Step A3: Pre-rename type variables per callee (Item 4)

**Files:** `Specialize.elm`, `TypeSubst.elm`

Currently, `buildRenameMap` runs on **every call**, generating fresh `name__calleeN_M` names.

**Design assumption:** Var name conflicts between caller and callee are **common** in practice (typical Elm uses short scheme vars like `a`, `b`, `msg` reused across definitions). The optimization here is not "usually skip rename" but rather "rename once per callee definition, not once per call site."

**Refactor:**

1. When building `SchemeInfo` for a callee, assign definition-scoped canonical names using the callee's identity:
   ```
   a -> a__def_<moduleName>_<defName>_0
   b -> b__def_<moduleName>_<defName>_1
   ```

2. Store the pre-renamed `Can.Type` (`renamedFuncType`, `renamedResultType`) and the rename map inside `SchemeInfo`.

3. At call sites, check whether the caller's substitution keys conflict with the callee's *canonical* names:
   - If no conflicts: use `SchemeInfo.renamedFuncType` directly.
   - If conflicts exist (e.g., recursive or nested polymorphism): fall back to `buildRenameMap` with a fresh epoch.

4. The `renameEpoch` counter in `MonoState` remains for the fallback path.

**Invariant:** Same semantics. The only difference is *which* fresh names are generated; unification is name-agnostic.

---

## Phase B: Merge Traversals and Cache Var Data

### Step B1: Merge occurs check with normalization (Item 5)

**Files:** `TypeSubst.elm`

Currently, `unifyHelp`'s TVar branch calls `monoTypeContainsMVar name monoType` (full traversal), and then (if inserting) `insertBinding` calls `normalizeMonoType` (another full traversal).

**Refactor:** Create `insertBindingSafe`:

```elm
insertBindingSafe : Name -> Mono.MonoType -> Substitution -> Substitution
```

This function does a **single** walk of `monoType`:
- Checks for cycles (if `name` appears in `monoType` -> skip binding, return `subst` unchanged).
- Normalizes MVars via `findRootVar` at the same time.
- Returns the updated substitution with the normalized binding inserted.

**Substeps:**

1. Add `insertBindingSafe` to `TypeSubst.elm` with a combined walk helper.
2. Replace the `monoTypeContainsMVar` + `insertBinding` sequence in `unifyHelp`'s TVar branch with a single `insertBindingSafe` call.
3. Keep `monoTypeContainsMVar` as an internal helper (or remove if no other callers -- check: it's exposed but only used in `unifyHelp`).
4. Keep `insertBinding` for non-TVar paths (in `unifyMonoMono` and record extension) where occurs check isn't needed.

### Step B2: Cache var names and constraints per scheme (Item 6)

**Files:** `TypeSubst.elm`

This is largely subsumed by Step A1 (`SchemeInfo` already caches `varNames` and `constraints`).

**Additional optimization:** Add a scheme-aware variant for `fillUnconstrainedCEcoWithErased` that uses `info.constraints` directly instead of calling `constraintFromName` per var:

```elm
fillUnconstrainedCEcoWithErasedFromScheme : SchemeInfo -> Substitution -> Substitution
fillUnconstrainedCEcoWithErasedFromScheme info subst =
    List.foldl
        (\name acc ->
            if Dict.member name acc then acc
            else
                case Dict.get name info.constraints of
                    Just Mono.CEcoValue -> Dict.insert name Mono.MErased acc
                    _ -> acc
        )
        subst
        info.varNames
```

---

## Phase C: First-Class Union-Find Data Structure (Item 1)

### Step C1: Replace `Substitution = Dict Name MonoType` with `MonoVarUF`

**Files:** `State.elm`, `TypeSubst.elm`, `Specialize.elm`, `Monomorphize.elm`, `Analysis.elm`

```elm
type alias MonoVarUF =
    { parents : Dict Name Name            -- UF parent (self = root)
    , ranks   : Dict Name Int             -- union by rank
    , binds   : Dict Name Mono.MonoType   -- only roots have entries
    }

type alias Substitution = MonoVarUF
```

**API approach:** Treat `Substitution` as **opaque** outside of `TypeSubst` and `State`. No "Dict-compatible" wrappers exposed broadly. Instead, audit each call site and ensure all external access goes through the existing TypeSubst API (`applySubst`, `unifyExtend`, `resolveMonoVars`, etc.) or narrow purpose-built accessors.

Rationale: Exposing generic `get`/`insert`/`member`/`keys` wrappers would encourage callers to treat `Substitution` as "just a Dict again," making it harder to evolve the UF representation. The goal is to shrink the surface area, not preserve it.

**Substeps:**

1. **Define `MonoVarUF`** in `State.elm` (replacing the current `Dict Name Mono.MonoType` alias).

2. **Add internal constructors/accessors** (in `TypeSubst.elm` or `State.elm`):
   - `emptySubst : Substitution`
   - `find : Name -> Substitution -> ( Name, Substitution )` -- path-compressing find
   - `union : Name -> Name -> Substitution -> Substitution` -- union by rank
   - `bind : Name -> Mono.MonoType -> Substitution -> Substitution` -- bind root to concrete type
   - `lookup : Name -> Substitution -> Maybe Mono.MonoType` -- find root, then check binds
   - `substKeys : Substitution -> List Name` -- for `callerVarNames` in `unifyCallSiteWithRenaming`
   - `substMember : Name -> Substitution -> Bool` -- for `fillUnconstrainedCEcoWithErased`

3. **Rewrite `TypeSubst.elm` internals:**
   - `findRootVar` -> delegates to `find` on `parents`
   - `insertBinding` -> calls `find` to get root, then inserts into `binds`
   - `normalizeMonoType` -> uses `find` for MVar, no longer needs to walk entire tree for variable normalization
   - `unifyHelp` TVar -> uses `union` + `bind`
   - `unifyMonoMono` MVar cases -> uses `union` + `bind`
   - `resolveMonoVars` -> uses `lookup` instead of `Dict.get`
   - `applySubst` TVar -> uses `lookup`

4. **Update callers** (audit each `Dict.*` call on substitution values):
   - `Specialize.elm`: Most of the ~70+ `TypeSubst.*` references go through the public API and need no change. Direct `Dict.get`/`Dict.insert`/`Dict.member`/`Dict.keys` on `subst` must migrate to the opaque accessors.
   - `Monomorphize.elm`: Single reference (`canTypeToMonoType`), delegates to `applySubst` -- no change.
   - `Analysis.elm`: Two references to `TypeSubst.applySubst` -- no change.

**Trade-off:** Most invasive change. Do only after Phase A and B are stable and profiling confirms `normalizeMonoType`/`resolveMonoVars` are still hot.

---

## Phase D: Stack Robustness and Micro-Optimizations

### Step D1: Work-list rewrites for deep recursions (Item 8)

**Files:** `TypeSubst.elm`

The recursions in `resolveMonoVarsHelp`, `normalizeMonoType`, and `unifyHelp` are bounded by type depth, which for real Elm programs is typically < 20.

**Known history:** The only documented depth issue is the mono bug investigation around `resolveMonoVarsHelp` recursing due to cyclic MVar bindings (missing occurs check + shallow normalization + renaming collisions). The current mitigations are: (a) occurs check via `monoTypeContainsMVar`, (b) deep `normalizeMonoType`, (c) `visiting` set cycle detection in `resolveMonoVarsHelp`, (d) depth>200 bail-out. No separate stack-overflow crash from normal (non-cyclic) type depth has been reported.

**Decision:** Defer. Fix the structural causes (occurs check, normalization, renaming -- Phases A-B) first. Only implement work-list rewrites if stack overflows are observed after those fixes are in place. CPS/trampolining in Elm would hurt performance due to closure allocation; explicit work-lists are the right approach if needed.

### Step D2: Fast paths for shallow types (Item 9)

**Files:** `TypeSubst.elm`

Add specialized fast paths:

1. **`unifyHelp`**: Fast-path for `(Can.TType ... [], MInt/MFloat/MBool/MChar/MString)` -- the primitive matches are already there but could be checked first with a single-branch match.

2. **`resolveMonoVarsHelp`**: Early exit for leaf types is already the `_ -> (False, monoType)` wildcard. This is fine.

3. **`unifyArgsOnly`**: 1-arg fast path (most common for curried Elm):
   ```elm
   ( Can.TLambda from to, [ singleArg ] ) ->
       ( unifyHelp from singleArg subst, to )
   ```

4. **`applySubst`**: The current code already handles all cases; the main optimization is avoiding `List.map (applySubst subst)` when args are empty (already handled by `isElmCore` branches returning directly for `"Int"`, `"Float"`, etc.).

**Decision:** Low-hanging fruit. Can be done independently of other phases.

---

## Phase E: Architectural Separation (Item 10)

### Step E1: Move call-site refinement logic into Specialize

**Files:** `Specialize.elm`, `TypeSubst.elm`

Currently TypeSubst contains call-site-aware logic (`unifyArgsOnly`, `extractParamTypes`, `fillUnconstrainedCEcoWithErased`) that is really Specialize's responsibility.

**Refactor direction:**
- TypeSubst becomes a pure "`Can.Type <-> MonoType` unifier + applier" with these public operations:
  - `unify : Can.Type -> MonoType -> Substitution -> Substitution`
  - `unifyExtend : Can.Type -> MonoType -> Substitution -> Substitution` (keep for non-call-site unification -- used by `specializeLambda`, function cycles, tail functions, ports)
  - `applySubst : Substitution -> Can.Type -> MonoType`
  - `resolveMonoVars : Substitution -> MonoType -> MonoType`
  - `insertBinding : Name -> MonoType -> Substitution -> Substitution` (or via UF API)

- Move to `Specialize.elm`:
  - `unifyArgsOnly` -> becomes a local helper in Specialize (it's a simple fold over `unifyHelp`)
  - `extractParamTypes` -> local to Specialize
  - `fillUnconstrainedCEcoWithErased` -> local to Specialize (uses `SchemeInfo`)
  - `collectCanTypeVars` -> part of `SchemeInfo` builder, can stay in TypeSubst or move

**Decision:** Do this after Phases A-B when the boundary is clearer.

---

## Phase F: Hash-Consing MonoTypes (Item 7)

### Step F1: Canonicalize MonoType structures

**Files:** `TypeSubst.elm` (or new `MonoTypeCache.elm`)

Introduce an integer-keyed interning table for `MonoType` nodes:

```elm
type alias MonoTypeIntern =
    { nextId   : Int
    , table    : Dict MonoTypeKey Int
    , byId     : Dict Int Mono.MonoType
    }
```

**Decision:** Skip unless profiling justifies it. No profiling data currently points at heavy time in `MonoType` construction/comparison. Elm's front end already reuses canonical types via module/type environments, providing decent sharing on the `Can.Type` side. Fixing the substitution representation and removing redundant traversals (Phases A-C) should be the first optimization steps. If post-Phase-C profiling shows `TypeSubst` is still a dominant cost with a lot of time in structural equality/comparison/duplication, revisit hash-consing then.

---

## Implementation Order Summary

| Order | Item | Description | Files touched | Risk |
|-------|------|-------------|--------------|------|
| 1 | A1 | SchemeInfo cache per global | State, TypeSubst, Specialize | Low |
| 2 | A2 | Single-pass call-site unifier | TypeSubst, Specialize | Medium |
| 3 | A3 | Pre-rename vars per callee | Specialize, TypeSubst | Medium |
| 4 | B1 | Merge occurs check + normalize | TypeSubst | Low |
| 5 | B2 | Cache constraints per scheme | TypeSubst | Low (mostly from A1) |
| 6 | D2 | Shallow-type fast paths | TypeSubst | Low |
| 7 | C1 | MonoVarUF data structure | State, TypeSubst, Specialize, Monomorphize, Analysis | High |
| 8 | E1 | Architectural separation | TypeSubst, Specialize | Medium |
| 9 | D1 | Work-list rewrites | TypeSubst | Low (deferred) |
| 10 | F1 | Hash-consing | TypeSubst + new | High (deferred) |

---

## Verification (all phases)

### Build
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

### E2E
```bash
cmake --build build --target check
```

### What to look for
- All existing tests pass (no behavioral changes at any phase).
- No new compiler warnings.
- Monomorphization of complex generic code (Dict, Array, Json.Decode, Platform.Sub) produces identical output.
- After Phase C (UF refactor): verify substitution key enumeration (used for `callerVarNames`) still works correctly via the new API.

---

## Resolved Design Decisions

### D1: SchemeInfo cache key
Key by `TOpt.Global` using the existing comparable-key pattern (`TOpt.toComparableGlobal`), consistent with `toptNodes` and the specialization registry. Concretely: `schemeCache : Data.Map.Dict (List String) TOpt.Global SchemeInfo`.

### D2: Var name conflict frequency
Treat conflicts between caller and callee type variable names as **common**, not rare. Typical Elm uses short scheme vars (`a`, `b`, `msg`) reused across definitions. The optimization in A3 is "rename once per callee definition, not once per call site" -- not "skip rename entirely." At call sites, cheaply check `List.member name callerVars` and skip when safe; fall back to `buildRenameMap` with fresh epoch when not.

### D3: SchemeInfo scope
Cache for top-level globals only initially. Local functions are short-lived, often monomorphic or single-use, and the `localMulti` mechanism already caches specialization results per local def. Computing `SchemeInfo` on demand for locals is cheap. Extend to locals only if profiling shows benefit.

### D4: MonoVarUF API surface
Treat `Substitution` as opaque outside TypeSubst and State. Audit each call site; migrate all direct `Dict.*` operations on substitutions to purpose-built accessors (`substKeys`, `substMember`, etc.) or the existing TypeSubst public API. Do not expose generic "Dict-compatible" wrappers, as this would encourage callers to bypass the UF representation.

### D5: `unifyExtend` retention
Keep `unifyExtend` as a separate entry point for non-call-site unification. Multiple sites depend on "extend existing subst with a new `canType ~ monoType` equality": `specializeLambda`, function cycles (`specializeFunc` with `sharedSubst`), tail function parameter refinement, and ports. `unify` remains the convenience wrapper for the fresh-subst case.

### D6: Stack safety (Item 8)
Defer work-list rewrites. The documented depth issue was caused by cyclic MVar bindings (missing occurs check + shallow normalization + renaming collisions), not by normal type depth. Current mitigations (occurs check, deep normalization, `visiting` set, depth>200 bail-out) are sufficient. Fix structural causes first (Phases A-B). Only implement work-lists if stack overflows are observed post-fix. CPS/trampolining would hurt performance in Elm due to closure allocation; explicit work-lists are the right approach if needed.

### D7: Hash-consing (Item 7)
Skip unless future profiling justifies it. No profiling data currently points at heavy time in `MonoType` construction/comparison. Fix substitution representation and redundant traversals first (Phases A-C), then profile. If `TypeSubst` is still a dominant cost with significant duplicate-type construction, revisit then.
