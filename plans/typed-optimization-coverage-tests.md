# Typed Optimization and PostSolve Coverage Test Plan

## Overview

This plan outlines the implementation of ~200 new test cases to improve coverage of the typed optimization and type constraint modules. The tests target code paths in:

1. **Compiler.Optimize.Typed.*** - Typed optimization passes
2. **Compiler.Type.Constrain.Typed.*** - Type constraint generation with node IDs
3. **Compiler.Type.PostSolve** - Post-solve type resolution

## Current Coverage Summary

| Module | Current Coverage | Uncovered Regions | Priority |
|--------|------------------|-------------------|----------|
| Compiler.Optimize.Typed.Port | 0/33 (0%) | 33 | HIGH |
| Compiler.Type.Constrain.Typed.Module | 4/17 (23.5%) | 13 | HIGH |
| Compiler.Type.PostSolve | 69/139 (49.6%) | 70 | HIGH |
| Compiler.Optimize.Typed.DecisionTree | 81/143 (56.6%) | 62 | MEDIUM |
| Compiler.Optimize.Typed.Module | 66/108 (61.1%) | 42 | MEDIUM |
| Compiler.Optimize.Typed.Expression | 94/121 (77.7%) | 27 | MEDIUM |
| Compiler.Type.Constrain.Typed.Expression | 68/83 (81.9%) | 15 | LOW |
| Compiler.Optimize.Typed.Case | 13/16 (81.2%) | 3 | LOW |
| Compiler.Optimize.Typed.Names | 12/13 (92.3%) | 1 | LOW |
| Compiler.Type.Constrain.Typed.Pattern | 38/40 (95.0%) | 2 | LOW |
| Compiler.Type.Constrain.Typed.Program | 22/23 (95.7%) | 1 | LOW |
| Compiler.Optimize.Typed.KernelTypes | 1/2 (50.0%) | 1 | LOW |
| Compiler.Type.Constrain.Typed.NodeIds | 2/2 (100%) | 0 | DONE |

## Test Implementation Strategy

Tests will be written in Source IR form using `Compiler.AST.SourceBuilder` and run through `expectMonomorphization` from `Compiler.Generate.TypedOptimizedMonomorphize`.

### New Test Files to Create

1. **PortEncodingTests.elm** (~35 tests) - Port encoder/decoder coverage
2. **EffectManagerTests.elm** (~20 tests) - Effect manager coverage
3. **PostSolveExprTests.elm** (~50 tests) - PostSolve expression handling
4. **DecisionTreeAdvancedTests.elm** (~40 tests) - Advanced pattern matching
5. **TypeConstraintModuleTests.elm** (~25 tests) - Module constraint generation
6. **TypedOptExprTests.elm** (~30 tests) - Expression optimization gaps

### Additions to Existing Test Files

- **PatternMatchingTests.elm** - Add ~15 tests for uncovered pattern combinations
- **CaseTests.elm** - Add ~10 tests for decision tree edge cases
- **LetDestructTests.elm** - Add ~10 tests for destructuring patterns

---

## Detailed Test Cases by Module

### 1. Compiler.Optimize.Typed.Port (0% coverage - 35 new tests)

The Port module handles JSON encoding/decoding for Elm ports. All functions are currently untested.

**File: compiler/tests/Compiler/PortEncodingTests.elm**

#### 1.1 Encoder Tests (18 tests)

| # | Test Name | Description | Elm Code Pattern |
|---|-----------|-------------|------------------|
| 1 | `encodeInt` | Encode Int through port | `port out : Int -> Cmd msg` |
| 2 | `encodeFloat` | Encode Float through port | `port out : Float -> Cmd msg` |
| 3 | `encodeBool` | Encode Bool through port | `port out : Bool -> Cmd msg` |
| 4 | `encodeString` | Encode String through port | `port out : String -> Cmd msg` |
| 5 | `encodeUnit` | Encode Unit through port | `port out : () -> Cmd msg` |
| 6 | `encodeMaybeInt` | Encode Maybe Int | `port out : Maybe Int -> Cmd msg` |
| 7 | `encodeMaybeString` | Encode Maybe String | `port out : Maybe String -> Cmd msg` |
| 8 | `encodeListInt` | Encode List Int | `port out : List Int -> Cmd msg` |
| 9 | `encodeListString` | Encode List String | `port out : List String -> Cmd msg` |
| 10 | `encodeArrayInt` | Encode Array Int | `port out : Array Int -> Cmd msg` |
| 11 | `encodeTuple2` | Encode 2-tuple | `port out : (Int, String) -> Cmd msg` |
| 12 | `encodeTuple3` | Encode 3-tuple | `port out : (Int, String, Bool) -> Cmd msg` |
| 13 | `encodeSimpleRecord` | Encode simple record | `port out : { x : Int, y : Int } -> Cmd msg` |
| 14 | `encodeNestedRecord` | Encode nested record | `port out : { pos : { x : Int, y : Int } } -> Cmd msg` |
| 15 | `encodeRecordWithList` | Record with list field | `port out : { items : List Int } -> Cmd msg` |
| 16 | `encodeListOfRecords` | Encode list of records | `port out : List { x : Int } -> Cmd msg` |
| 17 | `encodeMaybeRecord` | Encode maybe record | `port out : Maybe { x : Int } -> Cmd msg` |
| 18 | `encodeJsonValue` | Encode Json.Encode.Value | `port out : Json.Encode.Value -> Cmd msg` |

