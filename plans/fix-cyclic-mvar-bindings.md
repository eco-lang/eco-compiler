# Fix Cyclic MVar Bindings in Type Substitution

## Problem

The monomorphization type substitution can create cyclic MVar bindings (e.g., `a = MTuple [Global, MVar "a"]`), leading to infinite loops in `resolveMonoVarsHelp`. Three root causes:

1. **Shallow occurs check in `unifyHelp`**: The TVar branch only checks direct self-reference (`a = MVar "a"`), not structural containment (`a = MTuple [X, MVar "a"]`).
2. **Shallow `normalizeMonoType`**: Only normalizes bare MVars, leaving nested MVars unresolved inside composite types like `MTuple`, `MFunction`, etc.
3. **Non-unique `__callee` names**: `buildRenameMap` reuses `__callee0`, `__callee1`, etc. across different `unifyFuncCall` calls, causing distinct instantiations to collide.

## Changes

### 1. Structural occurs check in `unifyHelp` (TVar case)

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Add `monoTypeContainsMVar` helper that recursively checks if a MonoType contains an MVar with a given name. Replace the shallow `isSelfRef` check in the `( Can.TVar name, _ )` branch of `unifyHelp` with a call to `monoTypeContainsMVar`.

If the occurs check fails, skip the binding (return `subst` unchanged) to prevent creating cyclic types.

### 2. Deep `normalizeMonoType`

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Make `normalizeMonoType` recursive: walk into `MFunction`, `MList`, `MTuple`, `MRecord`, `MCustom` and normalize any nested MVars. Add `normalizeList` helper.

This ensures `insertBinding` stores fully-canonicalized types.

### 3. Globally unique `__callee` names via `renameEpoch`

**Files**:
- `compiler/src/Compiler/Monomorphize/State.elm` — add `renameEpoch : Int` to `MonoState`
- `compiler/src/Compiler/Monomorphize/TypeSubst.elm` — add `epoch` parameter to `unifyFuncCall` and `buildRenameMap`
- `compiler/src/Compiler/Monomorphize/Specialize.elm` — pass and bump `renameEpoch` at each `unifyFuncCall` call site

Fresh names become `name ++ "__callee" ++ epoch ++ "_" ++ counter`, ensuring uniqueness across calls.

### 4. Depth bail-out remains as defensive measure

The existing `Set Name` visited-set cycle detection in `resolveMonoVarsHelp` stays as a safety net but should no longer trigger once cyclic bindings are prevented.

## Order of Implementation

1. Add `monoTypeContainsMVar` + fix `unifyHelp` occurs check
2. Make `normalizeMonoType` recursive + add `normalizeList`
3. Add `renameEpoch` to `MonoState`, thread through `unifyFuncCall`/`buildRenameMap`/`Specialize.elm`
4. Run elm-test and E2E tests

## Test Verification

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```
