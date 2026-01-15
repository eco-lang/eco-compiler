Below is a concrete refactor plan you can hand to an engineer. It assumes the current big module is:
```elm
module Compiler.Generate.CodeGen.MLIR exposing (backend)
```

and lives at:
```text
compiler/src/Compiler/Generate/CodeGen/MLIR.elm
```

You will introduce new `Compiler.Generate.MLIR.*` modules under:
```text
compiler/src/Compiler/Generate/MLIR/
```

and then turn `CodeGen.MLIR` into a thin compatibility shim.
I’ll go module by module, specifying:
- File path + module header.
- Which existing definitions move there.
- What imports they should have and which references must be updated.
- How the remaining modules should call them.
---
## Step 0 – Create the new directory

Create:
```text
compiler/src/Compiler/Generate/MLIR/
```

No code changes yet.
---
## Step 1 – `MLIR.Types` (Mono types ↔ MLIR types)
### 1.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Types.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Types exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToMlir
    , isFunctionType, functionArity, countTotalArity, decomposeFunctionType
    , isEcoValueType
    , mlirTypeToString
    )
```
### 1.2 Move definitions from old module

Cut the following from `CodeGen.MLIR` into `MLIR.Types`:
- Eco dialect MLIR types:
  ```elm
  ecoValue : MlirType
  ecoInt   : MlirType
  ecoFloat : MlirType
  ecoChar  : MlirType
  ```

- MonoType → MlirType:
  ```elm
  monoTypeToMlir : Mono.MonoType -> MlirType
  ```

- Function shape helpers:
  ```elm
  isFunctionType : Mono.MonoType -> Bool
  functionArity : Mono.MonoType -> Int
  countTotalArity : Mono.MonoType -> Int
  decomposeFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
  ```

- Boxed/MLIR helpers:
  ```elm
  isEcoValueType : MlirType -> Bool
  mlirTypeToString : MlirType -> String
  ```
### 1.3 Imports for `MLIR.Types`

Add:
```elm
import Compiler.AST.Monomorphized as Mono
import Mlir.Mlir exposing ( MlirType(..) )
```

(You also need `NamedStruct` constructor, etc., hence `MlirType(..)`.)
### 1.4 Adjust remaining modules later

Every place in the old file that referred to:
- `ecoValue`, `ecoInt`, `ecoFloat`, `ecoChar`
- `monoTypeToMlir` / `isFunctionType` / `functionArity` / `countTotalArity` / `decomposeFunctionType`
- `isEcoValueType`, `mlirTypeToString`

will now need:
- `ecoValue`, `ecoInt`, `ecoFloat`, `ecoChar`
- `monoTypeToMlir` / `isFunctionType` / `functionArity` / `countTotalArity` / `decomposeFunctionType`
- `isEcoValueType`, `mlirTypeToString`

will now need:
```elm
import Compiler.Generate.MLIR.Types as Types
```

and then use `Types.ecoValue`, `Types.monoTypeToMlir`, etc.
You don’t need to do all imports now; just be aware for later steps when you split those modules.
---
## Step 2 – `MLIR.Context` (codegen context & signatures)
### 2.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Context.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Context exposing
    ( Context
    , FuncSignature
    , PendingLambda, PendingWrapper
    , TypeRegistry
    , initContext, emptyTypeRegistry
    , freshVar, freshOpId
    , lookupVar, addVarMapping
    , getOrCreateTypeIdForMonoType, registerNestedTypes
    , extractNodeSignature, buildSignatures
    , kernelFuncSignatureFromType
    , isTypeVar
    , hasKernelImplementation
    )
```

(You can tighten the expose list as you like, but this covers usage in your existing file.)
### 2.2 Move type definitions and helpers

Move the whole “CONTEXT” and “SIGNATURE EXTRACTION” sections from the old module into this file:
- Type aliases:
  ```elm
  type alias FuncSignature =
      { paramTypes : List Mono.MonoType
      , returnType : Mono.MonoType
      }

  type alias Context = { ... }
  type alias TypeRegistry = { ... }
  type alias PendingLambda = { ... }
  type alias PendingWrapper = { ... }
  ```

- Initialization & context helpers:
  ```elm
  initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict.Dict Int FuncSignature -> EveryDict.Dict ... -> Context
  emptyTypeRegistry : TypeRegistry
  freshVar : Context -> ( String, Context )
  freshOpId : Context -> ( String, Context )
  lookupVar : Context -> String -> ( String, MlirType )
  addVarMapping : String -> String -> MlirType -> Context -> Context
  ```

- Type registry helpers:
  ```elm
  getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
  registerNestedTypes : Mono.MonoType -> Context -> Context
  ```

- Kernel declaration tracking:
  ```elm
  registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
  ```

  (Expose or keep internal depending on who uses it; today `ecoCallNamed` uses it.)
- Signature extraction:
  ```elm
  extractNodeSignature : Mono.MonoNode -> Maybe FuncSignature
  buildSignatures : EveryDict.Dict Int Int Mono.MonoNode -> Dict.Dict Int FuncSignature
  ```

- Kernel ABI helpers:
  ```elm
  kernelFuncSignatureFromType : Mono.MonoType -> FuncSignature
  isTypeVar : Mono.MonoType -> Bool
  hasKernelImplementation : String -> String -> Bool
  ```
### 2.3 Imports for `MLIR.Context`

