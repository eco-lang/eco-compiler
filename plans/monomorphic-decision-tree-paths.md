# Plan: Monomorphic Decision-Tree Paths

## Goal

Replace `DT.Path` (untyped `TypedPath.Path`) inside `Mono.Decider` with a new typed `MonoDtPath` that carries `MonoType` at every segment. Route all MLIR codegen path navigation through the existing `generateMonoPath` machinery instead of `generateDTPath`. This fixes the `CaseSingleCtorBoolMultiTypeTest` MLIR parse failure ("use of value expects different type: i1 vs i64") caused by `findSingleCtorUnboxedField` guessing wrong on polymorphic single-constructor types.

---

## Step-by-step Plan

### Step 1: Add `MonoDtPath` type to `Compiler.AST.Monomorphized`

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

1a. Add a new type just above the `Decider` definition (~line 650):

```elm
type MonoDtPath
    = DtRoot Name MonoType
    | DtIndex Int ContainerKind MonoType MonoDtPath
    | DtUnbox MonoType MonoDtPath
```

This mirrors `MonoPath` but omits `MonoField` (not needed for decision-tree navigation, which only has Index/Unbox/Root).

1b. Add helper:

```elm
dtPathType : MonoDtPath -> MonoType
dtPathType path =
    case path of
        DtRoot _ ty -> ty
        DtIndex _ _ ty _ -> ty
        DtUnbox ty _ -> ty
```

1c. Update the module `exposing` list to export `MonoDtPath(..)` and `dtPathType`.

### Step 2: Change `Decider` to use `MonoDtPath`

**File**: `compiler/src/Compiler/AST/Monomorphized.elm`

Change (lines 650-653):

```elm
-- Before:
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)

-- After:
type Decider a
    = Leaf a
    | Chain (List ( MonoDtPath, DT.Test )) (Decider a) (Decider a)
    | FanOut MonoDtPath (List ( DT.Test, Decider a )) (Decider a)
```

This will cause compile errors everywhere `DT.Path` was expected inside Decider — those are the sites we need to update.

### Step 3: Add `specializeDtPath` to both Specialize modules

**Files**:
- `compiler/src/Compiler/Monomorphize/Specialize.elm`
- `compiler/src/Compiler/MonoDirect/Specialize.elm`

3a. Add a `specializeDtPath` function near `specializePath` in each file. The logic mirrors `specializePath` but produces `MonoDtPath` instead of `MonoPath`, and handles only `Index`/`Unbox`/`Root` (no `Field` or `ArrayIndex`):

```elm
specializeDtPath : VarEnv -> TypeEnv.GlobalTypeEnv -> Name -> TOpt.Path -> Mono.MonoDtPath
specializeDtPath varEnv globalTypeEnv rootName dtPath =
    case dtPath of
        TOpt.Index index hint subPath ->
            let
                monoSubPath = specializeDtPath varEnv globalTypeEnv rootName subPath
                containerType = Mono.dtPathType monoSubPath
                resultType = computeIndexProjectionType globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.DtIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.Unbox subPath ->
            let
                monoSubPath = specializeDtPath varEnv globalTypeEnv rootName subPath
                containerType = Mono.dtPathType monoSubPath
                resultType = computeUnboxResultType globalTypeEnv containerType
            in
            Mono.DtUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty -> ty
                        Nothing -> Utils.Crash.crash ("specializeDtPath: Root variable '" ++ name ++ "' not found in VarEnv.")
            in
            Mono.DtRoot name rootType

        TOpt.Field _ _ ->
            Utils.Crash.crash "specializeDtPath: Field not expected in decision-tree paths"

        TOpt.ArrayIndex _ _ ->
            Utils.Crash.crash "specializeDtPath: ArrayIndex not expected in decision-tree paths"
```

The two files differ in parameter threading (Monomorphize uses `state.ctx.varEnv`, MonoDirect uses `state.varEnv` and takes `LocalView`). Adapt signatures accordingly:

- **Monomorphize**: `specializeDtPath : VarEnv -> TypeEnv.GlobalTypeEnv -> Name -> TOpt.Path -> Mono.MonoDtPath`
  - Called with `state.ctx.varEnv` and the `globalTypeEnv` from context/state.
- **MonoDirect**: `specializeDtPath : VarEnv -> TypeEnv.GlobalTypeEnv -> Name -> TOpt.Path -> Mono.MonoDtPath`
  - Called with `state.varEnv` and `view.globalTypeEnv`.

Note: The `rootName` is not used for the actual path — the root name comes from `TOpt.Root name`. The rootName parameter is only for error messages.

