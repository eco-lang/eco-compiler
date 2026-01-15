# MLIR CodeGen Modularization Plan

## Overview

Refactor the monolithic `Compiler.Generate.CodeGen.MLIR` module (6296 lines) into 11 focused modules under `Compiler.Generate.MLIR.*`, with the original module becoming a thin shim.

## Current State

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
**Size**: 6296 lines
**Sections** (per code markers):
- BACKEND (line 43)
- ECO DIALECT TYPES (line 57)
- CONVERT MONOTYPE TO MLIR TYPE (line 89)
- CONTEXT (line 194)
- KERNEL DECLARATION TRACKING (line 472)
- SIGNATURE EXTRACTION (line 515)
- EXPRESSION RESULT (line 633)
- INTRINSIC DEFINITIONS (line 650)
- TYPE TABLE GENERATION (line 1098)
- TYPE KIND ENUMS (line 1206)
- GENERATE WHOLE PROGRAM (line 1629)
- LAMBDA PROCESSING (line 1699)
- PAP WRAPPER FUNCTION GENERATION (line 1824)
- GENERATE MAIN ENTRY (line 1955)
- GENERATE NODE (line 1987)
- GENERATE DEFINE (line 2056)
- GENERATE TAIL FUNC (line 2154)
- GENERATE CTOR (line 2206)
- GENERATE ENUM (line 2297)
- GENERATE EXTERN (line 2337)
- GENERATE CYCLE (line 2554)
- GENERATE EXPRESSION (line 2611)
- LITERAL GENERATION (line 2677)
- VARIABLE GENERATION (line 2766)
- LIST GENERATION (line 3062)
- CLOSURE GENERATION (line 3132)
- CALL GENERATION (line 3252)
- TAIL CALL GENERATION (line 4039)
- IF GENERATION (line 4098)
- LET GENERATION (line 4170)
- DESTRUCT GENERATION (line 4287)
- DECISION TREE PATH GENERATION (line 4414)
- CASE GENERATION (line 4863)
- RECORD GENERATION (line 5324)
- TUPLE GENERATION (line 5482)
- UNIT GENERATION (line 5560)
- ACCESSOR GENERATION (line 5581)
- HELPERS (line 5612)
- ECO DIALECT OP HELPERS (line 5641)

## Target Module Structure

```
compiler/src/Compiler/Generate/MLIR/
├── Types.elm       # Eco types, MonoType→MlirType conversion
├── Context.elm     # Context, signatures, type registry
├── Ops.elm         # MLIR op builders (eco.*, arith.*, scf.*, func.*)
├── Names.elm       # Symbol naming helpers (canonicalization, sanitization)
├── TypeTable.elm   # eco.type_table generation
├── Intrinsics.elm  # Basics/Bitwise kernel intrinsics
├── Patterns.elm    # Path navigation, test generation
├── Expr.elm        # Expression lowering, call ABI
├── Lambdas.elm     # Lambda/closure processing, PAP wrappers
├── Functions.elm   # Node/function generation (define, ctor, extern, cycle)
└── Backend.elm     # Program entry point, module wiring
```

## Module Dependency Graph

```
Types (no deps on other MLIR.* modules)
  ↓
Names (imports Types)
  ↓
Context (imports Types, Names)
  ↓
Ops (imports Context, Types)
  ↓
Intrinsics (imports Context, Types, Ops)
  ↓
Patterns (imports Context, Types, Ops)
  ↓
Expr (imports Context, Types, Ops, Intrinsics, Patterns, Names)
  ↓
Lambdas (imports Context, Types, Ops, Expr, Names)
  ↓
Functions (imports Context, Types, Ops, Expr, Names)
  ↓
Backend (imports Context, Functions, Lambdas, TypeTable)
  ↓
CodeGen.MLIR (shim: re-exports Backend.backend)
```

**No cycles**: Each module only imports from modules above it in the graph.

---

## Implementation Plan

### Phase 1: Foundation Modules (Types, Names, Context, Ops)

#### Step 1.1: Create `MLIR/Types.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Types.elm`