Add at top:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Optimize.Typed.DecisionTree as DT
import Data.Map as EveryDict
import Dict
import Mlir.Mlir exposing ( MlirType(..) )
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)

import Compiler.Generate.MLIR.Types as Types
```

Use `Types.ecoValue` where you previously used `ecoValue`, etc.
### 2.4 Local adjustments

- `freshOpId` and `freshVar` still work the same; later, when we move `mlirOp` to `MLIR.Ops`, we’ll refer back to `Context.freshOpId`.
- In `lookupVar`, switch direct `ecoValue` references to `Types.ecoValue`.
Any direct `Debug.todo` or `Debug.toString` usage can stay; you already had them.
---
## Step 3 – `MLIR.Ops` (builder helpers for eco/arith/func/scf)
### 3.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Ops.elm
```

with header roughly:
```elm
module Compiler.Generate.MLIR.Ops exposing
    ( opBuilder, mlirOp
    , mkRegion
    , funcFunc
    , ecoConstantUnit, ecoConstantEmptyRec, ecoConstantTrue, ecoConstantFalse
    , ecoConstantNil, ecoConstantNothing, ecoConstantEmptyString
    , ecoConstructList, ecoConstructTuple2, ecoConstructTuple3
    , ecoConstructRecord, ecoConstructCustom
    , ecoProjectListHead, ecoProjectListTail
    , ecoProjectTuple2, ecoProjectTuple3
    , ecoProjectRecord, ecoProjectCustom
    , ecoCallNamed, ecoReturn, ecoStringLiteral
    , arithConstantInt, arithConstantInt32, arithConstantFloat
    , arithConstantBool, arithConstantChar, arithCmpI
    , ecoUnaryOp, ecoBinaryOp
    , ecoCase, ecoJoinpoint, ecoGetTag
    , scfIf, scfYield
    )
```

(Again, you can restrict the expose list later.)
### 3.2 Move all “ECO DIALECT OP HELPERS” and related MLIR builders

From the bottom of the old file, move these:
- Builder plumbing:
  ```elm
  opBuilder : Mlir.OpBuilderFns e
  opBuilder = Mlir.opBuilder

  mlirOp : Context -> String -> Mlir.OpBuilder Context
  ```

  **Change here:** `mlirOp` must now call `Context.freshOpId` instead of the local `freshOpId`, e.g.:
  ```elm
  import Compiler.Generate.MLIR.Context as Ctx

  mlirOp ctx =
      Mlir.mlirOp (\e -> Ctx.freshOpId e |> (\( id, ctx1 ) -> ( ctx1, id ))) ctx
  ```

- `mkRegion`, `funcFunc`
- All `ecoConstant*` helpers

- All `ecoConstruct*` and `ecoProject*` helpers

- `ecoCallNamed`, `ecoReturn`, `ecoStringLiteral`

- `arithConstantInt`, `arithConstantInt32`, `arithConstantFloat`, `arithConstantBool`, `arithConstantChar`, `arithCmpI`

- `ecoUnaryOp`, `ecoBinaryOp`

- `ecoCase`, `ecoJoinpoint`, `ecoGetTag`, `scfIf`, `scfYield`

Also move the small `defaultTerminator` and `mkRegionFromOps` if you want them centralised; or leave them where pattern lowering lives (we’ll decide in the Patterns step).
- All `ecoConstant*` helpers

- All `ecoConstruct*` and `ecoProject*` helpers

- `ecoCallNamed`, `ecoReturn`, `ecoStringLiteral`

- `arithConstantInt`, `arithConstantInt32`, `arithConstantFloat`, `arithConstantBool`, `arithConstantChar`, `arithCmpI`

- `ecoUnaryOp`, `ecoBinaryOp`

- `ecoCase`, `ecoJoinpoint`, `ecoGetTag`, `scfIf`, `scfYield`

Also move the small `defaultTerminator` and `mkRegionFromOps` if you want them centralised; or leave them where pattern lowering lives (we’ll decide in the Patterns step).
### 3.3 Imports for `MLIR.Ops`

Add:
```elm
import Dict
import OrderedDict

import Mlir.Loc as Loc
import Mlir.Mlir as Mlir
    exposing
        ( MlirAttr(..)
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
```

Inside this module:
- Replace plain `ecoValue` with `Types.ecoValue`.
- Where you previously used `freshOpId` or `freshVar`, now use `Ctx.freshOpId`/`Ctx.freshVar` if needed (most ops just return `(Context, MlirOp)` without needing new SSA vars).
- In `ecoCallNamed`, keep the call to `registerKernelCall`, but now it is `Ctx.registerKernelCall`.
---
## Step 4 – `MLIR.TypeTable` (global type graph / eco.type_table)
### 4.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/TypeTable.elm
```

with header:
```elm
module Compiler.Generate.MLIR.TypeTable exposing
    ( generateTypeTable
    )
```

and if you want to reuse the enums elsewhere:
```elm
    , TypeKind(..), PrimKind(..)
```
### 4.2 Move all “TYPE TABLE GENERATION” code

From the old file, move:
- `generateTypeTable : Context -> MlirOp`

- Type and helpers:
  ```elm
  type alias TypeTableAccum = { ... }

  getOrCreateStringIndex
  type TypeKind = ...
  type PrimKind = ...

  typeKindToTag
  primKindToTag

  processType
  addPrimitiveType
  addPolymorphicType
  lookupTypeId
  addListType
  addTupleType
  addRecordType
  addCustomType
  addCtorInfo
  addFunctionType
  ```
### 4.3 Imports for `MLIR.TypeTable`

Add:
```elm
import Dict
import Data.Map as EveryDict