**IMPORTANT**: DT.Path `Root` nodes carry their own variable name. The `rootName` from MonoCase is a good debug reference but the actual root should come from the `TOpt.Root name` match. Verify that DT.Path always terminates at `Empty` (the "root") vs `TOpt.Path` terminating at `Root name`. These are different path types:
- `TOpt.Path` (from `TypedOptimized`) has `Root Name` as its base.
- `DT.Path` (from `DecisionTree.TypedPath`) has `Empty` as its base — it doesn't carry the root name.

This means we need to handle this differently. The DT.Path/TypedPath path is relative to an implicit root (the scrutinee). We need to walk `DT.Path` outward, building `MonoDtPath` starting from `DtRoot rootName rootType`:

```elm
specializeDtPath : VarEnv -> TypeEnv.GlobalTypeEnv -> Name -> DT.Path -> Mono.MonoDtPath
specializeDtPath varEnv globalTypeEnv rootName dtPath =
    let
        rootType =
            case State.lookupVar rootName varEnv of
                Just ty -> ty
                Nothing -> Utils.Crash.crash ("specializeDtPath: Root '" ++ rootName ++ "' not in VarEnv")

        go : DT.Path -> Mono.MonoDtPath
        go path =
            case path of
                DT.Empty ->
                    Mono.DtRoot rootName rootType

                DT.Index index hint subPath ->
                    let
                        monoSubPath = go subPath
                        containerType = Mono.dtPathType monoSubPath
                        resultType = computeIndexProjectionType globalTypeEnv hint (Index.toMachine index) containerType
                    in
                    Mono.DtIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

                DT.Unbox subPath ->
                    let
                        monoSubPath = go subPath
                        containerType = Mono.dtPathType monoSubPath
                        resultType = computeUnboxResultType globalTypeEnv containerType
                    in
                    Mono.DtUnbox resultType monoSubPath
    in
    go dtPath
```

Note: `DT.Path` uses `DT.Index DT.Index.ZeroBased DT.ContainerHint DT.Path` and `DT.Unbox DT.Path` and `DT.Empty`. The import alias differs between the two Specialize files — verify exact constructor names.

### Step 4: Update `specializeDecider` in both Specialize modules

**Files**:
- `compiler/src/Compiler/Monomorphize/Specialize.elm` (line ~3006)
- `compiler/src/Compiler/MonoDirect/Specialize.elm` (line ~2031)

4a. Add `rootName : Name` as a parameter to `specializeDecider`:

- **Monomorphize**: `specializeDecider : Name -> TOpt.Decider TOpt.Choice -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )`
- **MonoDirect**: `specializeDecider : Name -> LocalView -> SolverSnapshot -> TOpt.Decider TOpt.Choice -> MonoDirectState -> ( Mono.Decider Mono.MonoChoice, MonoDirectState )`

4b. In the `Chain` branch, map each `(path, test)` through `specializeDtPath`:

```elm
TOpt.Chain testChain success failure ->
    let
        monoTestChain =
            List.map
                (\( path, test ) ->
                    ( specializeDtPath state.ctx.varEnv globalTypeEnv rootName path, test )
                )
                testChain
        ...
    in
    ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )
```

4c. In the `FanOut` branch, specialize the single path:

```elm
TOpt.FanOut path edges fallback ->
    let
        monoPath =
            specializeDtPath state.ctx.varEnv globalTypeEnv rootName path
        ...
    in
    ( Mono.FanOut monoPath monoEdges monoFallback, state2 )
```

4d. Pass `rootName` through recursive calls to `specializeDecider`.

4e. Update `specializeEdges` in Monomorphize (line ~3063) to also accept and pass through `rootName`.

### Step 5: Update MonoCase construction sites

**Files**:
- `compiler/src/Compiler/Monomorphize/Specialize.elm` (line ~504)
- `compiler/src/Compiler/MonoDirect/Specialize.elm` (line ~504)

At the `TOpt.Case scrutName label decider jumps meta ->` branch, pass `label` (the second Name = rootName, see Q1 resolved) into `specializeDecider`:

```elm
( monoDecider, state1 ) =
    specializeDecider label decider subst state   -- Monomorphize
    -- or: specializeDecider label view snapshot decider state  -- MonoDirect
```

`MonoCase unused rootName decider ...` — the second Name (`label` at the construction site) is the root scrutinee variable, confirmed by `MonoInlineSimplify.substitute`.

### Step 6: Add `generateMonoDtPath` adapter in Patterns.elm

**File**: `compiler/src/Compiler/Generate/MLIR/Patterns.elm`

6a. Add a function that converts `MonoDtPath` to `MonoPath` and delegates to `generateMonoPath`:

```elm
generateMonoDtPath : Ctx.Context -> Mono.MonoDtPath -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateMonoDtPath ctx dtPath targetType =
    let
        toMonoPath : Mono.MonoDtPath -> Mono.MonoPath
        toMonoPath p =
            case p of
                Mono.DtRoot name ty -> Mono.MonoRoot name ty
                Mono.DtIndex idx kind resultTy sub -> Mono.MonoIndex idx kind resultTy (toMonoPath sub)
                Mono.DtUnbox resultTy sub -> Mono.MonoUnbox resultTy (toMonoPath sub)
    in
    generateMonoPath ctx (toMonoPath dtPath) targetType
```

6b. Add a new `generateTest` variant that takes `MonoDtPath` instead of `(DT.Path, DT.Test)`:

```elm
generateMonoTest : Ctx.Context -> ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
generateMonoTest ctx ( dtPath, test ) =
    let
        targetType = ... -- same logic as existing generateTest
        ( pathOps, valVar, ctx1 ) = generateMonoDtPath ctx dtPath targetType
    in
    -- rest identical to existing generateTest
```

6c. Add a new `generateMonoChainCondition` that uses `MonoDtPath`:

```elm
generateMonoChainCondition : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
```

Note: None of the new functions take `root : Name.Name` — the root is embedded in `MonoDtPath` (see Q3 resolved).

6d. Update the module `exposing` list to export the new functions.

### Step 7: Update MLIR codegen consumers in Expr.elm

**File**: `compiler/src/Compiler/Generate/MLIR/Expr.elm`

7a. Update `generateDeciderWithJumps` (line 3575):
- `Mono.Chain testChain ...` → `testChain` is now `List (MonoDtPath, DT.Test)`, not `List (DT.Path, DT.Test)`.
- `Mono.FanOut path ...` → `path` is now `MonoDtPath`, not `DT.Path`.

7b. Update `generateChainWithJumps` (line 3723):
- Pattern match on `[ ( dtPath, Test.IsBool True ) ]` — `dtPath` is now `MonoDtPath`.
- Call `Patterns.generateMonoDtPath ctx dtPath I1` instead of `Patterns.generateDTPath ctx root path I1`.
- Remove the `root` parameter from this function's signature.

7c. Update `generateChainGeneralWithJumps` (line 3772):
- Call `Patterns.generateMonoChainCondition ctx testChain` instead of `Patterns.generateChainCondition ctx root testChain`.
- Remove `root` parameter from this function's signature.

7d. Update `generateBoolFanOutWithJumps` (line 3873):
- Call `Patterns.generateMonoDtPath ctx path I1` instead of `Patterns.generateDTPath ctx root path I1`.
- Remove `root` parameter from this function's signature.

7e. Update `generateFanOutGeneralWithJumps` (line 3913):
- Call `Patterns.generateMonoDtPath ctx path scrutineeType` instead of `Patterns.generateDTPath ctx root path scrutineeType`.
- Remove `root` parameter from this function's signature.

7f. Remove `root` from `generateDeciderWithJumps` (line 3575) and all callers:
- Per Q3 resolved: once `MonoDtPath` embeds the root, the separate `root : Name` parameter is redundant and should be removed in the same patch to prevent drift.
- `generateDeciderWithJumps` no longer needs `root` — it just dispatches to Chain/FanOut/Leaf handlers.
- Leaf handlers don't use `root` at all (confirmed: `generateLeafWithJumps` binds `root` as `_`).
- Update all call sites of `generateDeciderWithJumps` (both external callers and recursive calls within Chain/FanOut handlers).

### Step 8: Update MLIR codegen consumers in TailRec.elm

**File**: `compiler/src/Compiler/Generate/MLIR/TailRec.elm`

8a. Update `compileCaseChainStep` (line 569):
- `testChain` is now `List (MonoDtPath, DT.Test)`.
- Call `Patterns.generateMonoChainCondition ctx testChain` instead of `Patterns.generateChainCondition ctx root testChain`.
- Remove `root` parameter from function signature.

8b. Update `compileCaseFanOutStep` (line 680):
- `path` is now `MonoDtPath`.
- Call `Patterns.generateMonoDtPath ctx path scrutineeType` instead of `Patterns.generateDTPath ctx root path scrutineeType`.
- Remove `root` parameter from function signature.

8c. Update `compileCaseDeciderStep` (line 520):
- Remove `root` parameter — it was only forwarded to `compileCaseChainStep` and `compileCaseFanOutStep`.
- Update all callers of `compileCaseDeciderStep` accordingly.

### Step 9: Update all structural-traversal consumers

These are the ~20 functions classified as "(a)" that pass `DT.Path` through unchanged. They need to change their type signatures/pattern matches from `DT.Path` to `Mono.MonoDtPath`, but the logic is purely mechanical — just pass the new type through.

**Files to update** (each just adjusts the type in pattern match, no logic change):

1. `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`:
   - `rewriteDecider` (line 910)
   - `substituteDecider` (line 1306)
   - `simplifyLetsDecider` (line 1832)
   - `countUsagesInDecider` (line 2142)
   - `inlineVarInDecider` (line 2305)

