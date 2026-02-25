# MLIR Generation Pass

## Overview

The MLIR Generation pass converts the Monomorphized IR into MLIR (Multi-Level Intermediate Representation), specifically using the ECO dialect. This is the entry point into the LLVM compilation pipeline, producing operations that will be progressively lowered through ECO dialect transformations to LLVM IR.

**Phase**: Code Generation (Stage 1)

**Pipeline Position**: After Monomorphization, before ECO dialect lowering passes

## Purpose

MLIR provides a modular infrastructure for compiler construction with:

1. **Type safety**: Strong typing at the IR level
2. **Dialect extensibility**: Custom operations via ECO dialect
3. **Progressive lowering**: Staged conversion to LLVM
4. **Optimization framework**: MLIR's pass infrastructure

## ECO Dialect Operations

The ECO dialect defines operations for Elm runtime semantics:

### Data Construction

| Operation | Purpose |
|-----------|---------|
| `eco.constant` | Embedded constants (Unit, True, False, Nil) |
| `eco.string_literal` | String constants |
| `eco.box` | Box primitive to heap object |
| `eco.unbox` | Unbox heap object to primitive |
| `eco.construct.list` | Construct cons cell |
| `eco.construct.tuple2` | Construct 2-tuple |
| `eco.construct.tuple3` | Construct 3-tuple |
| `eco.construct.record` | Construct record |
| `eco.construct.custom` | Construct custom type |

### Data Access

| Operation | Purpose |
|-----------|---------|
| `eco.project.list_head` | Get list head |
| `eco.project.list_tail` | Get list tail |
| `eco.project.tuple2` | Project tuple field |
| `eco.project.record` | Project record field |
| `eco.project.custom` | Project custom type field |
| `eco.get_tag` | Get constructor tag |

### Arithmetic

| Operation | Purpose |
|-----------|---------|
| `eco.int.*` | Integer operations (add, sub, mul, div, etc.) |
| `eco.float.*` | Float operations |
| `eco.bool.*` | Boolean operations |
| `eco.char_to_int` | Character to code point |
| `eco.char_from_int` | Code point to character |
| `eco.int_to_float` | Integer to float conversion |

### Control Flow

| Operation | Purpose |
|-----------|---------|
| `eco.call` | Function call (direct or indirect) |
| `eco.case` | Multi-way branch on tag |
| `eco.joinpoint` | Local join point definition |
| `eco.jump` | Jump to join point |
| `eco.return` | Return from function |

### Closures

| Operation | Purpose |
|-----------|---------|
| `eco.papCreate` | Create partial application |
| `eco.papExtend` | Extend partial application |

### Utilities

| Operation | Purpose |
|-----------|---------|
| `eco.global` | Declare global variable |
| `eco.load_global` | Load global |
| `eco.store_global` | Store global |
| `eco.safepoint` | GC safepoint |
| `eco.dbg` | Debug print |
| `eco.crash` | Runtime error |
| `eco.expect` | Assertion |
| `eco.type_table` | Type metadata for debug printing |

## Type Mapping

MonoTypes map to MLIR types:

| MonoType | MLIR Type | Description |
|----------|-----------|-------------|
| MInt | `i64` | 64-bit signed integer |
| MFloat | `f64` | 64-bit float |
| MBool | `i1` | Boolean |
| MChar | `i32` | Unicode code point |
| MString | `!eco.value` | Heap string |
| MUnit | `!eco.value` | Unit constant |
| MList _ | `!eco.value` | Heap list |
| MTuple _ | `!eco.value` | Heap tuple |
| MRecord _ | `!eco.value` | Heap record |
| MCustom _ _ _ | `!eco.value` | Heap custom type |
| MFunction _ _ | `!eco.value` | Closure |
| MVar _ CEcoValue | `!eco.value` | Boxed polymorphic |
| MVar _ CNumber | varies | Int or Float |

## Code Generation Process

### Entry Point

```elm
generateModule :
    Mode.Mode
    -> TypeEnv.GlobalTypeEnv
    -> Mono.MonoGraph
    -> String  -- MLIR text output
```

### Processing Order

1. Build function signatures for all specializations
2. Initialize Context with TypeRegistry (seeded with `MonoGraph.ctorLayouts`)
3. Generate nodes for each specialization
4. Process pending lambdas (closures)
5. Generate main entry point
6. Generate kernel function declarations
7. Generate type table (uses pre-computed `ctorLayouts` from monomorphization)
8. Emit MLIR module

Note: Constructor layouts are computed during monomorphization and stored in `MonoGraph.ctorLayouts`. MLIR codegen only consumes this pre-computed map and does not re-derive layouts from `GlobalTypeEnv`.

### Context Structure