import Mlir.Mlir
    exposing
        ( MlirAttr(..)
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        )

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Context as Ctx
```

Use `Ctx.Context` and access `ctx.typeRegistry` etc. Use `Mono.toComparableMonoType` and layouts from `Mono`.
No change in logic, just moved.
### 4.4 Call site change

In your future `Backend` module, you will replace the old local `generateTypeTable` usage with:
```elm
import Compiler.Generate.MLIR.TypeTable as TypeTable

...

let
    typeTableOp =
        TypeTable.generateTypeTable finalCtx
in
...
```
---
## Step 5 – `MLIR.Intrinsics` (Basics/Bitwise → eco.* operations)
### 5.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Intrinsics.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Intrinsics exposing
    ( Intrinsic(..)
    , kernelIntrinsic
    , intrinsicResultMlirType
    , intrinsicOperandTypes
    , unboxArgsForIntrinsic
    , generateIntrinsicOp
    )
```
### 5.2 Move intrinsic definitions

From the old file, move all under “INTRINSIC DEFINITIONS”:
- The `Intrinsic` type and all its constructors:
  ```elm
  type Intrinsic
      = UnaryInt { op : String }
      | BinaryInt { op : String }
      | ...
  ```

- `intrinsicResultMlirType`
- `intrinsicOperandTypes`
- `unboxArgsForIntrinsic`
- `kernelIntrinsic`
- `basicsIntrinsic`
- `bitwiseIntrinsic`
- `generateIntrinsicOp`
### 5.3 Imports for `MLIR.Intrinsics`

Add:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name

import Mlir.Mlir exposing ( MlirOp, MlirType(..) )

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Ops as Ops
```

And then:
- Replace local `ecoInt`, `ecoFloat`, etc. with `Types.ecoInt`, `Types.ecoFloat`, etc.
- Replace `isEcoValueType` with `Types.isEcoValueType`.
- Use `Ops.ecoUnaryOp`, `Ops.ecoBinaryOp`, `Ops.arithConstantFloat`.

Callers later (in `Expr`) will do:
- Replace local `ecoInt`, `ecoFloat`, etc. with `Types.ecoInt`, `Types.ecoFloat`, etc.
- Replace `isEcoValueType` with `Types.isEcoValueType`.
- Use `Ops.ecoUnaryOp`, `Ops.ecoBinaryOp`, `Ops.arithConstantFloat`.

Callers later (in `Expr`) will do:
```elm
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
```

and use `Intrinsics.kernelIntrinsic`, `Intrinsics.generateIntrinsicOp`, etc.
---
## Step 6 – `MLIR.Expr` (expressions, calls, lists, records, tuples, if/let)

Now we create the main “expression lowering” module and move most `generateExpr` branches + related helpers here.
### 6.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Expr.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Expr exposing
    ( ExprResult(..)
    , emptyResult
    , generateExpr
    , generateList
    , generateClosure
    , generateCall
    , generateTailCall
    , generateIf
    , generateLet
    , generateRecordCreate
    , generateRecordAccess
    , generateRecordUpdate
    , generateTupleCreate
    , generateUnit
    , generateAccessor
    )
```

You may keep the expose list shorter, but `Functions` and `Patterns` will at least need `ExprResult` and `generateExpr`, plus some specific helpers.
### 6.2 Move `ExprResult` & helpers

From old file, move:
- `type alias ExprResult = { ops : List MlirOp, resultVar : String, resultType : MlirType, ctx : Context }`
- `emptyResult`

Make sure to import `MlirOp`, `MlirType`, and `Context`.
- `type alias ExprResult = { ops : List MlirOp, resultVar : String, resultType : MlirType, ctx : Context }`
- `emptyResult`

Make sure to import `MlirOp`, `MlirType`, and `Context`.
### 6.3 Move `generateExpr` and all “non-pattern” branches

From “GENERATE EXPRESSION” and associated sections, move:
- `generateExpr`
- `generateLiteral`
- `generateVarGlobal`
- `generateVarKernel`
- `generateList`
- `generateClosure`
- `generateCall`, `generateClosureApplication`, `generateSaturatedCall`
- `generateTailCall`
- `generateIf`
- `generateLet`
- `generateRecordCreate`, `generateRecordAccess`, `generateRecordUpdate`
- `generateTupleCreate`
- `generateUnit`
- `generateAccessor`
### 6.4 Move *call/boxing/coercion utilities* here

These logically belong with calls & expression results:
- `boxToEcoValue`
- `boxToMatchSignatureTyped`
- `unboxToType`
- `coerceResultToType`
- `generateExprListTyped`
- `boxArgsWithMlirTypes`
- `createDummyValue` (you can alternatively keep this in `Functions` if it’s only used there + patterns; but it’s about “expression of a dummy value”, so either works.)
### 6.5 Imports for `MLIR.Expr`

You’ll need:
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