2. `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`:
   - `collectFromDecider` (line 201)
   - `processDeciderForAbi` (line 316)
   - `annotateDeciderCalls` (line 1272)

3. `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`:
   - `rewriteDecider` (line 445)

4. `compiler/src/Compiler/Monomorphize/MonoTraverse.elm`:
   - `mapDecider` (line 66)
   - `traverseDecider` (line 136)
   - `foldDeciderAccFirst` (line 239)

5. `compiler/src/Compiler/Monomorphize/Analysis.elm`:
   - `collectCustomTypesFromDecider` (line 239)

6. `compiler/src/Compiler/Monomorphize/Closure.elm`:
   - `collectDeciderFreeLocals` (line 398)
   - `collectDeciderVarTypes` (line 548)
   - `collectCaseRootTypesFromDecider` (line 661)
   - `inferRootTypeFromDecider` (line 685) — **SPECIAL**: uses `isEmptyPath`. Change to check `DtRoot`:
     ```elm
     isRootPath : Mono.MonoDtPath -> Bool
     isRootPath p = case p of
         Mono.DtRoot _ _ -> True
         _ -> False
     ```

7. `compiler/src/Compiler/Monomorphize/Specialize.elm`:
   - `inferFromDecider` (line 2216) — path-agnostic, structural only (Q5 resolved)
   - `renameTailCallsDecider` (line 3453) — does NOT touch paths, only choices (Q4 resolved); just update the type in pattern match

8. `compiler/src/Compiler/MonoDirect/Specialize.elm`:
   - `renameTailCallsDecider` (line 1419) — same as above, path-agnostic
   - `firstLeafType` (line 2401)

### Step 10: Update test files

**Files**:
1. `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions.elm` — `checkDecider` (line 374)
2. `compiler/tests/TestLogic/Monomorphize/MonoCaseBranchResultType.elm` — `checkDecider` (line 213)
3. `compiler/tests/TestLogic/Monomorphize/FullyMonomorphicNoCEcoValue.elm` — `checkDeciderAllTypes` (line 265)
4. `compiler/tests/TestLogic/Monomorphize/MonoDirectComparisonTest.elm` — `compareDecider` (line 1450)
5. `compiler/tests/TestLogic/Generate/MonoGraphIntegrity.elm` — `checkDeciderLocalVarScoping` (line 743)
6. `compiler/tests/TestLogic/Generate/MonoFunctionArity.elm` — `collectDeciderArityIssues` (line 306)

These all pattern-match on `Mono.Chain`/`Mono.FanOut`. Most just recurse structurally and won't need logic changes beyond updating the type in their pattern bindings (the path variable changes from `DT.Path` to `Mono.MonoDtPath`).

### Step 11: Remove dead code from Patterns.elm

**File**: `compiler/src/Compiler/Generate/MLIR/Patterns.elm`

11a. Remove `generateDTPath` (line 518) and `generateDTPathHelper` (line 530).
11b. Remove `findSingleCtorUnboxedField` (line 450).
11c. Remove `lookupFieldInfoByCtorName` (line 412) — only used by DT.Path codegen.
11d. Remove `generateTest` (old version, line 826) — replaced by `generateMonoTest`.
11e. Remove `generateChainCondition` (old version, line 1030) — replaced by `generateMonoChainCondition`.
11f. Update module `exposing` list to remove deleted exports and add new ones.

### Step 12: Remove unused DT.Path imports

After all the above, many files will no longer need to import `DecisionTree.TypedPath`. Remove stale imports from:
- `Patterns.elm` (may still need `Test` import)
- `Expr.elm`
- `TailRec.elm`
- `Closure.elm` (if `DT` alias is fully unused)
- Any other file that no longer references `DT.Path`

