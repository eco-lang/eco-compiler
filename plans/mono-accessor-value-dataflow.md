# MonoAccessorValue: Introduction, Data-Flow Analysis, and Elimination

## Status: IN PROGRESS — Steps 1-3, 4a, 4b, 5 done; 4c needs context-rooted redesign

## Problem

Standalone accessor expressions (`TOpt.Accessor` not in call-argument position) are currently
specialized immediately via `Mono.Accessor` virtual globals, even when their record type may
contain `MVar`s (incomplete row variables). This produces invariant violations (MONO_012 arity
mismatch) and layout-incorrect code when the accessor flows through control structures.

The concrete failing pattern ("MONO_012 pattern") is case-selected accessors stored in a
record, later projected and called:

```elm
type Loc = First | Second

chooseRecFn loc rec =
    let
        ops =
            case loc of
                First ->
                    { getter = .a, setter = .b }
                Second ->
                    { getter = .b, setter = .a }
    in
    ( ops.getter rec
    , ops.setter rec
    )

testValue =
    chooseRecFn First { a = 10, b = 20 }
```

**Failure mode (manifests today):** Neither monomorphizer checks `containsAnyMVar` before
creating accessor globals. The canonical accessor type `.a : { a : Int | r } -> Int` is
specialized before the row variable `r` is bound, producing a `MonoType` with unresolved
pieces. `specializeAccessorGlobal` then either crashes (`expected MFunction [MRecord]
fieldType`) or creates a `MonoTailFunc` with 1 param whose `MonoType` encodes arity 2.
The MONO_012 invariant test catches this mismatch. This is a **live bug**, not latent.

## Goal

1. Introduce `MonoAccessorValue` as a tagged IR node for deferred accessor values.
2. Implement an intraprocedural data-flow analysis + rewrite pass that eliminates every
   `MonoAccessorValue` before GlobalOpt, either by inlining to `MonoRecordAccess` or
   converting to a context-rooted closure fallback.
3. Add invariant MONO_027: no reachable `MonoAccessorValue` in the final MonoGraph.

## Scope

- Intra-node analysis and transformations only.
- Inter-node behaviour (registry, worklist, etc.) stays as-is.
- Both `Specialize.elm` (old monomorphizer) and `MonoDirect/Specialize.elm` must be updated.
- One shared `ResolveAccessorValues` module operates on `MonoExpr` (post-specialization).

## Resolved Design Decisions

- **"MONO_012 pattern"** = the `chooseRecFn` idiom above (case-selected accessors in a
  record, later projected and called). Not the MONO_012 invariant text itself, but the
  program shape that violates it.
- **Worklist integration:** The elimination pass runs **per-node inside the worklist loop**
  (not as a post-pass), right after `specializeNode` produces a `MonoNode` and before
  insertion into `state.accum.nodes`.
- **Case-push duplication:** No size threshold for now — always perform the case-push when
  the pattern matches. Add a TODO for future size heuristic.
- **Downstream passes:** No pass requires accessor virtual globals to exist. Direct
  `MonoRecordAccess` is always acceptable.
- **Shared module:** One `Compiler.Monomorphize.ResolveAccessorValues` module shared by
  both monomorphizers.
- **MONO_027 is the next available number** (highest existing is MONO_026).

## Three-tier elimination strategy

All `MonoAccessorValue` nodes must be eliminated before the MonoGraph reaches GlobalOpt.
The strategy has three tiers, applied in order:

### Tier 1: Structural case/if-push rewrite

For the pattern where a case/if selects accessor values (in records **or tuples**), and
the destructured variables are only used as `var rec` calls, push the case/if down to the
uses and replace accessor calls with direct `MonoRecordAccess`.

Handles:
- Record-of-accessors: `let ops = case ... of { getter = .a, setter = .b } in ops.getter rec`
- Tuple-of-accessors: `let (get, set) = case ... of (.a, .b) in (get rec, set rec)`
- Mixed tuples: `let (get, set) = case ... of (.a, \x m -> {m|a=x}) in ...`
- 2-tuple and 3-tuple variants
- `MonoIf` as well as `MonoCase`
- Inline decider leaves (not just jumps)