import Mlir.Mlir exposing ( MlirOp, MlirType(..) )

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Patterns as Patterns -- will be added in step 7
```

Then adjust all references:
- Replace `ecoValue` with `Types.ecoValue` (and similarly `ecoInt`, etc.).
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `isEcoValueType` with `Types.isEcoValueType`.
- Replace direct op helpers with `Ops.*` (e.g. `ecoConstantUnit` → `Ops.ecoConstantUnit`).
- Replace intrinsic calls:

  - `kernelIntrinsic` → `Intrinsics.kernelIntrinsic`
  - `generateIntrinsicOp` → `Intrinsics.generateIntrinsicOp`
  - `unboxArgsForIntrinsic` → `Intrinsics.unboxArgsForIntrinsic`

- Replace context helpers:

  - `freshVar` → `Ctx.freshVar`
  - `lookupVar` → `Ctx.lookupVar`
  - `addVarMapping` → `Ctx.addVarMapping`
  - `getOrCreateTypeIdForMonoType` → `Ctx.getOrCreateTypeIdForMonoType`
  - `kernelFuncSignatureFromType` → `Ctx.kernelFuncSignatureFromType`
  - `buildSignatures` is not used here; that stays at graph level.

- Replace `mlirTypeToString` with `Types.mlirTypeToString`.

Where you previously called `eco.call`, `eco.return`, etc., use `Ops.ecoCallNamed`, `Ops.ecoReturn`, etc.

For now, **leave `generateDestruct` and `generateCase` here**; in step 7 we’ll pull the low‑level path/test helpers into `MLIR.Patterns`, but keep the higher-level case lowering in this `Expr` module to avoid cyclic deps.
- Replace `ecoValue` with `Types.ecoValue` (and similarly `ecoInt`, etc.).
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `isEcoValueType` with `Types.isEcoValueType`.
- Replace direct op helpers with `Ops.*` (e.g. `ecoConstantUnit` → `Ops.ecoConstantUnit`).
- Replace intrinsic calls:

  - `kernelIntrinsic` → `Intrinsics.kernelIntrinsic`
  - `generateIntrinsicOp` → `Intrinsics.generateIntrinsicOp`
  - `unboxArgsForIntrinsic` → `Intrinsics.unboxArgsForIntrinsic`

- Replace context helpers:

  - `freshVar` → `Ctx.freshVar`
  - `lookupVar` → `Ctx.lookupVar`
  - `addVarMapping` → `Ctx.addVarMapping`
  - `getOrCreateTypeIdForMonoType` → `Ctx.getOrCreateTypeIdForMonoType`
  - `kernelFuncSignatureFromType` → `Ctx.kernelFuncSignatureFromType`
  - `buildSignatures` is not used here; that stays at graph level.

- Replace `mlirTypeToString` with `Types.mlirTypeToString`.

Where you previously called `eco.call`, `eco.return`, etc., use `Ops.ecoCallNamed`, `Ops.ecoReturn`, etc.

For now, **leave `generateDestruct` and `generateCase` here**; in step 7 we’ll pull the low‑level path/test helpers into `MLIR.Patterns`, but keep the higher-level case lowering in this `Expr` module to avoid cyclic deps.
- Replace `ecoValue` with `Types.ecoValue` (and similarly `ecoInt`, etc.).
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `isEcoValueType` with `Types.isEcoValueType`.
- Replace direct op helpers with `Ops.*` (e.g. `ecoConstantUnit` → `Ops.ecoConstantUnit`).
- Replace intrinsic calls:

  - `kernelIntrinsic` → `Intrinsics.kernelIntrinsic`
  - `generateIntrinsicOp` → `Intrinsics.generateIntrinsicOp`
  - `unboxArgsForIntrinsic` → `Intrinsics.unboxArgsForIntrinsic`

- Replace context helpers:

  - `freshVar` → `Ctx.freshVar`
  - `lookupVar` → `Ctx.lookupVar`
  - `addVarMapping` → `Ctx.addVarMapping`
  - `getOrCreateTypeIdForMonoType` → `Ctx.getOrCreateTypeIdForMonoType`
  - `kernelFuncSignatureFromType` → `Ctx.kernelFuncSignatureFromType`
  - `buildSignatures` is not used here; that stays at graph level.

- Replace `mlirTypeToString` with `Types.mlirTypeToString`.

Where you previously called `eco.call`, `eco.return`, etc., use `Ops.ecoCallNamed`, `Ops.ecoReturn`, etc.

For now, **leave `generateDestruct` and `generateCase` here**; in step 7 we’ll pull the low‑level path/test helpers into `MLIR.Patterns`, but keep the higher-level case lowering in this `Expr` module to avoid cyclic deps.
---
## Step 7 – `MLIR.Patterns` (MonoPath + DT.Path/test helpers)

To avoid cycles, we move the “path navigation” and “primitive test” helpers to their own module, and leave the high‑level `generateCase` / `generateDecider` in `MLIR.Expr`, which just *call* into these helpers.
### 7.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Patterns.elm
```

with header:
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
### 7.2 Move low-level destruct/DT helpers

From the old file, move **only**:
- `generateMonoPath`
- `generateDTPath`
- `generateTest`
- `generateChainCondition`
- `testToTagInt`
- `caseKindFromTest`
- `computeFallbackTag`

Do **not** move:

- `generateDestruct` (stays in `Expr`)
- `generateSharedJoinpoints`
- `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`, `generateCase`, etc. (all stay in `Expr` for now)

This way, `MLIR.Patterns` has no dependency on `generateExpr` or `ExprResult`, and `MLIR.Expr` can just call into it without cyclic imports.
- `generateMonoPath`
- `generateDTPath`
- `generateTest`
- `generateChainCondition`
- `testToTagInt`
- `caseKindFromTest`
- `computeFallbackTag`