### Step 13: Build and test

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```

The key regression test is `CaseSingleCtorBoolMultiTypeTest.elm` which should now pass without the "i1 vs i64" type mismatch.

### Step 14: Add TOPT_006 — UnboxPathGroundType invariant test

**New files**:
- `compiler/tests/TestLogic/LocalOpt/UnboxPathGroundType.elm`
- `compiler/tests/TestLogic/LocalOpt/UnboxPathGroundTypeTest.elm`

**Logic module** (`UnboxPathGroundType.elm`):
- Exposes `expectUnboxPathGroundType : Src.Module -> Expectation`
- Runs `Pipeline.runToTypedOpt` to get `TypedOptArtifacts`
- Walks `localGraph.nodes` via `Data.Map.foldl`
- For each `TOpt.Define expr` / `TOpt.TrackedDefine expr`, recursively walks the expression tree
- On `TOpt.Case name destructorName decider jumps meta`: walks the Decider tree collecting all paths, and walks each jump expression
- On `TOpt.Destruct (TOpt.Destructor name path) body meta`: checks the path directly
- Extracts every `TypedPath.Unbox` segment from Chain path lists and FanOut root paths
- For each Unbox segment, checks the attached `Can.Type` for:
  - **Groundness**: recursive walk checking no `Can.TVar` leaf
  - **Single-constructor**: looks up the union in the canonical module's type declarations, confirms `numAlts == 1` and `opts == Can.Unbox`
  - **Single-field**: confirms the sole `Ctor` has `numArgs == 1`
- Collects violations as `{ context : String, message : String }` records, fails if non-empty

**Test wrapper** (`UnboxPathGroundTypeTest.elm`):
- Runs against `StandardTestSuites.expectSuite` for broad coverage
- Additionally imports `DecisionTreeAdvancedCases` for pattern-match-heavy programs

**Key test inputs** (via existing SourceIR suites + new targeted cases if needed):
- `type Wrapper a = Wrapper a` used at `Wrapper Int`, `Wrapper String`
- `type Id = Id Int` — concrete unboxable wrapper
- `type Name = Name String` — concrete boxed wrapper
- Nested: `type Outer = Outer (Wrapper Int)`
- Negative: `Maybe`, `Result`, multi-field constructors should produce zero Unbox segments

### Step 15: Add MONO_026 — UnboxCtorLayoutConsistency invariant test

**New files**:
- `compiler/tests/TestLogic/Monomorphize/UnboxCtorLayoutConsistency.elm`
- `compiler/tests/TestLogic/Monomorphize/UnboxCtorLayoutConsistencyTest.elm`

**Logic module** (`UnboxCtorLayoutConsistency.elm`):
- Exposes `expectUnboxCtorLayoutConsistency : Src.Module -> Expectation`
- Runs `Pipeline.runToMono` to get `MonoArtifacts`
- Walks `monoGraph.nodes` array, for each `Just node`:
  - Extracts all `MonoExpr` trees from the node (via `MonoDefine expr`, `MonoTailFunc _ expr`, etc.)
  - Recursively walks expressions to find `MonoCase` nodes
  - In each `MonoCase`, walks the Decider tree and jump expressions collecting all `MonoPath` instances
  - Also checks `MonoDestruct` paths
- For each `MonoPath`, recursively searches for `MonoUnbox resultType subPath` segments
- For each found `MonoUnbox`:
  - Gets container type: `containerType = Mono.getMonoPathType subPath`
  - Asserts `containerType` is `MCustom moduleName typeName typeArgs`
  - Looks up `Mono.toComparableMonoType containerType` in `monoGraph.ctorShapes`
  - Asserts lookup succeeds
  - Asserts result is `[ singleShape ]` (exactly 1 constructor)
  - Asserts `singleShape.fieldTypes` is `[ fieldType ]` (exactly 1 field)
  - Asserts `resultType == fieldType` (the MonoUnbox result type matches)
  - Computes `layout = Types.computeCtorLayout singleShape`
  - Asserts `layout.fields` is `[ fieldInfo ]`
  - If `fieldType` is `MInt`/`MFloat`/`MChar`: asserts `fieldInfo.isUnboxed == True` and `layout.unboxedBitmap == 1`
  - Otherwise: asserts `fieldInfo.isUnboxed == False` and `layout.unboxedBitmap == 0`
- Collects all violations, fails if non-empty

**Test wrapper** (`UnboxCtorLayoutConsistencyTest.elm`):
- Runs `StandardTestSuites.expectSuite` for broad coverage
- Also runs `DecisionTreeAdvancedCases.expectSuite` for pattern-intensive programs

**Key test inputs**:
- Programs with `type Wrapper a = Wrapper a` at `Int` (unboxed, bitmap 1) and `String` (boxed, bitmap 0)
- `type Id = Id Int` and `type Name = Name String` — direct concrete wrappers
- Nested: `type Inner = Inner Int`, `type Outer = Outer Inner` — tests nested Unbox chains
- Polymorphic wrappers specialized at multiple types in same program
- Negative cases: `Maybe Int`, `Result String Int`, `type Pair a b = Pair a b` — none should produce `MonoUnbox`

**Note**: MONO_026 should also walk `MonoDtPath` segments (the new type from this plan) inside `Decider` nodes, not just `MonoPath` from destructors. The `DtUnbox` constructor carries the same `resultType` + sub-path structure and should be checked with identical logic.

### Step 16: Build and run all tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```

Verify that both new invariant tests pass across the full suite, and that the `CaseSingleCtorBoolMultiTypeTest` regression is fixed.

---

## Resolved Questions

### Q1: Which `Name` in `MonoCase` is the root variable? — RESOLVED