### Tier 2: Data-flow analysis + call-site elimination

Forward intraprocedural analysis tracks which locals are definitely accessor values.
When a call's callee is a known accessor and its first argument has `MRecord` type,
inline to `MonoRecordAccess`.

Handles:
- Simple let-binding: `let f = .a in f rec`
- Record field tracking: `let r = { f = .a } in r.f rec`
- Multi-arg accessor calls: `.getter ops rec` → `MonoRecordAccess ops "getter" T` then
  re-analyze the resulting call

### Tier 3: Context-rooted closure fallback

**Key policy: never use the accessor's own `MonoType` to build the fallback closure.**
Only build a closure when we have a contextual, fully monomorphic expected function type
`MFunction [MRecord fields] fieldType`. Otherwise, leave the node as `MonoAccessorValue`;
if it remains reachable at the end, that's an invariant failure (MONO_027).

This is implemented by threading a `Maybe MonoType` ("expected type") down through the
data-flow rewrite. The expected type comes from:
- **Tuple elements:** `MonoTupleCreate` with `MTuple elemTypes` provides each element's type
- **Record fields:** `MonoRecordCreate` with `MRecord fieldTypes` provides each field's type
- **Let definitions:** `Mono.typeOf defExpr` provides the binding's type
- **If/Case branches:** `resultType` provides the expected type for each branch body
- **Node entry:** `nodeType` or `resultTypeOf nodeType` provides the top-level expected type

For `MonoAccessorValue`, the fallback logic:
```elm
MonoAccessorValue region fieldName accessorMonoType ->
    case maybeExpectedType of
        Just expectedType ->
            case maybeAccessorSigFromExpected expectedType of
                Just ( recordType, fieldType ) ->
                    -- SAFE: build closure from expected type, not accessorMonoType
                    MonoClosure
                        { lambdaId = fresh, captures = [], params = [("record", recordType)], ... }
                        (MonoRecordAccess (MonoVarLocal "record" recordType) fieldName fieldType)
                        expectedType

                Nothing ->
                    -- Expected type not safe: leave as MonoAccessorValue
                    expr

        Nothing ->
            -- No expected type: leave as MonoAccessorValue
            expr
```

Where `maybeAccessorSigFromExpected` checks:
```elm
maybeAccessorSigFromExpected : MonoType -> Maybe ( MonoType, MonoType )
maybeAccessorSigFromExpected expectedType =
    case expectedType of
        MFunction [ MRecord fields ] fieldType ->
            if not (containsAnyMVar (MRecord fields)) && not (containsAnyMVar fieldType) then
                Just ( MRecord fields, fieldType )
            else
                Nothing
        _ ->
            Nothing
```

This ensures closures are only built with fully monomorphic types — no `MVar CEcoValue`
in record fields or result type. The CGEN_005 failures are fixed because the closure's
record type comes from the container's concrete type, not the accessor's unresolved type.

After tier 3, assert MONO_027: no `MonoAccessorValue` in reachable expressions.

---

## Step-by-step Implementation Plan

### Step 1: Add `MonoAccessorValue` to the IR [DONE]

**Files:**
- `compiler/src/Compiler/AST/Monomorphized.elm`

**Changes:**
1. Add `MonoAccessorValue Region Name MonoType` variant to the `MonoExpr` type (after `MonoUnit`).
2. Add a case for `MonoAccessorValue` in `typeOf` that returns the attached `MonoType`.
3. Add cases in all exhaustive pattern matches over `MonoExpr` in this file.
4. Export `MonoAccessorValue` from the module.

### Step 2: Fix all exhaustiveness errors [DONE]

**Files:** Every module that pattern-matches on `MonoExpr` (13 source + 7 test files).