Do **not** move:

- `generateDestruct` (stays in `Expr`)
- `generateSharedJoinpoints`
- `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`, `generateCase`, etc. (all stay in `Expr` for now)

This way, `MLIR.Patterns` has no dependency on `generateExpr` or `ExprResult`, and `MLIR.Expr` can just call into it without cyclic imports.
- `generateMonoPath`
- `generateDTPath`
- `generateTest`
- `generateChainCondition`
- `testToTagInt`
- `caseKindFromTest`
- `computeFallbackTag`

Do **not** move:

- `generateDestruct` (stays in `Expr`)
- `generateSharedJoinpoints`
- `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`, `generateCase`, etc. (all stay in `Expr` for now)

This way, `MLIR.Patterns` has no dependency on `generateExpr` or `ExprResult`, and `MLIR.Expr` can just call into it without cyclic imports.
- `generateMonoPath`
- `generateDTPath`
- `generateTest`
- `generateChainCondition`
- `testToTagInt`
- `caseKindFromTest`
- `computeFallbackTag`

Do **not** move:

- `generateDestruct` (stays in `Expr`)
- `generateSharedJoinpoints`
- `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`, `generateCase`, etc. (all stay in `Expr` for now)

This way, `MLIR.Patterns` has no dependency on `generateExpr` or `ExprResult`, and `MLIR.Expr` can just call into it without cyclic imports.
### 7.3 Imports for `MLIR.Patterns`

Add:
```elm
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Optimize.Typed.DecisionTree as DT

import Mlir.Mlir exposing ( MlirOp, MlirRegion(..), MlirType(..) )

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Ops as Ops
import Utils.Crash exposing (crash)
```

And adjust:
- `freshVar` → `Ctx.freshVar`
- `ecoProjectListHead` → `Ops.ecoProjectListHead`
- `ecoGetTag` → `Ops.ecoGetTag`
- `arithConstantInt32` → `Ops.arithConstantInt32`, etc.
- `ecoBinaryOp` → `Ops.ecoBinaryOp`
- `ecoStringLiteral` → `Ops.ecoStringLiteral`
- `ecoCallNamed` → `Ops.ecoCallNamed`
- `arithConstantBool` → `Ops.arithConstantBool`
- `arithConstantChar` → `Ops.arithConstantChar`
- `arithCmpI` → `Ops.arithCmpI`

Replace `ecoValue` with `Types.ecoValue`, `ecoChar` with `Types.ecoChar`.
- `freshVar` → `Ctx.freshVar`
- `ecoProjectListHead` → `Ops.ecoProjectListHead`
- `ecoGetTag` → `Ops.ecoGetTag`
- `arithConstantInt32` → `Ops.arithConstantInt32`, etc.
- `ecoBinaryOp` → `Ops.ecoBinaryOp`
- `ecoStringLiteral` → `Ops.ecoStringLiteral`
- `ecoCallNamed` → `Ops.ecoCallNamed`
- `arithConstantBool` → `Ops.arithConstantBool`
- `arithConstantChar` → `Ops.arithConstantChar`
- `arithCmpI` → `Ops.arithCmpI`

Replace `ecoValue` with `Types.ecoValue`, `ecoChar` with `Types.ecoChar`.
### 7.4 Update `MLIR.Expr` to use `Patterns`

In `MLIR.Expr`:
- Replace calls to the old local `generateMonoPath` with `Patterns.generateMonoPath`.
- Replace uses of `generateDTPath`, `generateTest`, etc., the same way:

  - In `generateDestruct`: call `Patterns.generateMonoPath`.
  - In case‑lowering functions: call `Patterns.generateDTPath`, `Patterns.generateTest`, `Patterns.generateChainCondition`, `Patterns.testToTagInt`, `Patterns.caseKindFromTest`, `Patterns.computeFallbackTag`.

Remove the old copies of those functions from `Expr`.
- Replace calls to the old local `generateMonoPath` with `Patterns.generateMonoPath`.
- Replace uses of `generateDTPath`, `generateTest`, etc., the same way:

  - In `generateDestruct`: call `Patterns.generateMonoPath`.
  - In case‑lowering functions: call `Patterns.generateDTPath`, `Patterns.generateTest`, `Patterns.generateChainCondition`, `Patterns.testToTagInt`, `Patterns.caseKindFromTest`, `Patterns.computeFallbackTag`.

Remove the old copies of those functions from `Expr`.
---
## Step 8 – `MLIR.Functions` (nodes, functions, lambdas, wrappers, externs, cycles)
### 8.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Functions.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Functions exposing
    ( generateNode
    , generateMainEntry
    , processLambdas
    , processPendingWrappers
    )
```

Optionally also expose `specIdToFuncName` if other modules need it.
### 8.2 Move node/function-level generators

From the old file, move:
- Node dispatch and main:
  ```elm
  generateNode
  generateMainEntry
  specIdToFuncName
  ```

- Define / closure / tail functions:
  ```elm
  generateDefine
  generateClosureFunc
  generateTailFunc
  ```

- Constructors, enums, externs, cycles:
  ```elm
  generateCtor
  generateEnum
  generateExtern
  generateCycle
  ```

- Lambdas & wrappers:
  ```elm
  processLambdas
  generateLambdaFunc
  processPendingWrappers
  generatePapWrapper
  lambdaIdToString
  ```

- Stub/extern helpers (used by generateExtern/generateKernelDecl):
  ```elm
  generateStubValue
  generateKernelDecl
  generateStubValueFromMlirType
  ```

If `createDummyValue` is still in `Expr`, leave it there and call it from `Expr`’s case‑lowering; if you prefer to move it, you can move it here and expose it, then adjust `Expr`.
### 8.3 Imports for `MLIR.Functions`

Add:
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
import Mlir.Mlir exposing ( MlirModule, MlirOp, MlirRegion(..), MlirType(..), Visibility(..) )

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Ops as Ops
```

