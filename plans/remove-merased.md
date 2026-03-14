# Remove MErased from Monomorphization

## Background

`MErased` is a `MonoType` variant introduced to replace `MVar` in two cases:
1. **Dead-value specializations** (not value-used): all MVars erased to MErased
2. **Value-used specs with polymorphic key types**: only CEcoValue MVars erased (phantom type variables)

The erasure was always about flushing out bugs — it has no semantic effect because `MVar _ CEcoValue` and `MErased` both compile to `!eco.value` at every boundary (ABI, SSA operand, type table). The expensive tree-walking passes that convert MVar→MErased are unnecessary work.

## Plan

### Step 1: Remove the MErased variant from MonoType

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

- Remove `MErased` from the `MonoType` type definition (line ~222)
- Remove the comment block about MErased (lines ~200-206)
- Remove function `eraseTypeVarsToErased` (~line 319-330)
- Remove function `eraseTypeVarsToErasedHelp` (~line 337-401)
- Remove function `eraseCEcoVarsToErased` (~line 467-479)
- Remove function `eraseCEcoVarsToErasedHelp` (~line 486-553)
- Remove function `containsCEcoMVar` (~line 439-463)
- Remove `MErased` case from `toComparableMonoTypeHelper` (~line 1136)
- Remove `MErased` case from `monoTypeToString` (~line 913-914)
- Remove any helper functions only used by the erasure functions (e.g., `listMapChanged`, `dictMapChanged`) — but only if they have no other callers

### Step 2: Remove the erasure pass in Monomorphize.elm

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

The `assembleRawGraph` function performs key-type-aware erasure. Remove this entirely:

- Remove the 3-branch patching logic in `assembleRawGraph` (the `patchedNodes` computation, lines ~186-230ish):
  - Remove the `isValueUsed` / `keyHasCEcoMVar` / `patched` logic
  - Just store nodes directly without patching
- Remove the `patchedRegistry` computation that rebuilds the registry after erasure — no longer needed since node types don't change
- Remove functions:
  - `patchNodeTypesToErased` (~line 668)
  - `patchNodeTypesCEcoToErased` (~line 696)
  - `patchInternalExprCEcoToErased` (~line 723)
  - `eraseParamTypes` (~line 735ish)
  - `mapExprTypes` (~line 770)
  - `mapOneExprType` (~line 777-843)
  - `eraseExprTypeVars` (~line 852)
  - `eraseExprCEcoVars` (~line 863)
  - `mapDestructorTypes` (~line dependent)
  - `mapPathTypes` (~line dependent)

### Step 3: Remove MErased from TypeSubst.elm

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

- Remove `fillUnconstrainedCEcoWithErased` (~line 610)
- Remove `fillUnconstrainedCEcoWithErasedFromScheme` (~line 1190)
- Remove the MErased special-case in `bindTypeVar` (~lines 296-306) — the MErased-vs-concrete upgrade logic becomes dead code
- Remove any MErased handling in `applySubstHelp` if present

### Step 4: Remove MErased from Specialize.elm (Monomorphize)

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`

- Remove all calls to `TypeSubst.fillUnconstrainedCEcoWithErased`:
  - Line ~660-664 (Define branch)
  - Line ~686-688 (TrackedDefine branch)
  - Line ~1002-1004 (TailFunc branch)
- Remove the empty-list MErased fallback at line ~1274 — instead just use the unresolved type as-is (it has MVar _ CEcoValue which compiles identically)
- Remove `MErased` case from `isFullyResolved` (~line 3263-3265) — this was treating MErased as "resolved"; remove that case (the function will still work since `MVar _ CEcoValue` is already handled as not-fully-resolved, or we may need to treat `MVar _ CEcoValue` as resolved too since it's valid at codegen)
- Remove `eraseCEcoVarsToErased` call at line ~1275

### Step 5: Remove MErased from MonoDirect/Specialize.elm

**File**: `compiler/src/Compiler/MonoDirect/Specialize.elm`

- Remove the MErased crash guard at line ~2145-2152 (no longer possible)
- Remove the comment about MErased at line ~252

### Step 6: Remove MErased from downstream consumers

These all have `MErased ->` cases that can simply be removed (the `MVar _ CEcoValue` case already handles them identically):

- **`compiler/src/Compiler/Generate/MLIR/Types.elm`** (~line 238): Remove `Mono.MErased -> ecoValue` case. Already covered by the `_ -> ecoValue` fallthrough in `monoTypeToAbi`, and by the `MVar _ CEcoValue -> ecoValue` fallthrough in `monoTypeToOperand`. Actually in `monoTypeToOperand` we need to check: with MErased removed, unpatched `MVar _ CEcoValue` will hit the existing `MVar` case and produce `ecoValue`. Correct.

- **`compiler/src/Compiler/Generate/MLIR/Context.elm`** (~line 354): Remove `Mono.MErased -> []` case in type registration. `MVar _ _` case at line 351 already returns `[]`.

- **`compiler/src/Compiler/Generate/MLIR/TypeTable.elm`** (~line 255): Remove `Mono.MErased ->` case. The `MVar _ CEcoValue` case at line 250 handles the same logic.

- **`compiler/src/Compiler/GlobalOpt/Staging/GraphBuilder.elm`** (~line 674): Remove `Mono.MErased -> "Erased"` case. Add handling for `MVar` if not present, or let it fall through.

- **`compiler/src/Compiler/Type/SolverSnapshot.elm`** (~line 586): Remove `Mono.MErased -> freshFlexVar st` case. The `MVar _ _` case at line 589 handles identically.

### Step 7: Verify no references remain

Search the entire codebase for `MErased`, `eraseTypeVarsToErased`, `eraseCEcoVarsToErased`, `containsCEcoMVar`, `fillUnconstrainedCEcoWithErased`, `patchNodeTypesToErased`, `patchNodeTypesCEcoToErased`, `patchInternalExprCEcoToErased`, `eraseExprTypeVars`, `eraseExprCEcoVars` to ensure nothing was missed.

### Step 8: Update invariants and documentation

- Update `design_docs/invariants.csv` if any invariant references MErased
- Update `design_docs/theory/pass_monomorphization_theory.md` to remove MErased references
- Update `compiler/src/Compiler/AST/Monomorphized.elm` doc comments about MonoType
- Update THEORY.md if it references MErased

## Risk Assessment

**Low risk.** The key insight is that `MVar _ CEcoValue` and `MErased` produce identical output at every compilation boundary:
- ABI: both → `!eco.value`
- SSA operand: both → `!eco.value`
- Type table: both → polymorphic CEcoValue descriptor
- Layout/unboxing: both → boxed (not unboxable)
- Comparable key: both produce distinct but equivalent strings for registry lookup

The only subtle point is **spec key identity**: after removing erasure, spec keys will contain `MVar _ CEcoValue` instead of `MErased`. This changes the string representation used in `toComparableMonoType`. Since erasure was a post-processing step (after the registry was built), and `assembleRawGraph` was rebuilding the mapping anyway, removing both the erasure and the rebuild should be safe — the original MVar-containing keys were what the worklist used during specialization.

## Testing

1. `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` — frontend tests
2. `cmake --build build --target check` — full E2E tests