**Move from MLIR.elm** (ECO DIALECT TYPES and CONVERT MONOTYPE sections):
- `ecoValue`, `ecoInt`, `ecoFloat`, `ecoChar` (eco dialect types)
- `monoTypeToMlir` (MonoType → MlirType conversion)
- `isFunctionType`, `functionArity`, `countTotalArity`, `decomposeFunctionType`
- `isEcoValueType`, `mlirTypeToString`

**Exports**:
```elm
module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToMlir
    , isFunctionType, functionArity, countTotalArity, decomposeFunctionType
    , isEcoValueType
    , mlirTypeToString
    )
```

**Imports needed**:
```elm
import Compiler.AST.Monomorphized as Mono
import Mlir.Mlir exposing (MlirType(..))
```

**Update MLIR.elm**: Add `import Compiler.Generate.MLIR.Types as Types` and qualify all moved functions with `Types.`.

**Verify**: Run `npm run test:elm` to ensure compilation.

---

#### Step 1.2: Create `MLIR/Names.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Names.elm`

**Move from MLIR.elm** (HELPERS section, lines 5612-5636):
- `canonicalToMLIRName` - converts IO.Canonical to MLIR-safe name
- `sanitizeName` - escapes special characters in identifiers

**Exports**:
```elm
module Compiler.Generate.MLIR.Names exposing
    ( canonicalToMLIRName
    , sanitizeName
    )
```

**Imports needed**:
```elm
import System.TypeCheck.IO as IO
```

**Update MLIR.elm**: Add `import Compiler.Generate.MLIR.Names as Names` and qualify:
- `canonicalToMLIRName` → `Names.canonicalToMLIRName`
- `sanitizeName` → `Names.sanitizeName`

**Verify**: Run `npm run test:elm`.

---

#### Step 1.3: Create `MLIR/Context.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Move from MLIR.elm** (CONTEXT, KERNEL DECLARATION TRACKING, SIGNATURE EXTRACTION sections):
- Type aliases: `FuncSignature`, `Context`, `TypeRegistry`, `PendingLambda`, `PendingWrapper`
- Initialization: `initContext`, `emptyTypeRegistry`
- Variable management: `freshVar`, `freshOpId`, `lookupVar`, `addVarMapping`
- Type registry: `getOrCreateTypeIdForMonoType`, `registerNestedTypes`
- Kernel tracking: `registerKernelCall`
- Signature extraction: `extractNodeSignature`, `buildSignatures`
- Kernel ABI: `kernelFuncSignatureFromType`, `isTypeVar`, `hasKernelImplementation`

**Exports**:
```elm
module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, PendingLambda, PendingWrapper, TypeRegistry
    , initContext, emptyTypeRegistry
    , freshVar, freshOpId, lookupVar, addVarMapping
    , getOrCreateTypeIdForMonoType, registerNestedTypes
    , registerKernelCall
    , extractNodeSignature, buildSignatures
    , kernelFuncSignatureFromType, isTypeVar, hasKernelImplementation
    )
```

