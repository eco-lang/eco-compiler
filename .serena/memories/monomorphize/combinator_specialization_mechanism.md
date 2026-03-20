# Combinator Specialization Bug - Detailed Mechanism

## The Bug Case: B Combinator
```elm
k : forall a b. a -> b -> a
s : forall a b c. (a -> b -> c) -> (a -> b) -> a -> c
b = s (k s) k  -- should have type: (Int -> Int) -> (Int -> Int) -> Int -> Int
```

When applied as: `b square inc 4` where:
- `square : Int -> Int`
- `inc : Int -> Int`
- `4 : Int`

## Expected Type Resolution

The trailing `k` in `b = s (k s) k` should have type:
- From the call context: `k : (Int -> Int) -> (Int -> Int) -> Int -> Int`
  (This is what `s` expects for its second parameter)
- But `k`'s canonical type is: `k : a -> b -> a` (fully polymorphic)

At runtime, when `s (k s) k` evaluates with the applied arguments:
1. `k s` creates a PAP (partially applied function) that returns `s` when called with one more arg
2. `k` (the trailing reference) also creates a PAP

The trailing `k` receives **closure values** (PAPs representing `(Int -> Int)` functions), NOT plain `Int` values.

## Current Bug: Wrong Type Selection

The monomorphizer outputs:
```mlir
%5 = papCreate(k_$_6, arity=2)  -- WRONG: uses Int version of k
```

It should output:
```mlir
%5 = papCreate(k_$_8, arity=2)  -- CORRECT: uses eco.value version
```

Where:
- `k_$_6 : (i64, i64) -> i64`  -- the wrong specialization (for `k : Int -> Int -> Int`)
- `k_$_8 : (!eco.value, !eco.value) -> !eco.value`  -- the correct specialization

## Root Cause: Argument Type Derivation in processCallArgs

### Location: `/work/compiler/src/Compiler/Monomorphize/Specialize.elm`

When specializing a function call, the flow is:

```
specializeExpr (TOpt.Call func args) subst state
├─ processCallArgs args subst state
│  └─ For each arg:
│     ├─ If VarGlobal:
│     │  ├─ monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst argCanType)
│     │  ├─ if containsCEcoMVar monoType:
│     │  │    Defer as PendingGlobal
│     │  └─ else:
│     │       Specialize immediately as ResolvedArg
│     └─ Return (ProcessedArg, monoType)
├─ unifyCallSiteWithRenaming funcCanType argTypes canType subst
│  └─ Returns callSubst, funcMonoType, paramTypes
└─ resolveProcessedArgs processedArgs paramTypes callSubst
   └─ Refine deferred args with paramTypes
```

**The critical problem:** When `k` (a VarGlobal) is processed in `processCallArgs`:

1. Line 2381-2382: Compute monoType by applying **current subst** to `k`'s canonical type
   ```elm
   monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst argCanType)
   ```

2. The **current subst** at this point contains bindings from:
   - The outer let context where `b` is being defined
   - The call context where we're specializing `s (k s) k`

3. If `k`'s canonical type has type variables that are **already bound** in the current subst, those bindings are applied

### The Specific Issue in `b = s (k s) k`

When the monomorphizer starts specializing `b = s (k s) k`:

1. **Initial context:** `b` is being defined with type `(Int -> Int) -> (Int -> Int) -> Int -> Int`

2. **Specialization of RHS:** `s (k s) k` is specialized with an initial subst derived from `b`'s type

3. **Call to s:** The arguments are `[(k s), k]`
   - First arg `(k s)` is a Call expression → specialized via `specializeExpr`
   - Second arg `k` is a VarGlobal

4. **Processing trailing `k` in processCallArgs (line 2381-2382):**
   ```elm
   canType = k's canonical type  -- (a -> b -> a) or similar
   monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
   ```

5. **What is `subst` at this point?**
   - It contains bindings from the **let-binding context**
   - If the let context has inferred `k : Int -> Int -> Int` somewhere, those bindings apply
   - The monomorphizer may have already decided that `k` should be `Int -> Int -> Int`

6. **Critical mistake:** The `subst` used here is the **outer let subst**, not the **call-site subst**
   - The outer let may have constrained `k` based on one use site (e.g., `k square`)
   - But this doesn't mean `k` should be constrained that way when used in a different context

## The Correct Flow (What Should Happen)

The trailing `k` should use **parameter types from the unified call**, not pre-existing bindings:

1. **Defer k as PendingGlobal** if it has unresolved type vars
2. In `resolveProcessedArg` (line 2488-2503):
   ```elm
   PendingGlobal savedExpr savedSubst canType ->
       refinedSubst = case maybeParamType of
           Just paramType -> TypeSubst.unifyExtend canType paramType savedSubst
           Nothing -> savedSubst
       (monoExpr, st1) = specializeExpr savedExpr refinedSubst state
   ```