Adjust references:
- Replace all `eco*` helpers with `Ops.eco*`.
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `getOrCreateTypeIdForMonoType` with `Ctx.getOrCreateTypeIdForMonoType`.
- Replace `freshVar` with `Ctx.freshVar`.
- Replace `initContext`, etc., with `Ctx.*` where appropriate.

When you call expression lowering, use `Expr.generateExpr` and `Expr.ExprResult`.

For example, in `generateLambdaFunc`:

- `exprResult : Expr.ExprResult`
- `exprResult = Expr.generateExpr ctxWithArgs lambda.body`
- Replace all `eco*` helpers with `Ops.eco*`.
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `getOrCreateTypeIdForMonoType` with `Ctx.getOrCreateTypeIdForMonoType`.
- Replace `freshVar` with `Ctx.freshVar`.
- Replace `initContext`, etc., with `Ctx.*` where appropriate.

When you call expression lowering, use `Expr.generateExpr` and `Expr.ExprResult`.

For example, in `generateLambdaFunc`:

- `exprResult : Expr.ExprResult`
- `exprResult = Expr.generateExpr ctxWithArgs lambda.body`
- Replace all `eco*` helpers with `Ops.eco*`.
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `getOrCreateTypeIdForMonoType` with `Ctx.getOrCreateTypeIdForMonoType`.
- Replace `freshVar` with `Ctx.freshVar`.
- Replace `initContext`, etc., with `Ctx.*` where appropriate.

When you call expression lowering, use `Expr.generateExpr` and `Expr.ExprResult`.

For example, in `generateLambdaFunc`:

- `exprResult : Expr.ExprResult`
- `exprResult = Expr.generateExpr ctxWithArgs lambda.body`
- Replace all `eco*` helpers with `Ops.eco*`.
- Replace `monoTypeToMlir` with `Types.monoTypeToMlir`.
- Replace `getOrCreateTypeIdForMonoType` with `Ctx.getOrCreateTypeIdForMonoType`.
- Replace `freshVar` with `Ctx.freshVar`.
- Replace `initContext`, etc., with `Ctx.*` where appropriate.

When you call expression lowering, use `Expr.generateExpr` and `Expr.ExprResult`.

For example, in `generateLambdaFunc`:

- `exprResult : Expr.ExprResult`
- `exprResult = Expr.generateExpr ctxWithArgs lambda.body`
---
## Step 9 – `MLIR.Backend` (program entry, wiring modules together)
### 9.1 New file

Create:
```text
compiler/src/Compiler/Generate/MLIR/Backend.elm
```

with header:
```elm
module Compiler.Generate.MLIR.Backend exposing
    ( backend
    )
```
### 9.2 Move and adapt backend + generateProgram

From the old `CodeGen.MLIR`, move:
- `backend : CodeGen.MonoCodeGen`
- `generateProgram : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> String`

Adapt `generateProgram` to use other modules:
- `backend : CodeGen.MonoCodeGen`
- `generateProgram : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> String`

Adapt `generateProgram` to use other modules:
```elm
import Dict
import Data.Map as EveryDict

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Mlir.Loc as Loc
import Mlir.Mlir exposing ( MlirModule )
import Mlir.Pretty as Pretty

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Functions as Funcs
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.MLIR.Types as Types
```

Then in `generateProgram`:
- Build signatures with `Ctx.buildSignatures`.
- Initialize context with `Ctx.initContext`.
- For each node, call `Funcs.generateNode`.
- `Funcs.processLambdas` and `Funcs.processPendingWrappers`.
- Generate main via `Funcs.generateMainEntry`.
- Generate kernel decls via `Funcs.generateKernelDecl` if you left it in `Functions`; otherwise expose it from there.
- Type table via `TypeTable.generateTypeTable`.

The logic is exactly as before; only module qualifiers change.

`backend` stays the same, but references `generateProgram` from this module.
- Build signatures with `Ctx.buildSignatures`.
- Initialize context with `Ctx.initContext`.
- For each node, call `Funcs.generateNode`.
- `Funcs.processLambdas` and `Funcs.processPendingWrappers`.
- Generate main via `Funcs.generateMainEntry`.
- Generate kernel decls via `Funcs.generateKernelDecl` if you left it in `Functions`; otherwise expose it from there.
- Type table via `TypeTable.generateTypeTable`.

The logic is exactly as before; only module qualifiers change.

`backend` stays the same, but references `generateProgram` from this module.
- Build signatures with `Ctx.buildSignatures`.
- Initialize context with `Ctx.initContext`.
- For each node, call `Funcs.generateNode`.
- `Funcs.processLambdas` and `Funcs.processPendingWrappers`.
- Generate main via `Funcs.generateMainEntry`.
- Generate kernel decls via `Funcs.generateKernelDecl` if you left it in `Functions`; otherwise expose it from there.
- Type table via `TypeTable.generateTypeTable`.

The logic is exactly as before; only module qualifiers change.