```elm
type alias Context =
    { nextVar : Int                -- SSA variable counter
    , nextOpId : Int               -- Operation ID counter
    , mode : Mode.Mode             -- Debug/Release mode
    , registry : SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , pendingWrappers : List PendingWrapper  -- Boxed wrappers for PAP targets
    , signatures : Dict Int FuncSignature
    , varMappings : Dict String (String, MlirType)
    , kernelDecls : Dict String (List MlirType, MlirType)
    , typeRegistry : TypeRegistry  -- Seeded with ctorLayouts from MonoGraph
    }
```

## Node Generation

### MonoDefine

Top-level definitions become `func.func` operations:

```
FUNCTION generateDefine(specId, expr, ctx):
    sig = signatures[specId]
    funcName = specIdToName(specId)

    -- Generate function body
    (bodyOps, resultVar, ctx') = generateExpr(expr, ctx)

    RETURN func.func @{funcName}({params}) -> {returnType} {
        bodyOps
        eco.return {resultVar}
    }
```

### MonoTailFunc

Tail-recursive functions generate with loop structure:

```
FUNCTION generateTailFunc(specId, args, body, ctx):
    -- Entry block initializes args
    -- Loop block has arg block parameters
    -- Tail calls become jumps with new arg values
```

### MonoCtor

Constructors generate allocation + field stores:

```
FUNCTION generateCtor(specId, tag, layout, ctx):
    -- eco.allocate_ctor for the tag and size
    -- eco.store_field for each field
```

## Expression Generation

### Literals

```
MInt n    -> arith.constant n : i64
MFloat f  -> arith.constant f : f64
MBool b   -> arith.constant b : i1
MChar c   -> arith.constant c : i32
MString s -> eco.string_literal s
MUnit     -> eco.constant Unit
```

### Variables

```
MonoVarLocal name type ->
    IF name IN varMappings:
        RETURN varMappings[name]
    ELSE:
        -- Must be function parameter
        RETURN lookupParam(name)

MonoVarGlobal specId type ->
    -- Reference to another specialization
    -- May generate a closure if partially applied
```

### Function Calls

```
MonoCall func args resultType ->
    CASE func OF
        MonoVarGlobal specId _ (direct call):
            -- eco.call @specName(args)

        MonoVarKernel home name _ (kernel call):
            -- eco.call @kernel_name(args)
            -- Track kernel declaration

        _ (indirect call through closure):
            -- eco.papExtend or saturated call
```

### Let Expressions

```
MonoLet name boundExpr body ->
    (boundOps, boundVar, ctx') = generateExpr(boundExpr, ctx)
    ctx'' = ctx' with varMappings[name] = boundVar
    (bodyOps, resultVar, ctx''') = generateExpr(body, ctx'')
    RETURN (boundOps ++ bodyOps, resultVar, ctx''')
```

#### SSA Renaming for Recursive Let Definitions (Feb 2026)

When a let-bound definition is recursive (self-referential) and inlined, the generated MLIR may contain duplicate SSA variable names from repeated expansions. The codegen handles this with SSA value renaming utilities in `Expr.elm`:

```elm
renameSsaVarInOps : String -> String -> List MlirOp -> List MlirOp
renameSsaVarInRegion : String -> String -> MlirRegion -> MlirRegion
renameSsaVarInBlock : String -> String -> MlirBlock -> MlirBlock
renameSsaVarInSingleOp : String -> String -> MlirOp -> MlirOp
```

These functions perform substitution of one SSA variable name for another throughout a list of operations, recursing into regions and blocks. This ensures that after inlining a recursive definition, all SSA references within the inlined copy are unique and properly scoped.

### Case Expressions

```
MonoCase scrutinee branches default ->
    (scrutOps, scrutVar, ctx') = generateExpr(scrutinee, ctx)

    -- eco.case with alternatives for each tag
    caseOp = eco.case scrutVar [tags] {
        tag0 -> { branchOps0; eco.return result0 }
        tag1 -> { branchOps1; eco.return result1 }
        ...
    }
```

### Lambdas

Lambdas are hoisted to top-level functions:

```
MonoFunction params captures body ->
    lambdaName = generateLambdaName()
    addPendingLambda(lambdaName, params, captures, body)

    -- Generate closure creation
    eco.papCreate @lambdaName, arity, [capturedValues]
```

### Data Construction

```
MonoList elems elemType ->
    -- Fold from Nil, cons'ing each element
    result = eco.constant Nil
    FOR elem IN reverse(elems):
        (elemOps, elemVar) = generateExpr(elem)
        result = eco.construct.list elemVar result

MonoTuple2 a b ->
    eco.construct.tuple2 aVar bVar unboxedBitmap

MonoRecord fields ->
    eco.construct.record [fieldVars] fieldCount unboxedBitmap

MonoCustom tag fields ->
    eco.construct.custom tag size [fieldVars] unboxedBitmap
```