#### 1.2 Decoder Tests (17 tests)

| # | Test Name | Description | Elm Code Pattern |
|---|-----------|-------------|------------------|
| 19 | `decodeInt` | Decode Int from port | `port inp : (Int -> msg) -> Sub msg` |
| 20 | `decodeFloat` | Decode Float from port | `port inp : (Float -> msg) -> Sub msg` |
| 21 | `decodeBool` | Decode Bool from port | `port inp : (Bool -> msg) -> Sub msg` |
| 22 | `decodeString` | Decode String from port | `port inp : (String -> msg) -> Sub msg` |
| 23 | `decodeUnit` | Decode Unit (tuple0) | `port inp : (() -> msg) -> Sub msg` |
| 24 | `decodeMaybeInt` | Decode Maybe Int | `port inp : (Maybe Int -> msg) -> Sub msg` |
| 25 | `decodeListInt` | Decode List Int | `port inp : (List Int -> msg) -> Sub msg` |
| 26 | `decodeArrayInt` | Decode Array Int | `port inp : (Array Int -> msg) -> Sub msg` |
| 27 | `decodeTuple2` | Decode 2-tuple | `port inp : ((Int, String) -> msg) -> Sub msg` |
| 28 | `decodeTuple3` | Decode 3-tuple | `port inp : ((Int, String, Bool) -> msg) -> Sub msg` |
| 29 | `decodeSimpleRecord` | Decode simple record | `port inp : ({ x : Int } -> msg) -> Sub msg` |
| 30 | `decodeNestedRecord` | Decode nested record | `port inp : ({ pos : { x : Int } } -> msg) -> Sub msg` |
| 31 | `decodeRecordMultiField` | Record multiple fields | `port inp : ({ a : Int, b : String, c : Bool } -> msg) -> Sub msg` |
| 32 | `decodeListOfRecords` | Decode list of records | `port inp : (List { x : Int } -> msg) -> Sub msg` |
| 33 | `decodeMaybeRecord` | Decode maybe record | `port inp : (Maybe { x : Int } -> msg) -> Sub msg` |
| 34 | `decodeJsonValue` | Decode Json.Decode.Value | `port inp : (Json.Decode.Value -> msg) -> Sub msg` |
| 35 | `decodeNestedMaybe` | Nested Maybe types | `port inp : (Maybe (Maybe Int) -> msg) -> Sub msg` |

**Implementation Notes:**
- Ports require `port module` declaration
- Need to add port-specific Source IR builders to SourceBuilder.elm
- Each test creates a port module and validates it compiles through monomorphization

---

### 2. Compiler.Type.Constrain.Typed.Module (23.5% coverage - 25 new tests)

This module handles constraint generation for effects modules.

**File: compiler/tests/Compiler/EffectManagerTests.elm**

#### 2.1 Effect Manager Constraint Tests (20 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 36 | `cmdEffectManagerInit` | Cmd manager init constraint | `constrainEffectsWithIdsProg` Cmd branch |
| 37 | `cmdEffectManagerOnEffects` | Cmd manager onEffects | `constrainEffectsWithIdsProg` Cmd |
| 38 | `cmdEffectManagerOnSelfMsg` | Cmd manager onSelfMsg | `constrainEffectsWithIdsProg` Cmd |
| 39 | `subEffectManagerInit` | Sub manager init constraint | `constrainEffectsWithIdsProg` Sub branch |
| 40 | `subEffectManagerOnEffects` | Sub manager onEffects | `constrainEffectsWithIdsProg` Sub |
| 41 | `subEffectManagerOnSelfMsg` | Sub manager onSelfMsg | `constrainEffectsWithIdsProg` Sub |
| 42 | `fxEffectManagerInit` | Fx manager init constraint | `constrainEffectsWithIdsProg` Fx branch |
| 43 | `fxEffectManagerOnEffects` | Fx manager onEffects | `constrainEffectsWithIdsProg` Fx |
| 44 | `fxEffectManagerOnSelfMsg` | Fx manager onSelfMsg | `constrainEffectsWithIdsProg` Fx |
| 45 | `checkMapCmdHelper` | Check map for Cmd | `checkMapHelperWithIdsProg` |
| 46 | `checkMapSubHelper` | Check map for Sub | `checkMapHelperWithIdsProg` |
| 47 | `checkMapFxHelper` | Check map for Fx | `checkMapHelperWithIdsProg` |
| 48 | `effectListCmd` | Effect list for Cmd | `effectList` function |
| 49 | `effectListSub` | Effect list for Sub | `effectList` function |
| 50 | `taskTypeGeneration` | Task type constraint | `task` function |
| 51 | `routerTypeGeneration` | Router type constraint | `router` function |
| 52 | `toMapTypeCoverage` | toMapType function | `toMapType` function |
| 53 | `letPortWithVarsIncoming` | Incoming port vars | `letPortWithVars` Incoming |
| 54 | `letPortWithVarsOutgoing` | Outgoing port vars | `letPortWithVars` Outgoing |
| 55 | `letCmdWithVarsCoverage` | Cmd command vars | `letCmdWithVars` |

