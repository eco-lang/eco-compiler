# Refactor Call-Site Type Logic from TypeSubst to Specialize

## Goal

Move **call-site type unification orchestration** out of `Compiler.Monomorphize.TypeSubst` and into `Compiler.Monomorphize.Specialize`, so that:

- `TypeSubst` becomes a pure "canonical type <-> MonoType unifier + applier" with no call-site semantics.
- `Specialize` owns alpha-renaming callee schemes vs caller, combining caller/callee substitutions, and building the function MonoType used at the call site.

Concretely: remove `unifyFuncCall` (and its rename helpers) from `TypeSubst` and re-implement that behavior as a private helper in `Specialize`.

---

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/TypeSubst.elm` | Remove `unifyFuncCall`, `buildRenameMap`, `renameCanTypeVars`; expose `collectCanTypeVars`, `resolveMonoVars` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add private `buildRenameMap`, `renameCanTypeVars`, `unifyCallSiteWithRenaming`; update 4 call sites |

---

## Step 1: Update `TypeSubst` module header

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` lines 1-7

Change the exposing list from:
```elm
module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType
    , unify, unifyExtend, unifyFuncCall, unifyArgsOnly, extractParamTypes
    , fillUnconstrainedCEcoWithErased
    , monoTypeContainsMVar
    )
```

To:
```elm
module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType
    , unify, unifyExtend, unifyArgsOnly, extractParamTypes
    , fillUnconstrainedCEcoWithErased
    , monoTypeContainsMVar
    , collectCanTypeVars
    , resolveMonoVars
    )
```

Differences:
- **Remove**: `unifyFuncCall`
- **Add**: `collectCanTypeVars` (line 643), `resolveMonoVars` (line 522) — both already implemented, just not exposed

---

## Step 2: Delete `unifyFuncCall` from TypeSubst

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Delete the `unifyFuncCall` function definition (lines ~240-282) including its type annotation and doc comment.

The function currently:
1. Collects caller/callee type variables
2. Alpha-renames callee variables to avoid collisions (`buildRenameMap`, `renameCanTypeVars`)
3. Calls `unifyArgsOnly` to unify arguments
4. Applies the resulting substitution to the result type
5. Resolves MVars in argument types
6. Builds `desiredFuncMono = MFunction resolvedArgTypes desiredResultMono`
7. Calls `unifyHelp funcCanTypeRenamed desiredFuncMono subst1`

All of this is call-site policy that belongs in `Specialize`.

---

## Step 3: Delete `buildRenameMap` and `renameCanTypeVars` from TypeSubst

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Delete:
- `buildRenameMap` (lines ~683-697) — only used by `unifyFuncCall`
- `renameCanTypeVars` (lines ~703-743) — only used by `unifyFuncCall`

`collectCanTypeVars` (lines 644-676) stays — it's used by `fillUnconstrainedCEcoWithErased` (line 622) and will now be part of the public API.

---

## Step 4: Add rename helpers to Specialize

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add two private helpers near the top of the file (after the `ProcessedArg` type, before `processCallArgs`), moved verbatim from TypeSubst:

### `buildRenameMap`
```elm
buildRenameMap :
    Int
    -> List Name
    -> List Name
    -> Data.Map.Dict String Name Name
    -> Int
    -> Data.Map.Dict String Name Name
```
Lifted verbatim from TypeSubst lines 683-697.

### `renameCanTypeVars`
```elm
renameCanTypeVars : Data.Map.Dict String Name Name -> Can.Type -> Can.Type
```
Lifted verbatim from TypeSubst lines 703-743.

---

## Step 5: Add `unifyCallSiteWithRenaming` to Specialize

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add a private helper that replaces `TypeSubst.unifyFuncCall`, using only generic TypeSubst primitives:

```elm
unifyCallSiteWithRenaming :
    Can.Type
    -> List Mono.MonoType
    -> Can.Type
    -> Substitution
    -> Int
    -> ( Substitution, Can.Type )
unifyCallSiteWithRenaming funcCanType argMonoTypes resultCanType baseSubst epoch =
    let
        callerVarNames =
            Dict.keys baseSubst

        funcVarNames =
            TypeSubst.collectCanTypeVars funcCanType []

        renameMap =
            buildRenameMap epoch callerVarNames funcVarNames Data.Map.empty 0

        funcCanTypeRenamed =
            renameCanTypeVars renameMap funcCanType

        resultCanTypeRenamed =
            renameCanTypeVars renameMap resultCanType

        subst1 =
            TypeSubst.unifyArgsOnly funcCanTypeRenamed argMonoTypes baseSubst

        desiredResultMono =
            TypeSubst.applySubst subst1 resultCanTypeRenamed

        resolvedArgTypes =
            List.map (TypeSubst.resolveMonoVars subst1) argMonoTypes

        desiredFuncMono =
            Mono.MFunction resolvedArgTypes desiredResultMono
    in
    ( TypeSubst.unifyExtend funcCanTypeRenamed desiredFuncMono subst1
    , funcCanTypeRenamed
    )
```

Key: the final step uses `TypeSubst.unifyExtend` (which is `unifyHelp` — already exposed, lines 296-297) instead of calling `unifyHelp` directly.

---

## Step 6: Update 4 call sites in Specialize

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

All 4 call sites are simple mechanical replacements of `TypeSubst.unifyFuncCall` -> `unifyCallSiteWithRenaming`:

### 6a. `VarGlobal` branch (line 909-910)
```elm
-- Before:
TypeSubst.unifyFuncCall funcCanType argTypes canType subst epoch
-- After:
unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch
```

### 6b. `VarKernel` branch (line 943-944)
```elm
-- Before:
TypeSubst.unifyFuncCall funcCanType argTypes canType subst epoch
-- After:
unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch
```

### 6c. `VarDebug` branch (line 971-972)
```elm
-- Before:
TypeSubst.unifyFuncCall funcCanType argTypes canType subst epoch
-- After:
unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch
```

### 6d. Non-local fallback (line 1057-1058)
```elm
-- Before:
TypeSubst.unifyFuncCall funcCanType argTypes canType subst epoch
-- After:
unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch
```

**Not changed:** The local multi-target path (lines 1017-1045) — it deliberately uses `TypeSubst.unifyArgsOnly` directly without renaming, because local multi-target type variables are shared with the enclosing scope.

---

## Verification

The `Dict` import is already present in Specialize (line 32), so `Dict.keys` (used in `unifyCallSiteWithRenaming`) needs no new import. `Data.Map` is also already imported (line 30).

### Correctness argument

`unifyCallSiteWithRenaming` is semantically identical to `TypeSubst.unifyFuncCall` because:
- The body is the same logic in the same order
- The only difference is the final call: `unifyHelp x y z` (internal) vs `TypeSubst.unifyExtend x y z` (exposed) — and `unifyExtend` is defined as `unifyHelp` (line 296-297)

### Testing

```bash
# Front-end compiler tests:
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1

# Full E2E tests:
cmake --build build --target check
```

All existing monomorphization tests should pass unchanged, since this is a pure code-motion refactor with no semantic change.

---

## Questions / Risks

**Q: Are there any other consumers of `unifyFuncCall` outside these two files?**
A: No. `find_referencing_symbols` confirms it's only referenced in TypeSubst.elm (definition + exposing) and Specialize.elm (4 call sites).

**Q: Are `buildRenameMap` / `renameCanTypeVars` used anywhere else in TypeSubst?**
A: No. They're only called from `unifyFuncCall`.

**Q: Could exposing `collectCanTypeVars` / `resolveMonoVars` cause problems?**
A: No. They're pure functions with no side effects. They just become available for use from Specialize.
