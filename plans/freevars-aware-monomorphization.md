# Plan: FreeVars-Aware Monomorphization

## Problem

With independent, MVarId-based TVars (post-`AssignMVarIds` fix), the monomorphizer has two correctness gaps:

1. **`callResultMonoType` applies the caller's substitution to the call expression's type**, which can produce wrong results now that MVarIds are unique per-scheme and no longer collide by name. The "try caller, fall back to callSubst" heuristic was a collision workaround — it's now actively harmful.

2. **`TypeSubst.applySubst` is used without scope restriction** — any MVarId binding in the substitution can affect any type, even if those MVarIds belong to a different scheme. This enables cross-scheme contamination.

## Design

Three structural changes, all localized to `TypeSubst.elm` and `Specialize.elm`:

### A. Scope-restricted substitution (`applySubstWithFreeVars`)
### B. FreeVars helper functions in Specialize.elm
### C. Simplified `callResultMonoType` using only callee's call-site substitution

---

## Step-by-Step Implementation Plan

### Step 1: Thread annotations into SpecContext

**Files:** `State.elm`, `Monomorphize.elm`

**Why:** The design requires `lookupFreeVarsFromCtx` to read `Can.Forall freeVars` from the current global's annotation. Currently, `SpecContext` has no `annotations` field — annotations from `GlobalGraph` are destructured and discarded at `Monomorphize.elm:69`.

**Changes:**
1. Add `annotations : TOpt.Annotations MVarId` field to `SpecContext` in `State.elm:142-152`
2. In `Monomorphize.elm`, capture the annotations from `AssignMVarIds.assignIds` result (currently pattern-matched as `_`) and pass them through to `SpecContext` initialization
3. Update `runSpecialization` and any context-building code to include annotations

**Risk:** Low — purely additive, no existing behavior changes.

---

### Step 2: Add `applySubstWithFreeVars` to TypeSubst.elm

**File:** `Compiler/Monomorphize/TypeSubst.elm`

**Changes:**
1. Add `applySubstWithFreeVars` to the module export list (line 2)
2. Implement the function near `applySubst` (after line 723):
   - Collect MVarIds from the input `canType` using existing `collectMVarIds`
   - Filter the substitution to only include bindings for those MVarIds
   - Call existing `applySubst` with the filtered substitution and empty MVarEnv
   - Return only the `MonoType` (discard updated MVarEnv)

**Signature:**
```elm
applySubstWithFreeVars : Can.FreeVars -> Substitution -> Can.Type MVarId -> Mono.MonoType
```

**Design decision (resolved):** The `Can.FreeVars` parameter (`Dict Name ()`) is passed for documentation/intent but the actual safety filtering is by `collectMVarIds canType` — i.e., only substitute MVarIds that appear in the type being transformed. This is sufficient because:
- Subst keys are MVarIds; any binding whose MVarId never appears in `canType` cannot affect the result
- MVarIds are globally unique post-AssignMVarIds, so filtering by ids-in-type prevents cross-scheme contamination
- The FreeVars parameter is retained for intent clarity and to support future tightening (e.g., intersecting with a Name→MVarId mapping)

---

### Step 3: Add FreeVars helper functions to Specialize.elm

**File:** `Compiler/Monomorphize/Specialize.elm`

**Changes:** Add three helper functions:

1. **`lookupFreeVars`** — given `Maybe TOpt.Global` and annotations dict, look up the `Can.Forall freeVars` for that global
2. **`lookupFreeVarsFromCtx`** — same but reads `currentGlobal` and `annotations` from `MonoState.ctx`
3. **`applySubstFV`** — wraps `TypeSubst.applySubstWithFreeVars` with automatic FreeVars lookup from context

**Depends on:** Step 1 (annotations in SpecContext)

---

### Step 4: Redefine `callResultMonoType`

**File:** `Compiler/Monomorphize/Specialize.elm`, lines 3361-3371