#### 2.2 Module Constraint Tests (5 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 56 | `letSubWithVarsCoverage` | Sub subscription vars | `letSubWithVars` |
| 57 | `constrainDeclsWithVarsHelp` | Decls constraint helper | `constrainDeclsWithVarsHelp` |
| 58 | `constrainWithIdsModule` | Module constraint with IDs | `constrainWithIds` |
| 59 | `constrainDeclsWithVarsRecursive` | Recursive decls | `constrainDeclsWithVars` recursive |
| 60 | `constrainEffectsNoEffects` | No effects case | `constrainEffectsWithIds` NoEffects |

**Implementation Notes:**
- Effect manager tests require special module structures
- May need to create CanonicalBuilder helpers for effect modules
- Tests should verify constraint generation doesn't crash

---

### 3. Compiler.Type.PostSolve (49.6% coverage - 50 new tests)

**File: compiler/tests/Compiler/Type/PostSolve/PostSolveExprTests.elm**

#### 3.1 Expression Type Resolution Tests (35 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 61 | `postSolveStrType` | String literal type | `postSolveExpr` Str branch |
| 62 | `postSolveChrType` | Char literal type | `postSolveExpr` Chr branch |
| 63 | `postSolveFloatType` | Float literal type | `postSolveExpr` Float branch |
| 64 | `postSolveUnitType` | Unit literal type | `postSolveExpr` Unit branch |
| 65 | `postSolveListEmpty` | Empty list type | `postSolveList` empty |
| 66 | `postSolveListSingleton` | Singleton list type | `postSolveList` singleton |
| 67 | `postSolveListMultiple` | Multiple element list | `postSolveList` multiple |
| 68 | `postSolveTuple2` | 2-tuple type | `postSolveTuple` 2 |
| 69 | `postSolveTuple3` | 3-tuple type | `postSolveTuple` 3 |
| 70 | `postSolveRecordSimple` | Simple record type | `postSolveRecord` |
| 71 | `postSolveRecordNested` | Nested record type | `postSolveRecord` nested |
| 72 | `postSolveLambdaSimple` | Simple lambda type | `postSolveLambda` |
| 73 | `postSolveLambdaMultiArg` | Multi-arg lambda | `postSolveLambda` multi |
| 74 | `postSolveAccessorField` | Field accessor type | `postSolveAccessor` |
| 75 | `postSolveLetSimple` | Let expression type | `postSolveExpr` Let |
| 76 | `postSolveLetRecSimple` | LetRec expression | `postSolveExpr` LetRec |
| 77 | `postSolveLetDestruct` | LetDestruct expression | `postSolveExpr` LetDestruct |
| 78 | `postSolveIfSimple` | Simple if expression | `postSolveIf` |
| 79 | `postSolveIfNested` | Nested if expression | `postSolveIf` nested |
| 80 | `postSolveCaseSimple` | Simple case expression | `postSolveCase` |
| 81 | `postSolveCaseMultiBranch` | Multi-branch case | `postSolveCase` multi |
| 82 | `postSolveUpdateSimple` | Record update type | `postSolveUpdate` |
| 83 | `postSolveUpdateMultiField` | Multi-field update | `postSolveUpdate` multi |
| 84 | `postSolveCallSimple` | Simple call type | `postSolveCall` |
| 85 | `postSolveCallKernel` | Kernel function call | `postSolveCall` kernel |
| 86 | `postSolveBinopAdd` | Addition binop | `postSolveBinop` add |
| 87 | `postSolveBinopCompare` | Comparison binop | `postSolveBinop` compare |
| 88 | `postSolveBinopLogical` | Logical binop | `postSolveBinop` logical |
| 89 | `postSolveNegate` | Negate expression | `postSolveExpr` Negate |
| 90 | `postSolveAccess` | Record access | `postSolveExpr` Access |
| 91 | `postSolveVarKernelKnown` | VarKernel known type | `postSolveExpr` VarKernel known |
| 92 | `postSolveVarKernelUnknown` | VarKernel unknown | `postSolveExpr` VarKernel unknown |
| 93 | `postSolveVarLocal` | Local variable | `postSolveExpr` VarLocal |
| 94 | `postSolveVarTopLevel` | Top-level variable | `postSolveExpr` VarTopLevel |
| 95 | `postSolveVarForeign` | Foreign variable | `postSolveExpr` VarForeign |