**Answer**: The second `Name` is the root scrutinee variable. Confirmed by `MonoInlineSimplify.substitute` which annotates:
```elm
MonoCase unused rootName decider branches resultType ->
```
Pass `rootName` (the second Name) to `specializeDtPath`.

### Q2: DT.Path `Index` uses `Index.ZeroBased` — conversion to `Int` — ASSUMED

**Assumption**: Yes, both `TOpt.Path` and `DT.Path` use `Index.ZeroBased` and `Index.toMachine` is the correct conversion. (Unverified but high confidence from existing code patterns.)

### Q3: Remove `root` parameter from codegen functions? — RESOLVED: YES

**Answer**: Remove the separate `root : Name` parameter from the Expr/Patterns codegen functions in the same patch. Once `MonoDtPath` carries `DtRoot Name MonoType`, keeping a redundant `root` parameter risks drift. Concretely:
- `generateMonoTest`, `generateMonoChainCondition`, `generateMonoDtPath` take only `MonoDtPath` + `targetType` — no `root`.
- `generateDeciderWithJumps`, `generateChainWithJumps`, `generateFanOutWithJumps`, etc. in `Expr.elm` drop their `root` parameter.
- `compileCaseChainStep`, `compileCaseFanOutStep` in `TailRec.elm` drop their `root` parameter.
- `compileCaseDeciderStep` drops `root` too (it only passes it to sub-functions).

### Q4: `renameTailCallsDecider` — path renaming needed? — RESOLVED: NO

**Answer**: `renameTailCallsDecider` does NOT touch paths. It passes `tests` and `path` through unchanged, only rewriting `MonoChoice` (Inline expressions). No `renameDtPath` utility is needed for this function.

**Future note**: If a future optimization needs to rename variables inside `MonoDtPath` (e.g. renaming the scrutinee root), a `renameDtPath` helper would be needed at that point. Not needed now.

### Q5: `inferFromDecider` / `inferRootTypeFromDecider` — RESOLVED: path-agnostic

**Answer**: These functions are path-agnostic. `collectDeciderVarTypes` ignores paths entirely. `inferRootTypeFromDecider` only checks whether the path `isEmptyPath` (i.e. is the root) and then inspects the `Test` value — it never structurally walks the path. Impact is minimal: just change `isEmptyPath` to check for `DtRoot` instead of `DT.Empty`.

### Q6: Import aliasing — `DT` means different things in different files — NOTED

- In `Monomorphized.elm`: `DT` = both `DecisionTree.Test` and `DecisionTree.TypedPath`
- In `Patterns.elm`: `DT` = `LocalOpt.Typed.DecisionTree` (re-exports `Path` as alias for `TypedPath.Path`)
- In `Expr.elm` and `TailRec.elm`: `DT` = `LocalOpt.Typed.DecisionTree`

After this change, `Monomorphized.elm` can remove the `TypedPath as DT` import (only `Test as DT` remains for `DT.Test`).

### Q7: Can `ArrayIndex` appear in DT.Path? — CONFIRMED: NO

`DT.Path` (TypedPath) only has `Index`, `Unbox`, and `Empty`. No `ArrayIndex` or `Field`. `specializeDtPath` only needs to handle these three.

### Q8: `TOpt.Path` vs `DT.Path` — CONFIRMED

The Decider uses `DT.Path` (TypedPath with `Empty` as base), NOT `TOpt.Path` (which has `Root Name`). `specializeDtPath` must:
- Accept `rootName : Name` explicitly as a separate parameter
- Map `DT.Empty` → `Mono.DtRoot rootName rootType` (looking up `rootType` from VarEnv)
- Map `DT.Index` and `DT.Unbox` recursively

---

## Addendum: Detailed Switchover Implementation Notes

This addendum covers the extra implementation detail for applying MonoDtPath in both monomorphizers, swapping Expr/Patterns codegen, updating decider utilities, and cleaning up obsolete helpers. File paths are relative to `compiler/src`.

### A1. Classic monomorphizer: `Compiler/Monomorphize/Specialize.elm`

The existing `specializeDecider` signature and body are:
```elm
specializeDecider :
    TOpt.Decider TOpt.Choice
    -> Substitution
    -> MonoState
    -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider decider subst state =
    case decider of
        TOpt.Leaf choice -> ...
        TOpt.Chain testChain success failure -> ...
        TOpt.FanOut path edges fallback -> ...
```

**Changes:**

1. Extend signature with root name:
   ```elm
   specializeDecider :
       Name
       -> TOpt.Decider TOpt.Choice
       -> Substitution
       -> MonoState
       -> ( Mono.Decider Mono.MonoChoice, MonoState )
   ```

