# Phase 8: Eliminate TypeSubst Fallbacks from MonoDirect

## Goal
MonoDirect must be a clean, solver-driven monomorphizer. It must never fall back to `TypeSubst` or the original monomorphization logic. All type/layout information must come from the HM solver snapshot and `Mono.forceCNumberToInt` (for numeric defaulting only).

This phase removes all remaining uses of `Compiler.Monomorphize.TypeSubst` in:
- `Compiler.MonoDirect.Monomorphize`
- `Compiler.MonoDirect.Specialize`

## Steps

### 8.1 Remove `resolveMainType` Fallback
**File:** `compiler/src/Compiler/MonoDirect/Monomorphize.elm`
**Change:** Replace `Nothing` branch (TypeSubst fallback) with `Utils.Crash.compilerBug`. Main always has a tvar after P1.

### 8.2 Remove `specializeDefineNodeFallback`
**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`
**Changes:**
1. Delete `specializeDefineNodeFallback` entirely
2. Replace `Nothing` branch in `specializeDefineNode` with `Utils.Crash.compilerBug`

### 8.3 Replace `resolveType` Fallback
**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`
**Change:** Replace `Nothing` branch (TypeSubst fallback) with `Utils.Crash.compilerBug`. Trivial/synthetic expressions (Unit, Shader) never call `resolveType`; they hard-code MonoType.

### 8.4 Destructor Path Types (Option A: Extend Destructor with Meta)
**Files:** Multiple

#### 8.4.1 Extend `TOpt.Destructor` to carry `Meta`
**File:** `compiler/src/Compiler/AST/TypedOptimized.elm`
- Change `Destructor Name Path Can.Type` → `Destructor Name Path Meta`
- Update encoder/decoder to use metaEncoder/metaDecoder

#### 8.4.2 Update Destructor construction sites
- `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`: Thread `ExprVars` into `destruct*` functions; construct Meta with tvar lookup
- `compiler/src/Compiler/LocalOpt/Typed/Port.elm`: Construct Meta with `tvar = Nothing` (synthetic)
- `compiler/src/Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm`: Update pattern match

#### 8.4.3 Update Destructor consumption sites
- `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`: Update `(TOpt.Destructor n _ t)` patterns to `(TOpt.Destructor n _ meta)` then use `meta.tipe`
- `compiler/src/Compiler/LocalOpt/Typed/Module.elm`: Same pattern update
- `compiler/src/Compiler/Monomorphize/Specialize.elm`: Same pattern update
- `compiler/src/Compiler/MonoDirect/Specialize.elm`: Use `resolveType view meta` instead of TypeSubst
- Test files: Update pattern matches

#### 8.4.4 Specialize Destructor Path Type via Solver
**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`
- `specializeDestructorPathType` becomes: `resolveType view meta`
- `specializeDestructor` uses `resolveType view meta` instead of TypeSubst

### 8.5 Kernel ABI Derivation: Replace TypeSubst with Solver-Aware Mapping
**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`
**Changes:**
1. Require `tvar` for kernels (crash on `Nothing`)
2. For `NumberBoxed` non-fully-mono: walk solver `canType` and map unresolved vars to `MVar _ CEcoValue` instead of using TypeSubst
3. For `PreserveVars` non-fully-mono: use `KernelAbi.canTypeToMonoType_preserveVars` (already solver-free, just walks Can.Type)
4. The `NumberBoxed` non-fully-mono case needs a solver-aware version that preserves number vars as CEcoValue

### 8.6 Delete `specializeExprWithSubst`
**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`
- Delete the function entirely (no remaining callers after 8.2)

### 8.7 Strip TypeSubst Imports from MonoDirect
- Remove `import Compiler.Monomorphize.TypeSubst as TypeSubst` from both MonoDirect files
- Verify Elm compiles with no remaining MonoDirect references to TypeSubst

## Key Design Decisions
- **Destructor approach:** Option A – extend `TOpt.Destructor` with `Meta` (carries `tvar`)
- **Kernel ABI:** For `NumberBoxed` non-mono case, use `KernelAbi.canTypeToMonoType_preserveVars` on the solver's `canType` (since `view.typeOf tvar` gives the un-defaulted type). This is equivalent since `canTypeToMonoType Dict.empty canType` with empty subst just maps vars to `MVar _ CEcoValue`.
- **All TypeSubst fallbacks:** Become `compilerBug` crashes. If they fire, fix upstream passes.

## Testing
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```