#### 3.2 Kernel Type Inference Tests (15 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 96 | `inferBinopKernelTypeInt` | Int binop kernel type | `inferBinopKernelType` Int |
| 97 | `inferBinopKernelTypeFloat` | Float binop kernel | `inferBinopKernelType` Float |
| 98 | `inferBranchKernelType` | Branch kernel type | `inferBranchKernelType` |
| 99 | `propagateKernelArgTypes` | Propagate arg types | `propagateKernelArgTypes` |
| 100 | `unifySchemeToType` | Scheme unification | `unifySchemeToType` |
| 101 | `unifyHelpLambda` | Lambda unification | `unifyHelp` TLambda |
| 102 | `unifyHelpType` | Type unification | `unifyHelp` TType |
| 103 | `unifyHelpRecord` | Record unification | `unifyHelp` TRecord |
| 104 | `unifyHelpTuple` | Tuple unification | `unifyHelp` TTuple |
| 105 | `unifyList` | List unification | `unifyList` |
| 106 | `unifyFieldList` | Field list unification | `unifyFieldList` |
| 107 | `applySubst` | Apply substitution | `applySubst` |
| 108 | `postSolveCallCtorKernel` | Ctor kernel args | `postSolveCallWithCtorKernelArgs` |
| 109 | `processCtorArgs` | Process ctor args | `processCtorArgs` |
| 110 | `peelFunctionTypeMulti` | Peel multi-arg func | `peelFunctionType` |

---

### 4. Compiler.Optimize.Typed.DecisionTree (56.6% coverage - 40 new tests)

**File: compiler/tests/Compiler/DecisionTreeAdvancedTests.elm**

#### 4.1 Pattern Relevance Tests (20 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 111 | `relevantBranchPCtor` | Ctor pattern relevance | `toRelevantBranch` PCtor |
| 112 | `relevantBranchPCtorSingleAlt` | Single alt ctor | `toRelevantBranch` PCtor single |
| 113 | `relevantBranchPCtorMultiArg` | Multi-arg ctor | `toRelevantBranch` PCtor multi |
| 114 | `relevantBranchPListEmpty` | Empty list relevance | `toRelevantBranch` PList empty |
| 115 | `relevantBranchPListNonEmpty` | Non-empty list | `toRelevantBranch` PList non-empty |
| 116 | `relevantBranchPCons` | Cons pattern | `toRelevantBranch` PCons |
| 117 | `relevantBranchPChr` | Char pattern | `toRelevantBranch` PChr |
| 118 | `relevantBranchPStr` | String pattern | `toRelevantBranch` PStr |
| 119 | `relevantBranchPInt` | Int pattern | `toRelevantBranch` PInt |
| 120 | `relevantBranchPBool` | Bool pattern | `toRelevantBranch` PBool |
| 121 | `relevantBranchPUnit` | Unit pattern | `toRelevantBranch` PUnit |
| 122 | `relevantBranchPTuple2` | 2-tuple pattern | `toRelevantBranch` PTuple 2 |
| 123 | `relevantBranchPTuple3` | 3-tuple pattern | `toRelevantBranch` PTuple 3 |
| 124 | `relevantBranchPVar` | Variable pattern | `toRelevantBranch` PVar |
| 125 | `relevantBranchPAnything` | Wildcard pattern | `toRelevantBranch` PAnything |
| 126 | `relevantBranchPRecord` | Record pattern | `toRelevantBranch` PRecord |
| 127 | `relevantBranchPAlias` | Alias pattern | `toRelevantBranch` PAlias |
| 128 | `relevantBranchNotFound` | Not found case | `toRelevantBranch` NotFound |
| 129 | `relevantBranchMismatch` | Pattern mismatch | `toRelevantBranch` mismatch |
| 130 | `relevantBranchChain` | Chained patterns | `toRelevantBranch` chain |

#### 4.2 Decision Tree Construction Tests (20 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 131 | `toDecisionTreeSimple` | Simple decision tree | `toDecisionTree` |
| 132 | `toDecisionTreeComplete` | Complete patterns | `isComplete` true |
| 133 | `toDecisionTreeIncomplete` | Incomplete patterns | `isComplete` false |
| 134 | `flattenPatternsSimple` | Simple flatten | `flattenPatterns` |
| 135 | `flattenPatternsNested` | Nested flatten | `flatten` nested |
| 136 | `gatherEdgesSimple` | Simple gather edges | `gatherEdges` |
| 137 | `gatherEdgesMultiple` | Multiple edges | `gatherEdges` multi |
| 138 | `testsAtPathSimple` | Tests at path | `testsAtPath` |
| 139 | `testsAtPathNested` | Nested path tests | `testsAtPath` nested |
| 140 | `testAtPathCtor` | Test at path ctor | `testAtPath` ctor |
| 141 | `testAtPathLiteral` | Test at path literal | `testAtPath` literal |
| 142 | `edgesForSimple` | Edges for pattern | `edgesFor` |
| 143 | `needsTestsSimple` | Needs tests simple | `needsTests` |
| 144 | `needsTestsComplex` | Needs tests complex | `needsTests` complex |
| 145 | `pickPathSimple` | Pick path simple | `pickPath` |
| 146 | `pickPathMultiple` | Pick path multiple | `pickPath` multi |
| 147 | `isChoicePathTrue` | Is choice path true | `isChoicePath` true |
| 148 | `isChoicePathFalse` | Is choice path false | `isChoicePath` false |
| 149 | `smallDefaultsTrue` | Small defaults true | `smallDefaults` true |
| 150 | `smallBranchingFactor` | Branching factor | `smallBranchingFactor` |