2. Add `specializeDtPath` helper using the classic state's `ctx.varEnv` and `globalTypeEnv`:
   - Look up root's `MonoType` in `varEnv`
   - Create `Mono.DtRoot rootName rootType`
   - Walk `DT.Path` (`TypedPath.Empty|Index|Unbox`) producing `MonoDtPath` via:
     - `hintToKind` + `computeIndexProjectionType` for `Index`
     - `computeUnboxResultType` for `Unbox`

3. Wire into `specializeDecider`:
   - **Chain**: map each `(path, test)` through `specializeDtPath`:
     ```elm
     TOpt.Chain testChain success failure ->
         ...
         let
             monoTestChain =
                 List.map
                     (\( path, test ) ->
                         ( specializeDtPath rootName path state.ctx.varEnv state.globalTypeEnv
                         , test
                         )
                     )
                     testChain
         in
         ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )
     ```
   - **FanOut**: specialize the single path:
     ```elm
     TOpt.FanOut path edges fallback ->
         ...
         let
             monoPath =
                 specializeDtPath rootName path state.ctx.varEnv state.globalTypeEnv
         in
         ( Mono.FanOut monoPath monoEdges monoFallback, state2 )
     ```

4. Pass `rootName` from the MonoCase construction site using the **second** Name (`scrutVar`/`label`):
   ```elm
   ( monoDecider, state1 ) =
       specializeDecider scrutVar decider subst state0
   ```

### A2. MonoDirect monomorphizer: `Compiler/MonoDirect/Specialize.elm`

The MonoDirect `specializeDecider` uses a different signature:
```elm
specializeDecider :
    LocalView
    -> SolverSnapshot
    -> TOpt.Decider TOpt.Choice
    -> MonoDirectState
    -> ( Mono.Decider Mono.MonoChoice, MonoDirectState )
```

**Parallel changes:**

1. Extend signature:
   ```elm
   specializeDecider :
       Name
       -> LocalView
       -> SolverSnapshot
       -> TOpt.Decider TOpt.Choice
       -> MonoDirectState
       -> ( Mono.Decider Mono.MonoChoice, MonoDirectState )
   ```

2. Implement `specializeDtPath` in MonoDirect style using `state.varEnv` and `view.globalTypeEnv` — identical logic to classic helper, just different state/view types.

3. In Chain and FanOut cases, map `DT.Path` to `MonoDtPath` using `rootName`, exactly as in A1.

4. At MonoDirect MonoCase construction site, pass root name into `specializeDecider`.

### A3. Patterns.elm — switch to MonoDtPath and remove `root`

**File**: `Compiler/Generate/MLIR/Patterns.elm`

New adapter (converts MonoDtPath → MonoPath and delegates):
```elm
generateMonoDtPath :
    Ctx.Context
    -> Mono.MonoDtPath
    -> MlirType
    -> ( List MlirOp, String, Ctx.Context )
generateMonoDtPath ctx dtPath targetType =
    let
        toMonoPath monoDt =
            case monoDt of
                Mono.DtRoot name ty ->
                    Mono.MonoRoot name ty
                Mono.DtIndex idx kind resultTy sub ->
                    Mono.MonoIndex idx kind resultTy (toMonoPath sub)
                Mono.DtUnbox resultTy sub ->
                    Mono.MonoUnbox resultTy (toMonoPath sub)
    in
    generateMonoPath ctx (toMonoPath dtPath) targetType
```

**Change `generateTest` signature** — drop `root`:
```elm
-- Before:
generateTest : Ctx.Context -> Name.Name -> ( DT.Path, DT.Test ) -> ( List MlirOp, String, Ctx.Context )

-- After:
generateTest : Ctx.Context -> ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
```

Inside, replace `generateDTPath ctx root path targetType` with `generateMonoDtPath ctx path targetType`.

**Change `generateChainCondition` signature** — drop `root`:
```elm
-- Before:
generateChainCondition : Ctx.Context -> Name.Name -> List ( DT.Path, DT.Test ) -> ( List MlirOp, String, Ctx.Context )

-- After:
generateChainCondition : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> ( List MlirOp, String, Ctx.Context )
```

Body adjustments:
- `[]` and single-test cases call `generateTest ctx singleTest` (no root)
- Fold over remaining tests calls `generateTest accCtx test` (no root)

**Delete** `generateDTPath`, `generateDTPathHelper`, and `findSingleCtorUnboxedField` once all call-sites are removed.

Update module export list: expose `generateMonoPath`, `generateMonoDtPath`, `generateChainCondition` (updated signature), remove `generateDTPath`.

### A4. Expr.elm — FanOut helpers use MonoDtPath, no root

**File**: `Compiler/Generate/MLIR/Expr.elm`

Change signatures to carry `MonoDtPath` instead of `DT.Path` and drop `Name` root:

```elm
-- Before:
generateFanOutWithJumps : Ctx.Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateBoolFanOutWithJumps : Ctx.Context -> Name.Name -> DT.Path -> ... -> ExprResult
generateFanOutGeneralWithJumps : Ctx.Context -> Name.Name -> DT.Path -> ... -> ExprResult

-- After:
generateFanOutWithJumps : Ctx.Context -> Mono.MonoDtPath -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateBoolFanOutWithJumps : Ctx.Context -> Mono.MonoDtPath -> ... -> ExprResult
generateFanOutGeneralWithJumps : Ctx.Context -> Mono.MonoDtPath -> ... -> ExprResult
```

In `generateBoolFanOutWithJumps`, replace:
```elm
-- Before:
( pathOps, boolVar, ctx1 ) = Patterns.generateDTPath ctx root path I1
thenRes = generateDeciderWithJumps ctx1 root trueBranch ...
elseRes = generateDeciderWithJumps ctxForElse root falseBranch ...

-- After:
( pathOps, boolVar, ctx1 ) = Patterns.generateMonoDtPath ctx path I1
thenRes = generateDeciderWithJumps ctx1 trueBranch ...
elseRes = generateDeciderWithJumps ctxForElse falseBranch ...
```

In `generateFanOutGeneralWithJumps`, replace:
```elm
-- Before:
( pathOps, scrutineeVar, ctx1 ) = Patterns.generateDTPath ctx root path scrutineeType
subRes = generateDeciderWithJumps branchCtx root subTree ...
fallbackRes = generateDeciderWithJumps fallbackCtx root fallback ...

-- After:
( pathOps, scrutineeVar, ctx1 ) = Patterns.generateMonoDtPath ctx path scrutineeType
subRes = generateDeciderWithJumps branchCtx subTree ...
fallbackRes = generateDeciderWithJumps fallbackCtx fallback ...
```

At the MonoCase lowering in `Expr.generateExpr` that handles `Mono.MonoCase _ root decider jumps _`: change call to pass `monoPath` from `Mono.FanOut` directly to `generateFanOutWithJumps` (no separate root).

### A5. Decider utilities — type-only updates (no logic changes)

These functions traverse or transform `Mono.Decider` but are path-agnostic (they pass `path` through unchanged). When `Decider` switches from `DT.Path` to `MonoDtPath`, they need only **type** updates:

1. **`renameTailCallsDecider`** (both Specialize files):
   ```elm
   Mono.Chain tests ... -> Mono.Chain tests ...       -- tests unchanged
   Mono.FanOut path ... -> Mono.FanOut path ...        -- path unchanged
   ```
   Only the `Decider` definition changes; function stays structurally identical.

2. **`inlineVarInDecider`** (`MonoInlineSimplify.elm`):
   ```elm
   Mono.Chain testChain ... -> Mono.Chain testChain ...    -- testChain unchanged
   Mono.FanOut path ... -> Mono.FanOut path ...            -- path unchanged
   ```
   No logic change; just relies on new `MonoDtPath` type in `Decider` definition.

3. **`mapDecider`, `traverseDecider`, `foldDeciderAccFirst`** (`MonoTraverse.elm`):
   Match on `FanOut path edges fallback` and carry `path` through; keep bodies identical, just update imported `Decider` type.

4. **`collectDeciderVarTypes`, `collectCaseRootTypesFromDecider`** (`Closure.elm`):
   Only traverse `Decider` and look at tests and branch bodies, not paths:
   ```elm
   Mono.Chain _ success failure -> ...
   Mono.FanOut _ edges fallback -> ...
   ```
   No path logic; just ensure they compile with updated `Decider` type.

No additional `renameDtPath` helper is needed in this pass — all these functions either ignore the path or just copy it. If variable renaming at `DtRoot` level is needed later, a dedicated helper can be added then.

### A6. Clean-up and verification checklist

1. **Delete from `Compiler/Generate/MLIR/Patterns.elm`**:
   - `generateDTPath`
   - `generateDTPathHelper`
   - `findSingleCtorUnboxedField`
   - Any DT.Path-only helper now unreachable

2. **Update module exports**:
   - `Patterns.elm`: expose `generateMonoPath`, `generateMonoDtPath`, `generateChainCondition` (updated); remove `generateDTPath`

3. **Verify all `Decider` imports compile**:
   - `Monomorphized.elm`: `Decider a` now uses `MonoDtPath`
   - All users (Expr, TailRec, Closure, MonoTraverse, MonoInlineSimplify, both monomorphizers) type-check with `MonoDtPath`

4. **Run the failing test**:
   - `CaseSingleCtorBoolMultiTypeTest.elm` should compile without the i1 vs i64 mismatch
   - Re-run invariant tests that assert MLIR invariants — no more `eco.project.custom` with wrong primitive type on Bool wrappers