### Data Projection

```
MonoProjectList head/tail list ->
    eco.project.list_head/tail listVar

MonoProjectTuple idx tuple ->
    eco.project.tuple2/tuple3 tupleVar idx

MonoProjectRecord fieldName record ->
    eco.project.record recordVar fieldIndex

MonoProjectCustom idx custom ->
    eco.project.custom customVar idx
```

## Unboxed Value Optimization

Primitives in containers can be stored unboxed:

```
FUNCTION computeUnboxedBitmap(fields):
    bitmap = 0
    FOR (i, field) IN enumerate(fields):
        IF isUnboxed(field.type):  -- MInt, MFloat
            bitmap |= (1 << i)
    RETURN bitmap
```

The bitmap is stored in the object header and used by GC/projection.

## Function Signatures

Signatures track function types for type checking:

```elm
type alias FuncSignature =
    { params : List (Name, MlirType)
    , returnType : MlirType
    }

buildSignatures : Dict SpecId MonoNode -> Dict Int FuncSignature
```

## Kernel Function Handling

Kernel functions are declared but not defined:

```
FUNCTION generateKernelDecl(name, (argTypes, returnType), ctx):
    RETURN func.func @{name}({argTypes}) -> {returnType}
           attributes { sym_visibility = "private" }
```

They're linked at LLVM level to C++ runtime implementations.

## Main Entry Point

The main function is special-cased:

```
FUNCTION generateMainEntry(ctx, mainInfo):
    CASE mainInfo OF
        Static:
            -- Just call the main specialization
            func.func @main() {
                eco.call @mainSpec()
            }

        Dynamic msgType decoder:
            -- Initialize runtime, register ports, etc.
```

## Implementation Details

### Module Structure

The MLIR codegen is organized into 11 modules under `compiler/src/Compiler/Generate/MLIR/`:

| Module | Purpose | Size |
|--------|---------|------|
| `Backend.elm` | Program entry point, module wiring | 4KB |
| `Context.elm` | Context, signatures, type registry | 15KB |
| `Types.elm` | Eco types, MonoType→MlirType conversion | 5KB |
| `Ops.elm` | MLIR op builders (eco.*, arith.*, scf.*, func.*) | 25KB |
| `Names.elm` | Symbol naming helpers | 1KB |
| `TypeTable.elm` | eco.type_table generation | 16KB |
| `Intrinsics.elm` | Basics/Bitwise/JsArray kernel intrinsics | 16KB |
| `Patterns.elm` | Decision tree path navigation, test generation | 29KB |
| `Expr.elm` | Expression lowering, call ABI | 97KB |
| `Lambdas.elm` | Lambda/closure processing, PAP wrappers | 10KB |
| `Functions.elm` | Node generation (define, ctor, extern, cycle) | 22KB |

### Key Functions

| Module | Function | Purpose |
|--------|----------|---------|
| `Backend` | `generateModule` | Main entry point |
| `Functions` | `generateNode` | Generate a specialization |
| `Expr` | `generateExpr` | Generate an expression |
| `Expr` | `generateCall` | Generate function call |
| `Expr` | `generateFanOut*` | Generate case expressions |
| `Lambdas` | `processLambdas` | Hoist pending lambdas |
| `Types` | `monoTypeToMlir` | Convert MonoType to MLIR type |
| `TypeTable` | `generateTypeTable` | Build type metadata |
| `Patterns` | `generateDTPath` | Navigate decision tree paths |
| `Patterns` | `caseKindFromTest` | Determine case operation kind |

### MLIR Text Emission

Operations are serialized to MLIR text format:

```elm
type alias MlirOp =
    { name : String
    , id : String  -- Result SSA variable
    , operands : List String
    , results : List MlirType
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    }
```

## Pre-conditions

1. MonoGraph is complete with all specializations
2. All types are monomorphized (no remaining type variables except constrained)
3. Constructor layouts are computed
4. Specialization registry maps SpecIds to SpecKeys

## Post-conditions

1. Valid MLIR module in ECO dialect
2. All specializations have corresponding func.func
3. All lambdas are hoisted to top-level
4. Type table includes all used types
5. Kernel declarations for all external calls

## Example

Elm code:
```elm
double : Int -> Int
double x = x + x
```

Generated MLIR:
```mlir
module {
    eco.type_table types = [...] ...

    func.func @"Main.double<Int>"(%x: i64) -> i64 {
        %0 = eco.int.add %x, %x : i64
        eco.return %0 : i64
    }
}
```

## Relationship to Other Passes

- **Requires**: Monomorphization (MonoGraph)
- **Enables**: ECO dialect lowering passes (Stage 2)
- **Key Input**: MonoGraph with specializations
- **Key Output**: MLIR module in ECO dialect