3. The **paramType** comes from the unified function call, not the outer context
4. The refined substitution properly constrains the parameter type

## Why It's Wrong Currently

**The VarGlobal case in processCallArgs (lines 2376-2398) has two behaviors:**

### Case A: If monoType contains CEcoValue (line 2384-2388)
```elm
if Mono.containsCEcoMVar monoType then
    ( PendingGlobal arg subst canType :: accArgs, monoType :: accTypes, st )
```
→ Deferred correctly, will use paramTypes later

### Case B: If monoType does NOT contain CEcoValue (line 2390-2398)
```elm
else
    ( monoExpr, st1 ) = specializeExpr arg subst st
    ( ResolvedArg monoExpr :: accArgs, Mono.typeOf monoExpr :: accTypes, st1 )
```
→ **SPECIALIZED IMMEDIATELY** without waiting for parameter type unification

**The bug:** In the B combinator case, `k` likely does NOT contain CEcoValue after applying the current subst (because the outer context has constrained its type), so it takes the immediate path.

The immediate specialization uses the **outer context's substitution**, which has the wrong bindings for this call site.

## Example Trace

Assume we're specializing:
```elm
let
  k = \a b -> a
  s = \bf uf x -> bf x (uf x)
  b = s (k s) k
in
  b square inc 4
```

With goal: `b : (Int -> Int) -> (Int -> Int) -> Int -> Int`

### Phase 1: Specialize b's definition

1. **Enter Let (b definition):**
   - Push localMulti entry for `b`
   - Specialize body `b = s (k s) k`

2. **Specialize Call `s (k s) k`:**
   - Current subst: empty or minimal (just from outer context)
   - processCallArgs sees two args: `(k s)` and `k`

3. **Process first arg `(k s)` (a Call):**
   - Specialized immediately via specializeExpr
   - Result type derived from call

4. **Process second arg `k` (a VarGlobal):**
   - `k`'s canonical type: `a -> b -> a` (fully polymorphic)
   - Apply current subst: `applySubst subst (a -> b -> a)` = no bindings → `a -> b -> a`
   - Check `containsCEcoMVar`: MVar a and MVar b both have CEcoValue → YES
   - **Should defer as PendingGlobal** ✓

5. **Unify call to s:**
   - s's canonical type: `(a -> b -> c) -> (a -> b) -> a -> c`
   - First arg mono type: something like `(Int -> Int -> Int) -> (Int -> Int) -> Int -> (Int -> Int)` (from `k s`)
   - Second arg mono type: `MVar a CEcoValue` → `MVar b CEcoValue` → `MVar a CEcoValue` (from k)
   - After unification: `a = Int -> Int`, `b = Int -> Int`, `c = Int`
   
6. **Resolve deferred k with new paramTypes:**
   - paramType from s's unified signature: `(Int -> Int) -> (Int -> Int) -> Int -> Int`
   - Unify `k`'s canonical `a -> b -> a` with param type
   - **Result:** `a = Int -> Int`, `b = Int -> Int`
   - **Specialize k with this refined subst**
   - **Get correct specialization: k : eco.value -> eco.value -> eco.value**

### What Actually Happens (The Bug)

If `k` reaches Case B (immediate specialization) before deferral:

1. Apply immediate subst to `k`: maybe some outer let context has bound `a = Int`, `b = Int`
2. Specialize immediately as `k : Int -> Int -> Int`
3. Get wrong specialization: `k_$_6 : (i64, i64) -> i64`
4. Later when resolving, it's too late - the wrong specialization is already enqueued

## The Fix Direction

**The issue is:** VarGlobal arguments with polymorphic types should **always defer** if they might need parameter-type refinement.

The condition on line 2384 should be:
```elm
if Mono.containsCEcoMVar monoType || containsUnresolvedFromCallContext then
    Defer
else
    Specialize immediately
```

But actually, **even simpler:** If any argument's type is polymorphic (has ANY MVar), defer it to let the call-site unification constrain it.

Or better yet: **All VarGlobal arguments with polymorphic canonical types should defer**, regardless of whether the current subst has resolved them.

---

## Files Involved

- `/work/compiler/src/Compiler/Monomorphize/Specialize.elm` (processCallArgs, resolveProcessedArg)
- `/work/compiler/src/Compiler/Monomorphize/TypeSubst.elm` (unifyCallSiteDirect, extractParamTypes)

## Key Functions

- `processCallArgs` (line 2268): Derives argTypes from current subst
- `resolveProcessedArg` (line 2420): Refines deferred args with paramTypes
- `TypeSubst.extractParamTypes` (line ~223): Extracts param types from unified function type
- `Mono.forceCNumberToInt`: Converts CNumber MVars to MInt
- `Mono.containsCEcoMVar`: Checks for polymorphic MVars