**Imports needed**:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Generate.Mode as Mode
import Compiler.Optimize.Typed.DecisionTree as DT
import Data.Map as EveryDict
import Dict
import Mlir.Mlir exposing (MlirType(..))
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Names as Names
```

**Update MLIR.elm**: Add `import Compiler.Generate.MLIR.Context as Ctx` and qualify moved items.

**Verify**: Run `npm run test:elm`.

---

#### Step 1.4: Create `MLIR/Ops.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Ops.elm`

**Move from MLIR.elm** (ECO DIALECT OP HELPERS section, lines 5641+):
- Builder plumbing: `opBuilder`, `mlirOp`
- Region helpers: `mkRegion`, `funcFunc`
- Constants: `ecoConstantUnit`, `ecoConstantEmptyRec`, `ecoConstantTrue`, `ecoConstantFalse`, `ecoConstantNil`, `ecoConstantNothing`, `ecoConstantEmptyString`
- Construction: `ecoConstructList`, `ecoConstructTuple2`, `ecoConstructTuple3`, `ecoConstructRecord`, `ecoConstructCustom`
- Projection: `ecoProjectListHead`, `ecoProjectListTail`, `ecoProjectTuple2`, `ecoProjectTuple3`, `ecoProjectRecord`, `ecoProjectCustom`
- Calls: `ecoCallNamed`, `ecoReturn`, `ecoStringLiteral`
- Arithmetic: `arithConstantInt`, `arithConstantInt32`, `arithConstantFloat`, `arithConstantBool`, `arithConstantChar`, `arithCmpI`
- Operators: `ecoUnaryOp`, `ecoBinaryOp`
- Control flow: `ecoCase`, `ecoJoinpoint`, `ecoGetTag`, `scfIf`, `scfYield`

**Key change**: `mlirOp` must call `Ctx.freshOpId` instead of local `freshOpId`.

**Exports**: All the above functions.

**Imports needed**:
```elm
import Dict
import OrderedDict
import Mlir.Loc as Loc
import Mlir.Mlir as Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirRegion(..), MlirType(..), Visibility(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
```

**Update MLIR.elm**: Add `import Compiler.Generate.MLIR.Ops as Ops` and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 2: Type Table and Intrinsics

#### Step 2.1: Create `MLIR/TypeTable.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/TypeTable.elm`

**Move from MLIR.elm** (TYPE TABLE GENERATION and TYPE KIND ENUMS sections, lines 1098-1626):
- `generateTypeTable`
- `TypeTableAccum` type alias
- Helper functions: `getOrCreateStringIndex`, `processType`, `addPrimitiveType`, `addPolymorphicType`, `lookupTypeId`, `addListType`, `addTupleType`, `addRecordType`, `addCustomType`, `addCtorInfo`, `addFunctionType`
- Enums: `TypeKind`, `PrimKind`, `typeKindToTag`, `primKindToTag`

**Exports**:
```elm
module Compiler.Generate.MLIR.TypeTable exposing
    ( generateTypeTable
    , TypeKind(..), PrimKind(..)
    )
```

**Imports needed**:
```elm
import Dict
import Data.Map as EveryDict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))
import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Context as Ctx
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

#### Step 2.2: Create `MLIR/Intrinsics.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`

**Move from MLIR.elm** (INTRINSIC DEFINITIONS section, lines 650-1095):
- `Intrinsic` type (all constructors: `UnaryInt`, `BinaryInt`, `UnaryFloat`, `BinaryFloat`, `UnaryBool`, `BinaryBool`, `IntToFloat`, `FloatToInt`, `IntComparison`, `FloatComparison`, `FloatClassify`, `ConstantFloat`)
- `intrinsicResultMlirType`, `intrinsicOperandTypes`
- `unboxArgsForIntrinsic`
- `kernelIntrinsic`, `basicsIntrinsic`, `bitwiseIntrinsic`
- `generateIntrinsicOp`

**Exports**:
```elm
module Compiler.Generate.MLIR.Intrinsics exposing
    ( Intrinsic(..)
    , kernelIntrinsic
    , intrinsicResultMlirType, intrinsicOperandTypes
    , unboxArgsForIntrinsic
    , generateIntrinsicOp
    )
```