**Treatment:** `MonoAccessorValue` is a leaf (no sub-expressions). Pre-elimination passes
recurse/propagate; MLIR codegen crashes with a diagnostic message.

### Step 3: Change accessor introduction in `specializeExpr` [DONE]

**Files:**
- `compiler/src/Compiler/Monomorphize/Specialize.elm`
- `compiler/src/Compiler/MonoDirect/Specialize.elm`

**Changes:** Use `ResolveAccessorValues.accessorTypeNeedsDefer` to decide:
- First param not `MRecord` → defer (row variable unresolved)
- Result type is `MFunction` → defer (accessor extracts a function-typed field;
  `specializeAccessorGlobal` would produce arity mismatch)
- Otherwise → create `MonoVarGlobal` via `enqueueSpec` immediately

### Step 4: `ResolveAccessorValues` module

**File:** `compiler/src/Compiler/Monomorphize/ResolveAccessorValues.elm`

#### 4a: Record case-push [DONE]

Implemented for `MonoLet (MonoDef opsName (MonoCase ...))` with record-of-accessor branches.
Also handles inline decider leaves (not just jumps).

#### 4a-tuple: Tuple case-push [DONE]

Implemented for `MonoLet (MonoDef tupleVar (MonoCase/MonoIf ...))` followed by a
`MonoDestruct` chain. Handles 2-tuple, 3-tuple, mixed tuples, inline decider leaves.

#### 4b: Data-flow analysis and call-site elimination [DONE]

Implemented with `ValueInfo` lattice, conservative joins, call-site inlining.

#### 4c: Context-rooted closure fallback [TODO — redesign needed]

**Current state:** The existing fallback uses the accessor's own `MonoType` to build closures.
This produces closures with `MVar CEcoValue` types, causing CGEN_005 failures.

**Required change:** Redesign `rewriteExpr` to thread `Maybe MonoType` (expected type) and
use it for the closure fallback instead of the accessor's own type.

**API change:**
```elm
rewriteExpr : Env -> Maybe MonoType -> MonoExpr -> ( MonoExpr, ValueInfo )
```

**Expected type propagation rules:**

1. **MonoTupleCreate region elems (MTuple elemTypes):**
   Zip `elemTypes` with `elems`, pass each `elemType` as `Just elemType` to child rewrite.

2. **MonoRecordCreate fields (MRecord fieldTypes):**
   For each `(name, expr)`, look up `Dict.get name fieldTypes` and pass as expected type.

3. **MonoLet (MonoDef defName defExpr) body resultType:**
   Pass `Just (Mono.typeOf defExpr)` when rewriting `defExpr`.
   Pass `Just resultType` when rewriting `body`.

4. **MonoIf branches final resultType:**
   Pass `Nothing` for conditions, `Just resultType` for branch bodies and final.

5. **MonoCase _ _ decider jumps resultType:**
   Pass `Just resultType` for each jump expression and inline decider leaves.

6. **MonoCall:** Pass `Nothing` for all sub-expressions (no useful context).

7. **MonoClosure:** Pass `Nothing` for captures, pass `Just bodyResultType` for body
   (derived from closure type).

8. **Top-level entry (rewriteNode):**
   - `MonoDefine expr nodeType` → pass `Just nodeType`
   - `MonoTailFunc params body nodeType` → pass `Just (resultTypeOf nodeType)`

**Closure construction from expected type:**
```elm
maybeAccessorSigFromExpected : MonoType -> Maybe ( MonoType, MonoType )
maybeAccessorSigFromExpected expectedType =
    case expectedType of
        MFunction [ MRecord fields ] fieldType ->
            if not (containsAnyMVar (MRecord fields))
                && not (containsAnyMVar fieldType)
            then
                Just ( MRecord fields, fieldType )
            else
                Nothing
        _ ->
            Nothing
```