**Change:** Replace the 4-parameter version:
```elm
callResultMonoType : MVarEnv -> Substitution -> Substitution -> Can.Type MVarId -> Mono.MonoType
```
with a 3-parameter version:
```elm
callResultMonoType : Can.FreeVars -> Substitution -> Can.Type MVarId -> Mono.MonoType
```

The new version:
- Takes FreeVars (from the call expression's annotation scheme) instead of callerSubst
- Uses only callSubst (from `unifyCallSiteDirect`) to derive the result type
- Calls `TypeSubst.applySubstWithFreeVars` instead of raw `applySubst`
- Still applies `Mono.forceCNumberToInt` at the end

**Confirmed:** `callResultMonoType` is private to `Specialize.elm` (not exported; module only exports `specializeNode`). No external callers to update.

---

### Step 5: Update all `callResultMonoType` call sites

**File:** `Compiler/Monomorphize/Specialize.elm`

There are multiple call sites that currently pass `(state.ctx.mvarEnv, subst, callSubst, canType)`. Each must be updated to pass `(freeVars, callSubst, canType)`.

**Call sites to update:**

1. **Global calls** (around line 1256-1257): `callResultMonoType state.ctx.mvarEnv subst callSubst canType`
   → `callResultMonoType (lookupFreeVarsFromCtx state1a) callSubst canType`

2. **Kernel calls** (similar pattern in VarKernel branch, ~line 1290)

3. **Debug calls** (VarDebug branch, ~line 1315)

4. **Non-local function calls** (fallback branch, ~line 1400)

5. **Local multi-target calls** (lines ~1365-1380)

Each site: replace `state.ctx.mvarEnv, subst, callSubst` with `freeVars, callSubst` where `freeVars = lookupFreeVarsFromCtx stateN`.

---

### Step 6: Replace raw `applySubst` calls with `applySubstFV` for expression types

**File:** `Compiler/Monomorphize/Specialize.elm`

Replace instances of the pattern:
```elm
Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst state.ctx.mvarEnv subst canType))
```
with:
```elm
Mono.forceCNumberToInt (applySubstFV state subst canType)
```

#### Sites to convert (expressions in current global's scheme)

These all interpret `meta.tipe` for expressions within the current global's annotation scheme:

- **Literals:** Int, Float, Str type derivation (~lines 1003, 1018, 1025, 1045, 1065)
- **Tuples, Lists:** element type derivation
- **If/Case result types:** expression type specialization (~lines 1103, 1132, 1148, 1164, 1174, 1184)
- **Var types:** local variable type lookup (~lines 1075, 1078, 1081, 1084)
- **Let-bound defs:** def type specialization within the enclosing scheme (~lines 1526, 1649, 1709, 1745, 1859)
- **Function type specialization:** (~line 461, 490)
- **TailFunc return type:** (~line 946)
- **Record update record type:** (~line 2028, 2048, 2098, 2139, 2185)

#### Sites to leave on raw `applySubst` (callee-scheme or self-scheme)

- **`specializeNode` for Ctor/Enum/Define** (~lines 613, 629, 641, 850): operates on the node's own scheme with its own substitution — same scheme, no cross-contamination risk
- **`deriveKernelAbiType`** (~line 1284): operates on callee's `funcCanType` with callee's `callSubst` — same scheme by construction
- **`resolveProcessedArg` branches** for `AccessorArg`, `KernelArg` (~lines 2298, 2314): operate on callee-scheme types, not current global's scheme
- **`getOrBuildSchemeInfo` / `buildSchemeInfo` internals**: operate on callee schemes
- **`toptGlobalToMono` func type** (~line 3509): operates with `callSubst` on `canFuncType` in callee scheme
- **DtPath handling** (~lines 2995, 3062): uses `typeVarSubst` on callee argument types

#### Sites needing individual assessment

- **`resolveProcessedArg` branches** for `LocalFunArg` (~lines 2339, 2364, 2389): these operate on local function types. If the local shares the enclosing scheme (AssignMVarIds ensures this for same-binding locals), converting is correct. If the local has its own independent scheme, leave as-is.
- **Destructor path type** (~line 2784): uses `mvarEnv` and `subst` on `meta.tipe` — likely in current scheme, should convert
- **Local multi function calls** (~lines 2530, 2550, 2558): these are in-scope local calls, likely share the enclosing scheme

**Risk:** Medium — this is the highest-volume change. Each replacement must be validated to confirm the type being substituted belongs to the current global's scheme.

---

### Step 7: Adjust local multi-target path for scheme consistency

**File:** `Compiler/Monomorphize/Specialize.elm`, around lines 1355-1384

**Changes:**
1. Replace raw `applySubst` on `funcCanType` with `applySubstFV`:
   ```elm
   funcMonoType = Mono.forceCNumberToInt (applySubstFV state1 callSubst funcCanType)
   ```
2. Use new `callResultMonoType` with `freeVars` for result type

**Why this is correct:** Local helpers in the same HM binding share MVarIds with the parent (AssignMVarIds ensures this), so the enclosing function's FreeVars are the right scope. And since `applySubstWithFreeVars` filters by ids-in-type (not FreeVars), shared MVarIds from the parent will be correctly resolved.

---

### Step 8: Test

1. Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1 2>&1 | tee /tmp/test_output.txt` (compiler front-end)
2. Run `cmake --build build --target full 2>&1 | tee /tmp/e2e_output.txt` (E2E tests)
3. Check for:
   - Combinator tests (B, C, T) — no more spurious `i64` specializations
   - List/Bytes tests — element types preserved, no fallback to `!eco.value`
   - Numeric mismatches (i64 vs f64) should be reduced

---

## Resolved Design Decisions

### Q1: `Can.FreeVars` (`Dict Name ()`) vs MVarId-based filtering — RESOLVED

**Decision:** Option (a) — filter by MVarIds-in-type via `collectMVarIds`. This is sufficient because:
- Subst keys are MVarIds; bindings for MVarIds not in `canType` can't affect the result anyway
- Post-AssignMVarIds, MVarIds are globally unique per scheme, so ids-in-type is the right guardrail
- FreeVars parameter retained for documentation/intent; can be strengthened later with a Name→MVarId mapping

### Q2: Should `specializeNode` (Ctor/Enum/Define) use `applySubstFV`? — RESOLVED

**Decision:** No. These operate on the node's own scheme with its own substitution. Same scheme, no cross-contamination. Converting adds churn without correctness benefit.

### Q3: Should `deriveKernelAbiType` use `applySubstFV`? — RESOLVED

**Decision:** No. `funcCanType` and `callSubst` are in the same (callee) scheme by construction. Raw `applySubst` is correct and simpler.

### Q4: Is `callResultMonoType` private to Specialize.elm? — RESOLVED

**Decision:** Yes, confirmed. Module only exports `specializeNode`. No external callers to update.

### Q5: Is Step 1 (threading annotations) strictly necessary? — RESOLVED

**Decision:** Do it. Even though FreeVars isn't consumed by the filter today, threading annotations:
- Documents the intended contract (substitutions scoped to annotation binders)
- Provides a hook for future tightening (intersect collectMVarIds with scheme binders)
- Enables future invariant checks

### Q6: `resolveProcessedArg` paths — RESOLVED

**Decision:** Only convert `applySubst` calls where the type belongs to the current global's scheme. Leave callee-scheme calls (AccessorArg, KernelArg) as raw `applySubst`. Each of the ~57 sites must be individually assessed — see the triage in Step 6.

### Q7: Cycle specialization — RESOLVED

**Decision:** No special handling needed. AssignMVarIds processes cycle members with the same `Ctx`, so they share MVarIds where their types mention the same TVars. Since `applySubstWithFreeVars` filters by ids-in-type (not FreeVars), it will see all relevant MVarIds from co-recursive partners — shared ids appear in the type being substituted, so they pass the filter. Additionally, we're not planning to use `applySubstFV` inside `specializeNode` for Ctor/Enum/Define (per Q2), so this concern doesn't arise in the cycle cloning path.