`backend` stays the same, but references `generateProgram` from this module.
---
## Step 10 – Shrink `Compiler.Generate.CodeGen.MLIR` into a shim

Now that all functionality lives under `Compiler.Generate.MLIR.*`, turn the original big file into a thin wrapper.
### 10.1 Replace contents

Keep the file:
```text
compiler/src/Compiler/Generate/CodeGen/MLIR.elm
```

but reduce it to:
```elm
module Compiler.Generate.CodeGen.MLIR exposing (backend)

import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MlirBackend

backend : CodeGen.MonoCodeGen
backend =
    MlirBackend.backend
```

Delete everything else from this file (all definitions you have moved).
This keeps the external API (`Compiler.Generate.CodeGen.MLIR.backend`) stable while relocating implementation details.
---
## Step 11 – Build and fix imports incrementally

At this point you have:
- New modules: `MLIR.Types`, `MLIR.Context`, `MLIR.Ops`, `MLIR.TypeTable`, `MLIR.Intrinsics`, `MLIR.Expr`, `MLIR.Patterns`, `MLIR.Functions`, `MLIR.Backend`.
- Existing `CodeGen.MLIR` as a small shim.

To make it practical:

1. **Do it in small PR-sized steps.** For example:

   - PR1: Introduce `Types`, `Context`, `Ops` and update old module to import them but keep everything else in place.
   - PR2: Introduce `TypeTable` and change `generateTypeTable` call.
   - PR3: Introduce `Intrinsics` and change intrinsic references.
   - PR4: Extract `Expr` and `Patterns`.
   - PR5: Extract `Functions` and `Backend`, shrink `CodeGen.MLIR`.

2. **After each step**, run `elm make` (or your build pipeline) and fix:

   - Missing imports (add appropriate `import Compiler.Generate.MLIR.*`).
   - Unqualified names (prefix with `Types.`, `Ctx.`, `Ops.`, `Intrinsics.`, `Expr.`, or `Patterns.`).

3. **Watch for cycles.** With the plan above:

   - `Expr` imports `Patterns`, but `Patterns` does not import `Expr`.
   - `Functions` imports `Expr`, but `Expr` does not import `Functions`.
   - `Ops` only imports `Context` & `Types`.
   - `Context` & `Types` do not import any of the higher-level modules.

   So there should be no module cycles if you keep the boundaries as described.
- New modules: `MLIR.Types`, `MLIR.Context`, `MLIR.Ops`, `MLIR.TypeTable`, `MLIR.Intrinsics`, `MLIR.Expr`, `MLIR.Patterns`, `MLIR.Functions`, `MLIR.Backend`.
- Existing `CodeGen.MLIR` as a small shim.

To make it practical:

1. **Do it in small PR-sized steps.** For example:

   - PR1: Introduce `Types`, `Context`, `Ops` and update old module to import them but keep everything else in place.
   - PR2: Introduce `TypeTable` and change `generateTypeTable` call.
   - PR3: Introduce `Intrinsics` and change intrinsic references.
   - PR4: Extract `Expr` and `Patterns`.
   - PR5: Extract `Functions` and `Backend`, shrink `CodeGen.MLIR`.

2. **After each step**, run `elm make` (or your build pipeline) and fix:

   - Missing imports (add appropriate `import Compiler.Generate.MLIR.*`).
   - Unqualified names (prefix with `Types.`, `Ctx.`, `Ops.`, `Intrinsics.`, `Expr.`, or `Patterns.`).

3. **Watch for cycles.** With the plan above:

   - `Expr` imports `Patterns`, but `Patterns` does not import `Expr`.
   - `Functions` imports `Expr`, but `Expr` does not import `Functions`.
   - `Ops` only imports `Context` & `Types`.
   - `Context` & `Types` do not import any of the higher-level modules.

   So there should be no module cycles if you keep the boundaries as described.
- New modules: `MLIR.Types`, `MLIR.Context`, `MLIR.Ops`, `MLIR.TypeTable`, `MLIR.Intrinsics`, `MLIR.Expr`, `MLIR.Patterns`, `MLIR.Functions`, `MLIR.Backend`.
- Existing `CodeGen.MLIR` as a small shim.

To make it practical:

1. **Do it in small PR-sized steps.** For example:

   - PR1: Introduce `Types`, `Context`, `Ops` and update old module to import them but keep everything else in place.
   - PR2: Introduce `TypeTable` and change `generateTypeTable` call.
   - PR3: Introduce `Intrinsics` and change intrinsic references.
   - PR4: Extract `Expr` and `Patterns`.
   - PR5: Extract `Functions` and `Backend`, shrink `CodeGen.MLIR`.

2. **After each step**, run `elm make` (or your build pipeline) and fix:

   - Missing imports (add appropriate `import Compiler.Generate.MLIR.*`).
   - Unqualified names (prefix with `Types.`, `Ctx.`, `Ops.`, `Intrinsics.`, `Expr.`, or `Patterns.`).

3. **Watch for cycles.** With the plan above:

   - `Expr` imports `Patterns`, but `Patterns` does not import `Expr`.
   - `Functions` imports `Expr`, but `Expr` does not import `Functions`.
   - `Ops` only imports `Context` & `Types`.
   - `Context` & `Types` do not import any of the higher-level modules.

   So there should be no module cycles if you keep the boundaries as described.
---
## Summary of “what goes where”