---

### 5. Compiler.Optimize.Typed.Module (61.1% coverage - 30 new tests)

**Additions to existing test files and new TypedOptModuleTests.elm**

#### 5.1 Port Processing Tests (10 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 151 | `addPortIncoming` | Add incoming port | `addPort` Incoming |
| 152 | `addPortOutgoing` | Add outgoing port | `addPort` Outgoing |
| 153 | `addPortIncomingRecord` | Incoming record port | `addPort` Incoming record |
| 154 | `addPortOutgoingRecord` | Outgoing record port | `addPort` Outgoing record |
| 155 | `addPortIncomingList` | Incoming list port | `addPort` Incoming list |
| 156 | `addPortOutgoingList` | Outgoing list port | `addPort` Outgoing list |
| 157 | `addPortIncomingMaybe` | Incoming maybe port | `addPort` Incoming maybe |
| 158 | `addPortOutgoingMaybe` | Outgoing maybe port | `addPort` Outgoing maybe |
| 159 | `addPortIncomingTuple` | Incoming tuple port | `addPort` Incoming tuple |
| 160 | `addPortOutgoingTuple` | Outgoing tuple port | `addPort` Outgoing tuple |

#### 5.2 Effects Processing Tests (10 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 161 | `addEffectsNoEffects` | No effects case | `addEffects` NoEffects |
| 162 | `addEffectsPorts` | Ports effects | `addEffects` Ports |
| 163 | `addEffectsManagerCmd` | Cmd manager | `addEffects` Manager Cmd |
| 164 | `addEffectsManagerSub` | Sub manager | `addEffects` Manager Sub |
| 165 | `addEffectsManagerFx` | Fx manager | `addEffects` Manager Fx |
| 166 | `addCtorNodeSingle` | Single ctor node | `addCtorNode` single |
| 167 | `addCtorNodeMultiple` | Multiple ctor node | `addCtorNode` multi |
| 168 | `addAliasSimple` | Simple alias | `addAlias` simple |
| 169 | `addAliasRecord` | Record alias | `addAlias` record |
| 170 | `addRecordCtorField` | Record ctor field | `addRecordCtorField` |

#### 5.3 Definition Processing Tests (10 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 171 | `finalizeExprCall` | Finalize call expr | `finalizeExpr` Call |
| 172 | `finalizeExprTailCall` | Finalize tail call | `finalizeExpr` TailCall |
| 173 | `finalizeExprLet` | Finalize let expr | `finalizeExpr` Let |
| 174 | `finalizeExprDestruct` | Finalize destruct | `finalizeExpr` Destruct |
| 175 | `finalizeExprCase` | Finalize case expr | `finalizeExpr` Case |
| 176 | `finalizeDecider` | Finalize decider | `finalizeDecider` |
| 177 | `finalizeChoice` | Finalize choice | `finalizeChoice` |
| 178 | `addRecDefsSimple` | Simple rec defs | `addRecDefs` simple |
| 179 | `addRecDefsMultiple` | Multiple rec defs | `addRecDefs` multi |
| 180 | `addCycleName` | Add cycle name | `addCycleName` |

---

### 6. Compiler.Optimize.Typed.Expression (77.7% coverage - 27 new tests)

**Additions to existing test files**

#### 6.1 Expression Optimization Tests (15 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 181 | `optimizeExprVarKernel` | Optimize VarKernel | `optimizeExpr` VarKernel |
| 182 | `optimizeExprNegate` | Optimize Negate | `optimizeExpr` Negate |
| 183 | `optimizeExprBinopKernel` | Optimize kernel binop | `optimizeExpr` Binop kernel |
| 184 | `optimizeExprAccessor` | Optimize accessor | `optimizeExpr` Accessor |
| 185 | `optimizeTailSimple` | Optimize tail simple | `optimizeTail` |
| 186 | `optimizeTailNested` | Optimize tail nested | `optimizeTail` nested |
| 187 | `optimizeTailRecursive` | Optimize tail recursive | `optimizeTail` recursive |
| 188 | `hasTailCallTrue` | Has tail call true | `hasTailCall` true |
| 189 | `hasTailCallFalse` | Has tail call false | `hasTailCall` false |
| 190 | `decidecHasTailCall` | Decider has tail call | `decidecHasTailCall` |
| 191 | `destructArgsSimple` | Destruct args simple | `destructArgs` |
| 192 | `destructArgsMultiple` | Destruct args multi | `destructArgs` multi |
| 193 | `destructHelpWithType` | Destruct help type | `destructHelpWithType` |
| 194 | `destructCtorArg` | Destruct ctor arg | `destructCtorArg` |
| 195 | `destructCase` | Destruct case | `destructCase` |