**Imports needed**:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Mlir.Mlir exposing (MlirOp, MlirType(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Ops as Ops
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 3: Patterns Module

#### Step 3.1: Create `MLIR/Patterns.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Patterns.elm`

**Move from MLIR.elm** (DECISION TREE PATH GENERATION section, selectively):
- `generateMonoPath`
- `generateDTPath`
- `generateTest`
- `generateChainCondition`
- `testToTagInt`
- `caseKindFromTest`
- `computeFallbackTag`

**DO NOT move** (these stay in Expr to avoid cycles):
- `generateDestruct`
- `generateSharedJoinpoints`
- `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`, `generateCase`

**Exports**:
```elm
module Compiler.Generate.MLIR.Patterns exposing
    ( generateMonoPath
    , generateDTPath
    , generateTest
    , generateChainCondition
    , testToTagInt
    , caseKindFromTest
    , computeFallbackTag
    )
```

**Imports needed**:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Optimize.Typed.DecisionTree as DT
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Ops as Ops
import Utils.Crash exposing (crash)
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 4: Expression Module

#### Step 4.1: Create `MLIR/Expr.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Move from MLIR.elm**:

*Expression result* (EXPRESSION RESULT section):
- `ExprResult` type alias
- `emptyResult`

*Expression generation* (GENERATE EXPRESSION through ACCESSOR GENERATION sections, lines 2611-5610):
- `generateExpr`
- `generateLiteral`
- `generateVarGlobal`, `generateVarKernel`
- `generateList`
- `generateClosure` (calls out to Lambdas for registration)
- `generateCall`, `generateClosureApplication`, `generateSaturatedCall`
- `generateTailCall`
- `generateIf`
- `generateLet`, `collectLetBoundNames`, `addPlaceholderMappings`
- `generateDestruct` (calls Patterns for path ops)
- Case/decision tree: `generateCase`, `generateSharedJoinpoints`, `generateDecider`, `generateLeaf`, `generateChain`, `generateChainForBoolADT`, `generateChainGeneral`, `generateFanOut`, `generateBoolFanOut`, `findBoolBranches`, `generateFanOutGeneral`, `mkRegionFromOps`, `defaultTerminator`
- `generateRecordCreate`, `generateRecordAccess`, `generateRecordUpdate`
- `generateTupleCreate`
- `generateUnit`
- `generateAccessor`

*Call/boxing utilities*:
- `boxToEcoValue`
- `boxToMatchSignatureTyped`
- `unboxToType`
- `coerceResultToType`
- `generateExprListTyped`
- `boxArgsWithMlirTypes`
- `createDummyValue` (kept here per user direction)

**Exports**:
```elm
module Compiler.Generate.MLIR.Expr exposing
    ( ExprResult
    , emptyResult
    , generateExpr
    , generateList
    , generateClosure
    , generateCall
    , generateTailCall
    , generateIf
    , generateLet
    , generateRecordCreate, generateRecordAccess, generateRecordUpdate
    , generateTupleCreate
    , generateUnit
    , generateAccessor
    , boxToEcoValue, boxToMatchSignatureTyped, unboxToType, coerceResultToType
    , generateExprListTyped, boxArgsWithMlirTypes
    , createDummyValue
    )
```

**Imports needed**:
```elm
import Dict
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Generate.Mode as Mode
import Compiler.Optimize.Typed.DecisionTree as DT
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)
import Mlir.Mlir exposing (MlirOp, MlirType(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Patterns as Patterns
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 5: Lambdas Module

#### Step 5.1: Create `MLIR/Lambdas.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`

**Move from MLIR.elm** (LAMBDA PROCESSING and PAP WRAPPER sections, lines 1699-1953):
- `processLambdas` - iteratively processes pending lambdas
- `generateLambdaFunc` - generates func.func for a lambda
- `processPendingWrappers` - iteratively processes pending PAP wrappers
- `generatePapWrapper` - generates PAP wrapper function
- `lambdaIdToString` - converts lambda ID to MLIR function name

**Exports**:
```elm
module Compiler.Generate.MLIR.Lambdas exposing
    ( processLambdas
    , processPendingWrappers
    , lambdaIdToString
    )
```

**Imports needed**:
```elm
import Compiler.AST.Monomorphized as Mono
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..), Visibility(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Expr as Expr
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 6: Functions Module

#### Step 6.1: Create `MLIR/Functions.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Functions.elm`

**Move from MLIR.elm** (remaining node/function generation):

*Node/main generation*:
- `generateNode`
- `generateMainEntry`
- `specIdToFuncName`

*Function generators*:
- `generateDefine`
- `generateClosureFunc`
- `generateTailFunc`

*Constructors/enums/externs/cycles*:
- `generateCtor`
- `generateEnum`
- `generateExtern`
- `generateCycle`

*Stubs*:
- `generateStubValue`
- `generateKernelDecl`
- `generateStubValueFromMlirType`

**Exports**:
```elm
module Compiler.Generate.MLIR.Functions exposing
    ( generateNode
    , generateMainEntry
    , generateKernelDecl
    , specIdToFuncName
    )
```

**Imports needed**:
```elm
import Dict
import Data.Map as EveryDict
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name as Name
import Compiler.Generate.Mode as Mode
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..), MlirType(..), Visibility(..))
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Ops as Ops
```

**Update MLIR.elm**: Import and qualify.

**Verify**: Run `npm run test:elm`.

---

### Phase 7: Backend and Shim

#### Step 7.1: Create `MLIR/Backend.elm`

**Create file**: `compiler/src/Compiler/Generate/MLIR/Backend.elm`

**Move from MLIR.elm** (BACKEND and GENERATE WHOLE PROGRAM sections):
- `backend`
- `generateProgram`

**Exports**:
```elm
module Compiler.Generate.MLIR.Backend exposing (backend)
```

**Imports needed**:
```elm
import Dict
import Data.Map as EveryDict
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule)
import Mlir.Pretty as Pretty
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Functions as Funcs
import Compiler.Generate.MLIR.Lambdas as Lambdas
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.MLIR.Types as Types
```

**Verify**: Run `npm run test:elm`.

---

#### Step 7.2: Convert `CodeGen/MLIR.elm` to Shim

**Replace contents** of `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` with:

```elm
module Compiler.Generate.CodeGen.MLIR exposing (backend)

import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MlirBackend


backend : CodeGen.MonoCodeGen
backend =
    MlirBackend.backend
```

**Verify**: Run `npm run test:elm` and full test suite `npm test`.

---

## Validation Strategy

After each step:
1. Run `npm run elm-format` to format new files
2. Run `npm run test:elm` for Elm compilation and tests
3. Run `npm test` periodically for full validation

After final step:
1. Run full `npm test` suite
2. Existing tests validate the refactoring doesn't change behavior

---

## Rollback Strategy

Each phase creates new modules while leaving the original intact. If a phase fails:
1. Delete the newly created module file
2. Revert changes to `MLIR.elm`
3. Investigate and fix before retrying

---

## Summary

| Phase | Module(s) Created | Key Contents |
|-------|-------------------|--------------|
| 1.1 | Types.elm | Eco types, MonoType→MlirType |
| 1.2 | Names.elm | canonicalToMLIRName, sanitizeName |
| 1.3 | Context.elm | Context, signatures, type registry |
| 1.4 | Ops.elm | MLIR op builders |
| 2.1 | TypeTable.elm | eco.type_table generation |
| 2.2 | Intrinsics.elm | Basics/Bitwise intrinsics |
| 3.1 | Patterns.elm | Path navigation, test generation |
| 4.1 | Expr.elm | Expression lowering, call ABI |
| 5.1 | Lambdas.elm | Lambda/PAP wrapper processing |
| 6.1 | Functions.elm | Node/function generation |
| 7.1 | Backend.elm | Program entry, module wiring |
| 7.2 | Shim | Re-export Backend.backend |

**Final structure**: 11 focused modules + 1 shim, replacing 1 monolithic 6296-line file.

---

## Parallelization Opportunities

The following steps can be executed in parallel since they have no inter-dependencies:

**Parallel Group A** (after Phase 1 completes):
- Step 2.1: TypeTable.elm
- Step 2.2: Intrinsics.elm
- Step 3.1: Patterns.elm

All three depend only on Types, Names, Context, and Ops—none depend on each other.

**Parallel Group B** (after Expr completes):
- Step 5.1: Lambdas.elm
- Step 6.1: Functions.elm

Both depend on Expr but not on each other.

**Sequential requirements**:
- Phase 1 (Types → Names → Context → Ops) must be sequential due to import dependencies
- Phase 4 (Expr) must wait for all of Group A
- Phase 7 (Backend + Shim) must wait for all prior phases

---

## Design Decisions

1. **Lambda registration stays inline**: `generateClosure` in `Expr.elm` directly updates `ctx.pendingLambdas` rather than calling out to a helper in `Lambdas.elm`. This avoids a circular dependency since Lambdas imports Expr.

2. **`createDummyValue` in Expr.elm**: Kept with expression generation since it's used in case lowering for unreachable branches.

3. **`lambdaIdToString` in Lambdas.elm**: Logically belongs with lambda processing; uses `Names.canonicalToMLIRName` internally.