For quick reference:
- `Compiler.Generate.MLIR.Types`
  - eco.* types, MonoType → MlirType, function arity, boxed/unboxed checks.

- `Compiler.Generate.MLIR.Context`
  - `Context`, `FuncSignature`, `PendingLambda/Wrapper`, `TypeRegistry`.
  - Fresh var/op IDs, varMappings, type ID registry, kernel signature tracking.
  - Signature extraction and kernel ABI helpers.

- `Compiler.Generate.MLIR.Ops`
  - All MLIR/eco/arith/func/scf builder helpers (`eco.*`, `arith.*`, `scf.*`, `func.func`, `eco.case`, `eco.joinpoint`, etc.).

- `Compiler.Generate.MLIR.TypeTable`
  - Everything under “TYPE TABLE GENERATION” plus `generateTypeTable`.

- `Compiler.Generate.MLIR.Intrinsics`
  - `Intrinsic` type, `kernelIntrinsic`, `basicsIntrinsic`, `bitwiseIntrinsic`, intrinsic result/operand type helpers, intrinsic op generation and argument unboxing.

- `Compiler.Generate.MLIR.Expr`
  - `ExprResult`, `generateExpr` and all non‑pattern branches.
  - Call ABI helpers (`boxToEcoValue`, `boxToMatchSignatureTyped`, `unboxToType`, `coerceResultToType`, `generateExprListTyped`, `boxArgsWithMlirTypes`).
  - High-level `generateDestruct` and full case/decision-tree lowering that builds eco.case/scf.if by delegating to `Patterns` for path/test generation.

- `Compiler.Generate.MLIR.Patterns`
  - `generateMonoPath`, `generateDTPath`, `generateTest`, `generateChainCondition`, `testToTagInt`, `caseKindFromTest`, `computeFallbackTag`.

- `Compiler.Generate.MLIR.Functions`
  - `generateNode`, `generateMainEntry`, `generateDefine`, `generateClosureFunc`, `generateTailFunc`.
  - `generateCtor`, `generateEnum`, `generateExtern`, `generateCycle`.
  - `processLambdas`, `generateLambdaFunc`, `processPendingWrappers`, `generatePapWrapper`.
  - `generateStubValue`, `generateKernelDecl`, `generateStubValueFromMlirType`, `lambdaIdToString`, `specIdToFuncName`.

- `Compiler.Generate.MLIR.Backend`
  - `backend` and `generateProgram`, wiring together `Context`, `Functions`, `TypeTable`, `Pretty.ppModule`.

- `Compiler.Generate.CodeGen.MLIR`
  - Thin shim that just re‑exports `Backend.backend`.

Following these steps, an engineer can mechanically move code and update imports, with a clear separation of concerns and minimal coupling between the new modules.
- `Compiler.Generate.MLIR.Types`
  - eco.* types, MonoType → MlirType, function arity, boxed/unboxed checks.

- `Compiler.Generate.MLIR.Context`
  - `Context`, `FuncSignature`, `PendingLambda/Wrapper`, `TypeRegistry`.
  - Fresh var/op IDs, varMappings, type ID registry, kernel signature tracking.
  - Signature extraction and kernel ABI helpers.

- `Compiler.Generate.MLIR.Ops`
  - All MLIR/eco/arith/func/scf builder helpers (`eco.*`, `arith.*`, `scf.*`, `func.func`, `eco.case`, `eco.joinpoint`, etc.).

- `Compiler.Generate.MLIR.TypeTable`
  - Everything under “TYPE TABLE GENERATION” plus `generateTypeTable`.

- `Compiler.Generate.MLIR.Intrinsics`
  - `Intrinsic` type, `kernelIntrinsic`, `basicsIntrinsic`, `bitwiseIntrinsic`, intrinsic result/operand type helpers, intrinsic op generation and argument unboxing.

- `Compiler.Generate.MLIR.Expr`
  - `ExprResult`, `generateExpr` and all non‑pattern branches.
  - Call ABI helpers (`boxToEcoValue`, `boxToMatchSignatureTyped`, `unboxToType`, `coerceResultToType`, `generateExprListTyped`, `boxArgsWithMlirTypes`).
  - High-level `generateDestruct` and full case/decision-tree lowering that builds eco.case/scf.if by delegating to `Patterns` for path/test generation.

- `Compiler.Generate.MLIR.Patterns`
  - `generateMonoPath`, `generateDTPath`, `generateTest`, `generateChainCondition`, `testToTagInt`, `caseKindFromTest`, `computeFallbackTag`.

- `Compiler.Generate.MLIR.Functions`
  - `generateNode`, `generateMainEntry`, `generateDefine`, `generateClosureFunc`, `generateTailFunc`.
  - `generateCtor`, `generateEnum`, `generateExtern`, `generateCycle`.
  - `processLambdas`, `generateLambdaFunc`, `processPendingWrappers`, `generatePapWrapper`.
  - `generateStubValue`, `generateKernelDecl`, `generateStubValueFromMlirType`, `lambdaIdToString`, `specIdToFuncName`.

- `Compiler.Generate.MLIR.Backend`
  - `backend` and `generateProgram`, wiring together `Context`, `Functions`, `TypeTable`, `Pretty.ppModule`.

- `Compiler.Generate.CodeGen.MLIR`
  - Thin shim that just re‑exports `Backend.backend`.

Following these steps, an engineer can mechanically move code and update imports, with a clear separation of concerns and minimal coupling between the new modules.