#### 6.2 Definition Optimization Tests (12 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 196 | `optimizeDefSimple` | Optimize simple def | `optimizeDef` |
| 197 | `optimizeDefHelp` | Optimize def help | `optimizeDefHelp` |
| 198 | `optimizePotentialTailCall` | Potential tail call | `optimizePotentialTailCall` |
| 199 | `getDefNameAndType` | Get def name type | `getDefNameAndType` |
| 200 | `lookupAnnotationType` | Lookup annotation | `lookupAnnotationType` |
| 201 | `wrapDestruct` | Wrap destruct | `wrapDestruct` |
| 202 | `destructTwo` | Destruct two | `destructTwo` |
| 203 | `lookupPatternType` | Lookup pattern type | `lookupPatternType` |
| 204 | `catchMissing` | Catch missing | `catchMissing` |
| 205 | `buildFunctionType` | Build function type | `buildFunctionType` |
| 206 | `peelFunctionType` | Peel function type | `peelFunctionType` |
| 207 | `optimizeDefHelpRecursive` | Recursive def help | `optimizeDefHelp` recursive |

---

### 7. Additional Tests for Low-Priority Modules (13 tests)

#### 7.1 Compiler.Type.Constrain.Typed.Expression (8 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 208 | `constrainShaderWithIdsProg` | Shader constraint | `constrainShaderWithIdsProg` |
| 209 | `constrainAccessWithIdsProg` | Access constraint | `constrainAccessWithIdsProg` |
| 210 | `constrainDestructWithIdsProg` | Destruct constraint | `constrainDestructWithIdsProg` |
| 211 | `constrainCaseBranchWithIdsProg` | Case branch | `constrainCaseBranchWithIdsProg` |
| 212 | `constrainUpdateFieldsWithIdsProg` | Update fields | `constrainUpdateFieldsWithIdsProg` |
| 213 | `typedArgsHelpWithIds` | Typed args help | `typedArgsHelpWithIds` |
| 214 | `recDefsHelpWithIdsProg` | Rec defs help | `recDefsHelpWithIdsProg` |
| 215 | `constrainCallArgsWithIdsProg` | Call args | `constrainCallArgsWithIdsProg` |

#### 7.2 Other Modules (5 tests)

| # | Test Name | Description | Coverage Target |
|---|-----------|-------------|-----------------|
| 216 | `caseOptimizeChain` | Case chain optimize | `Typed.Case.toChain` |
| 217 | `caseCreateChoices` | Case create choices | `Typed.Case.createChoices` |
| 218 | `caseInsertChoices` | Case insert choices | `Typed.Case.insertChoices` |
| 219 | `kernelTypesLookupMissing` | Kernel lookup miss | `KernelTypes.lookup` miss |
| 220 | `namesRegisterDebug` | Names register debug | `Names.registerDebug` |

---

## Implementation Plan

### Phase 1: Infrastructure (Days 1-2)

1. **Add port module support to SourceBuilder**
   - Add `portModule` function to declare port modules
   - Add `portIn` and `portOut` builders for port declarations
   - Add effect module builders if needed

2. **Add effect manager support to CanonicalBuilder**
   - Add `effectModule` function
   - Add `cmdManager`, `subManager`, `fxManager` builders
   - Add `init`, `onEffects`, `onSelfMsg` constraint helpers

3. **Create new test file skeletons**
   - PortEncodingTests.elm
   - EffectManagerTests.elm
   - PostSolveExprTests.elm
   - DecisionTreeAdvancedTests.elm

### Phase 2: Port Tests (Days 3-4)

Implement tests 1-35 in PortEncodingTests.elm:
- Start with simple primitive types (Int, Float, Bool, String)
- Progress to container types (Maybe, List, Array)
- Add tuple and record tests
- Add nested structure tests

### Phase 3: PostSolve Tests (Days 5-7)

Implement tests 61-110 in PostSolveExprTests.elm:
- Group by expression type
- Add kernel type inference tests
- Add unification tests

### Phase 4: Decision Tree Tests (Days 8-9)

Implement tests 111-150 in DecisionTreeAdvancedTests.elm:
- Pattern relevance tests
- Decision tree construction tests
- Edge case tests

### Phase 5: Module and Expression Tests (Days 10-11)

Implement tests 151-207:
- Add to TypedOptModuleTests.elm
- Add to existing expression test files