When `maybeAccessorSigFromExpected` succeeds, build:
```elm
MonoClosure
    { lambdaId = AnonymousLambda home counter
    , captures = []
    , params = [ ( "record", recordType ) ]
    , closureKind = Nothing
    , captureAbi = Nothing
    }
    (MonoRecordAccess (MonoVarLocal "record" recordType) fieldName fieldType)
    expectedType  -- use expected type, NOT accessor's own type
```

When it fails (no safe expected type), leave as `MonoAccessorValue` — caught by MONO_027.

#### 4d: MONO_027 assertion [TODO]

After tier 3, walk the expression tree. Crash on any surviving `MonoAccessorValue`.
This is the final safety net.

### Step 5: Wire the pass into the worklist loop [DONE]

**Files:**
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
- `compiler/src/Compiler/MonoDirect/Monomorphize.elm`

After `specializeNode` produces a `MonoNode`, call `ResolveAccessorValues.rewriteNode`
before inserting into `state.accum.nodes`. Passes `IO.Canonical` (module home) and
`lambdaCounter` through, updates counter in state.

### Step 6: Add MONO_027 invariant [TODO]

**Files:**
- `design_docs/invariants.csv`
- `compiler/tests/TestLogic/Monomorphize/`

### Step 7: Add targeted tests [TODO]

---

## Implementation status

| Step | Description | Status |
|------|-------------|--------|
| 1 | Add `MonoAccessorValue` to IR | DONE |
| 2 | Fix exhaustiveness errors | DONE |
| 3 | Change accessor introduction | DONE |
| 4a-record | Record case-push rewrite | DONE |
| 4a-tuple | Tuple case-push rewrite + inline decider leaves | DONE |
| 4b | Data-flow analysis + call-site elimination | DONE |
| 4c | Context-rooted closure fallback | TODO (redesign) |
| 4d | MONO_027 assertion | TODO |
| 5 | Wire into worklist loop | DONE |
| 6 | MONO_027 invariant in invariants.csv + test | TODO |
| 7 | Targeted tests | TODO |

## Test results after current implementation

**12332 passed / 11 failed** out of 12343 tests.

8 pre-existing failures (GOPT_013 x5, CGEN_056 x2, MONO_025 x1) — unrelated.

3 failures from this change (all CGEN_005 — projection layout bitmap):
- "Destruct tuple of accessors from case"
- "Accessor selected via case, stored in tuple"
- "If-selected accessors in tuple"

Root cause: The current closure fallback uses the accessor's own `MonoType` (which has
`MVar CEcoValue` fields) to build closures. The resulting `MonoRecordAccess` inside the
closure references `MRecord {a: MVar CEcoValue, b: MVar CEcoValue}`, which MLIR codegen
lowers to `!eco.value` fields, but the tuple layout bitmap marks them as unboxed (expecting
`i64`).

Fix: Step 4c redesign — thread expected types down through `rewriteExpr` and build closures
only from fully monomorphic contextual types.

Previous results (before tuple case-push): 12329 passed / 14 failed.
The 3 MONO_018 failures are now fixed by the tuple case-push + inline decider branch handling.

---

## Assumptions

1. The `ResolveAccessorValues` pass operates on `MonoExpr` (the monomorphized IR), not on
   `TOpt.Expr`. Both monomorphizers produce the same IR, so one shared module suffices.
2. The case-push rewrite is applied when the pattern is exact (all branches are record/tuple
   of accessors, all destructured-accessor uses are single-arg calls). Any deviation falls
   through to data-flow, then context-rooted closure fallback.
3. `PendingAccessor` / `resolveProcessedArg` / `finishProcessedArg` are **not modified** —
   the accessor-as-argument path is orthogonal and already correct.
4. The pass runs once per node, not iteratively — the lattice is finite and the analysis is
   forward-only, so one pass suffices.
5. No inter-procedural analysis is needed.
6. The closure fallback **never** uses the accessor's own `MonoType` for layout. It only uses
   fully monomorphic types from the surrounding context. If no safe context exists, the
   accessor remains as `MonoAccessorValue` and is caught by MONO_027.