### Phase 6: Integration and Cleanup (Day 12)

1. Run all tests to verify they pass canonicalization and type checking
2. Document any genuine compiler bugs found
3. Integrate test suites into master test runner

---

## Test Suite Integration

### New Test Module Structure

```
compiler/tests/Compiler/
├── PortEncodingTests.elm        (NEW - 35 tests)
├── EffectManagerTests.elm       (NEW - 20 tests)
├── DecisionTreeAdvancedTests.elm (NEW - 40 tests)
├── Type/
│   └── PostSolve/
│       └── PostSolveExprTests.elm (NEW - 50 tests)
└── Optimize/
    └── Typed/
        └── TypedOptModuleTests.elm (NEW - additions)
```

### Suite Integration

Add to main test suite in appropriate Test.elm files:

```elm
-- In compiler/tests/Test.elm or equivalent
suite : Test
suite =
    Test.describe "Compiler Tests"
        [ -- existing suites...
        , PortEncodingTests.suite
        , EffectManagerTests.suite
        , DecisionTreeAdvancedTests.suite
        , PostSolveExprTests.suite
        ]
```

---

## Test Logic Aggregators (expectSuite Pattern)

New test case files must be integrated into all test logic aggregators that use the `expectSuite` pattern. This ensures all test logics run against all test cases.

### Complete List of Test Logic Files

| # | Test Logic Module | Test Suite File | Expectation Functions |
|---|-------------------|-----------------|----------------------|
| 1 | Compiler.Canonicalize.GlobalNames | GlobalNamesTest.elm | `expectGlobalNamesQualified`, `expectGlobalNamesQualifiedCanonical` |
| 2 | Compiler.Canonicalize.IdAssignment | IdAssignmentTest.elm | `expectUniqueIds`, `expectUniqueIdsCanonical` |
| 3 | Compiler.Generate.CEcoValueLayout | CEcoValueLayoutTest.elm | `expectValidCEcoValueLayout` |
| 4 | Compiler.Generate.CodeGen.GenerateMLIR | GenerateMLIRTest.elm | `expectMLIRGeneration` |
| 5 | Compiler.Generate.MonoFunctionArity | MonoFunctionArityTest.elm | `expectFunctionArityMatches` |
| 6 | Compiler.Generate.MonoGraphIntegrity | MonoGraphIntegrityTest.elm | `expectCallableMonoNodes`, `expectMonoGraphClosed`, `expectMonoGraphComplete`, `expectSpecRegistryComplete` |
| 7 | Compiler.Generate.MonoLayoutIntegrity | MonoLayoutIntegrityTest.elm | `expectCtorLayoutsConsistent`, `expectLayoutsCanonical`, `expectRecordAccessMatchesLayout`, `expectRecordTupleLayoutsComplete` |
| 8 | Compiler.Generate.MonoNumericResolution | MonoNumericResolutionTest.elm | `expectNoNumericPolymorphism`, `expectNumericTypesResolved` |
| 9 | Compiler.Generate.MonoTypeShape | MonoTypeShapeTest.elm | `expectMonoTypesFullyElaborated` |
| 10 | Compiler.Generate.TypedOptimizedMonomorphize | TypedOptimizedMonomorphizeTest.elm | `expectMonomorphization` |
| 11 | Compiler.Optimize.AnnotationsPreserved | AnnotationsPreservedTest.elm | `expectAnnotationsPreserved` |
| 12 | Compiler.Optimize.DeciderExhaustive | DeciderExhaustiveTest.elm | `expectDeciderNoNestedPatterns`, `expectDeciderComplete` |
| 13 | Compiler.Optimize.FunctionTypeEncode | FunctionTypeEncodeTest.elm | `expectFunctionTypesEncoded` |
| 14 | Compiler.Optimize.OptimizeEquivalent | OptimizeEquivalentTest.elm | `expectEquivalentOptimization` |
| 15 | Compiler.Optimize.TypedOptTypes | TypedOptTypesTest.elm | `expectAllExprsHaveTypes` |
| 16 | Compiler.Type.Constrain.TypedErasedCheckingParity | TypedErasedCheckingParityTest.elm | `expectEquivalentTypeChecking`, `expectEquivalentTypeCheckingCanonical`, `expectEquivalentTypeCheckingFails` |

### Test Case Files Currently Aggregated

These are the existing test case files that provide `expectSuite` functions. Each new test file must follow this pattern:

1. **AnnotatedTests.elm** - Type annotation tests
2. **AsPatternTests.elm** - As-pattern tests
3. **BinopTests.elm** - Binary operator tests
4. **BitwiseTests.elm** - Bitwise operation tests
5. **CaseTests.elm** - Case expression tests
6. **ClosureTests.elm** - Closure tests
7. **ControlFlowTests.elm** - Control flow tests
8. **DeepFuzzTests.elm** - Deep fuzzing tests
9. **EdgeCaseTests.elm** - Edge case tests
10. **FloatMathTests.elm** - Float math tests
11. **FunctionTests.elm** - Function tests
12. **HigherOrderTests.elm** - Higher-order function tests
13. **LetDestructTests.elm** - Let destructuring tests
14. **LetRecTests.elm** - Recursive let tests
15. **LetTests.elm** - Let expression tests
16. **ListTests.elm** - List tests
17. **LiteralTests.elm** - Literal tests
18. **MultiDefTests.elm** - Multiple definition tests
19. **OperatorTests.elm** - Operator tests
20. **PatternArgTests.elm** - Pattern argument tests
21. **PatternMatchingTests.elm** - Pattern matching tests
22. **RecordTests.elm** - Record tests
23. **SpecializeAccessorTests.elm** - Accessor specialization tests
24. **SpecializeConstructorTests.elm** - Constructor specialization tests
25. **SpecializeCycleTests.elm** - Cycle specialization tests
26. **SpecializeExprTests.elm** - Expression specialization tests
27. **TupleTests.elm** - Tuple tests

### Integration Requirements for New Test Files

Each new test case file MUST:

1. **Export an `expectSuite` function** with signature:
   ```elm
   expectSuite : (Src.Module -> Expectation) -> String -> Test
   ```

2. **Be added to ALL 16 test suite aggregators** listed above by adding:
   ```elm
   , NewTestFile.expectSuite expectFn condStr
   ```
   to each aggregator's `expectSuite` function.

### Files to Update When Adding New Test Cases

When adding a new test case file (e.g., `PortEncodingTests.elm`), update these 16 files:

```
compiler/tests/Compiler/Canonicalize/GlobalNamesTest.elm
compiler/tests/Compiler/Canonicalize/IdAssignmentTest.elm
compiler/tests/Compiler/Generate/CEcoValueLayoutTest.elm
compiler/tests/Compiler/Generate/CodeGen/GenerateMLIRTest.elm
compiler/tests/Compiler/Generate/MonoFunctionArityTest.elm
compiler/tests/Compiler/Generate/MonoGraphIntegrityTest.elm
compiler/tests/Compiler/Generate/MonoLayoutIntegrityTest.elm
compiler/tests/Compiler/Generate/MonoNumericResolutionTest.elm
compiler/tests/Compiler/Generate/MonoTypeShapeTest.elm
compiler/tests/Compiler/Generate/TypedOptimizedMonomorphizeTest.elm
compiler/tests/Compiler/Optimize/AnnotationsPreservedTest.elm
compiler/tests/Compiler/Optimize/DeciderExhaustiveTest.elm
compiler/tests/Compiler/Optimize/FunctionTypeEncodeTest.elm
compiler/tests/Compiler/Optimize/OptimizeEquivalentTest.elm
compiler/tests/Compiler/Optimize/TypedOptTypesTest.elm
compiler/tests/Compiler/Type/Constrain/TypedErasedCheckingParityTest.elm
```

### Example: Adding PortEncodingTests to an Aggregator

In `TypedOptimizedMonomorphizeTest.elm`:

```elm
-- Add import
import Compiler.PortEncodingTests as PortEncodingTests

-- Add to expectSuite function
expectSuite expectFn condStr =
    Test.describe "..."
        [ AnnotatedTests.expectSuite expectFn condStr
        , ...
        , PortEncodingTests.expectSuite expectFn condStr  -- NEW
        , ...
        ]
```

This ensures that:
- Port encoding tests run through all 16 test logics
- Any new test logic automatically tests port encoding
- Coverage is maximized across all validation checks

---

## Expected Outcomes

### Coverage Improvements

| Module | Before | After (Expected) |
|--------|--------|------------------|
| Compiler.Optimize.Typed.Port | 0% | 80%+ |
| Compiler.Type.Constrain.Typed.Module | 23.5% | 70%+ |
| Compiler.Type.PostSolve | 49.6% | 85%+ |
| Compiler.Optimize.Typed.DecisionTree | 56.6% | 80%+ |
| Compiler.Optimize.Typed.Module | 61.1% | 80%+ |
| Compiler.Optimize.Typed.Expression | 77.7% | 90%+ |

### Test Failure Expectations

- Tests should NOT fail in Canonicalization or Type Checking phases
- Test failures in Monomorphization or MLIR codegen indicate potential compiler bugs
- Document all genuine failures for future compiler work

---

## Risk Mitigation

1. **Port module parsing**: May need special handling in test infrastructure
2. **Effect managers**: Complex module structure may require careful setup
3. **Kernel type resolution**: Some paths may be hard to trigger from Source IR

If infrastructure proves too complex for certain tests, fall back to:
- Using CanonicalBuilder directly for lower-level tests
- Creating simplified test helpers
- Documenting coverage gaps that require special infrastructure

---

## Success Criteria

1. All 220 test cases compile and run
2. No test failures in pre-monomorphization phases
3. Coverage improvements match expected targets
4. Test failures in later phases are documented for future work
