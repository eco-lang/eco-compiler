# Kernel Intrinsics for MLIR Code Generation

## Overview

This plan describes how to modify `Compiler.Generate.CodeGen.MLIR` to recognize arithmetic kernel functions as **intrinsics** and emit the already-defined `eco.int.*` / `eco.float.*` operations instead of runtime calls.

### Current Behavior

Currently, all kernel calls are treated as runtime function calls:

1. A kernel value reference (`MonoVarKernel`) compiles to a 0-arg call to `Elm_Kernel_<home>_<name>`
2. A kernel application (`MonoCall` where func is `MonoVarKernel`) generates:
   - Arguments
   - Boxes arguments at kernel boundary
   - Emits `eco.call` to `Elm_Kernel_<home>_<name>`

### Target Behavior

Recognize arithmetic/bitwise/comparison/trig kernel functions and emit native eco dialect operations:
- `eco.int.add`, `eco.int.sub`, `eco.int.mul`, etc.
- `eco.float.add`, `eco.float.div`, `eco.float.sqrt`, etc.
- `eco.int.lt`, `eco.int.eq`, `eco.float.lt`, etc. for comparisons
- `eco.float.sin`, `eco.float.cos`, etc. for trigonometry
- `eco.float.isNaN`, `eco.float.isInfinite` for float classification
- No boxing needed since eco ops work on unboxed primitives

---

## Decisions Made

| Question | Decision |
|----------|----------|
| **Bitwise width** | Use 64-bit (`eco.int.*`) - Ints are 64-bit in Eco |
| **Comparisons** | Generated as eco comparison ops (`eco.int.lt`, etc.), not kernel calls |
| **Trig functions** | Add new eco ops (`eco.float.sin`, `eco.float.cos`, etc.) |
| **isNaN/isInfinite** | Add new eco ops (`eco.float.isNaN`, `eco.float.isInfinite`) |
| **Kernels as values** | Generate wrapper function using intrinsic, mark for inlining |
| **Wrapper naming** | `__eco_intrinsic_<op>_<types>` (e.g., `__eco_intrinsic_add_i64_i64`) |
| **logBase** | Expand inline to `eco.float.div (eco.float.log x) (eco.float.log base)` |
| **Constants (pi, e)** | Emit as `arith.constant` with actual values |

---

## Phase 0: Add Missing Eco Dialect Ops

Before implementing intrinsics in the Elm compiler, we need to add the missing ops to the eco dialect.

### 0.1 New Ops to Add to `Ops.td`

**Trigonometric functions:**
```tablegen
def Eco_FloatSinOp : Eco_Op<"float.sin", [Pure]> { ... }    // sin(x)
def Eco_FloatCosOp : Eco_Op<"float.cos", [Pure]> { ... }    // cos(x)
def Eco_FloatTanOp : Eco_Op<"float.tan", [Pure]> { ... }    // tan(x)
def Eco_FloatAsinOp : Eco_Op<"float.asin", [Pure]> { ... }  // asin(x)
def Eco_FloatAcosOp : Eco_Op<"float.acos", [Pure]> { ... }  // acos(x)
def Eco_FloatAtanOp : Eco_Op<"float.atan", [Pure]> { ... }  // atan(x)
def Eco_FloatAtan2Op : Eco_Op<"float.atan2", [Pure]> { ... } // atan2(y, x)
def Eco_FloatLogOp : Eco_Op<"float.log", [Pure]> { ... }    // natural log
```

**Float classification:**
```tablegen
def Eco_FloatIsNaNOp : Eco_Op<"float.isNaN", [Pure]> { ... }
def Eco_FloatIsInfiniteOp : Eco_Op<"float.isInfinite", [Pure]> { ... }
```

### 0.2 Add Lowerings to `EcoToLLVM.cpp`

Lower trig ops to LLVM math intrinsics:
- `eco.float.sin` → `llvm.sin`
- `eco.float.cos` → `llvm.cos`
- etc.

Lower float classification:
- `eco.float.isNaN` → `llvm.fcmp uno %x, %x` (unordered compare with self)
- `eco.float.isInfinite` → compare absolute value with infinity

---

## Phase 1: Define Intrinsic Types and Table

### 1.1 Add Intrinsic Type Definition

```elm
{-| Types of intrinsic operations -}
type Intrinsic
    = UnaryInt { op : String }           -- eco.int.* with one i64 operand, returns i64
    | BinaryInt { op : String }          -- eco.int.* with two i64 operands, returns i64
    | UnaryFloat { op : String }         -- eco.float.* with one f64 operand, returns f64
    | BinaryFloat { op : String }        -- eco.float.* with two f64 operands, returns f64
    | IntToFloat                         -- eco.int.toFloat: i64 -> f64
    | FloatToInt { op : String }         -- eco.float.round/floor/ceiling/truncate: f64 -> i64
    | IntComparison { op : String }      -- eco.int.lt/le/gt/ge/eq/ne: (i64, i64) -> i1
    | FloatComparison { op : String }    -- eco.float.lt/le/gt/ge/eq/ne: (f64, f64) -> i1
    | FloatClassify { op : String }      -- eco.float.isNaN/isInfinite: f64 -> i1
```

### 1.2 Create the Intrinsic Lookup Function

```elm
kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case ( home, name, argTypes, resultType ) of
        -- ===== Integer Arithmetic =====
        ( "Basics", "add", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.add" })

        ( "Basics", "sub", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.sub" })

        ( "Basics", "mul", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.mul" })

        ( "Basics", "idiv", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.div" })

        ( "Basics", "modBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.modby" })

        ( "Basics", "remainderBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.remainderby" })

        ( "Basics", "negate", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.negate" })

        ( "Basics", "abs", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.abs" })

        ( "Basics", "pow", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.pow" })

        -- ===== Float Arithmetic =====
        ( "Basics", "add", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.add" })

        ( "Basics", "sub", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.sub" })

        ( "Basics", "mul", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.mul" })

        ( "Basics", "fdiv", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.div" })

        ( "Basics", "negate", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.negate" })

        ( "Basics", "abs", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.abs" })

        ( "Basics", "pow", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.pow" })

        ( "Basics", "sqrt", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" })

        -- ===== Trigonometric Functions =====
        ( "Basics", "sin", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.sin" })

        ( "Basics", "cos", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.cos" })

        ( "Basics", "tan", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.tan" })

        ( "Basics", "asin", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.asin" })

        ( "Basics", "acos", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.acos" })

        ( "Basics", "atan", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.atan" })

        ( "Basics", "atan2", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.atan2" })

        -- ===== Logarithm =====
        -- Natural log
        ( "Basics", "log", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        -- logBase is handled specially - expanded inline (see generateLogBase)

        -- ===== Float Classification =====
        ( "Basics", "isNaN", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "Basics", "isInfinite", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        -- ===== Type Conversions =====
        ( "Basics", "toFloat", [ Mono.MInt ], Mono.MFloat ) ->
            Just IntToFloat

        ( "Basics", "round", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.round" })

        ( "Basics", "floor", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.floor" })

        ( "Basics", "ceiling", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.ceiling" })

        ( "Basics", "truncate", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.truncate" })

        -- ===== Integer Min/Max =====
        ( "Basics", "min", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "Basics", "max", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.max" })

        -- ===== Float Min/Max =====
        ( "Basics", "min", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "Basics", "max", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        -- ===== Bitwise Operations (64-bit) =====
        ( "Bitwise", "and", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.and" })

        ( "Bitwise", "or", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.or" })

        ( "Bitwise", "xor", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.xor" })

        ( "Bitwise", "complement", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.complement" })

        ( "Bitwise", "shiftLeftBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shl" })

        ( "Bitwise", "shiftRightBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shr" })

        ( "Bitwise", "shiftRightZfBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shru" })

        -- ===== Integer Comparisons =====
        ( "Basics", "lt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "Basics", "le", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "Basics", "gt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "Basics", "ge", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "Basics", "eq", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "Basics", "neq", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.ne" })

        -- ===== Float Comparisons =====
        ( "Basics", "lt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "Basics", "le", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "Basics", "gt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "Basics", "ge", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "Basics", "eq", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "Basics", "neq", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        -- Fallback: not an intrinsic
        _ ->
            Nothing
```

---

## Phase 2: Add Op Builder Helpers

### 2.1 Unary and Binary Intrinsic Builders

```elm
{-| Build a unary eco op (e.g., eco.int.negate, eco.float.sqrt) -}
ecoUnaryOp : Context -> String -> String -> ( String, MlirType ) -> MlirType -> MlirOp
ecoUnaryOp ctx opName resultVar ( operand, operandTy ) resultTy =
    mlirOp opName ctx
        |> withOperands [ ( operand, operandTy ) ]
        |> withResult resultVar resultTy
        |> build


{-| Build a binary eco op (e.g., eco.int.add, eco.float.mul) -}
ecoBinaryOp : Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirType -> MlirOp
ecoBinaryOp ctx opName resultVar ( lhs, lhsTy ) ( rhs, rhsTy ) resultTy =
    mlirOp opName ctx
        |> withOperands [ ( lhs, lhsTy ), ( rhs, rhsTy ) ]
        |> withResult resultVar resultTy
        |> build
```

---

## Phase 3: Modify generateCall for Kernel Intrinsics

### 3.1 Update the MonoVarKernel Branch

In `generateCall`, the `Mono.MonoVarKernel` branch currently boxes all arguments and emits `eco.call`. We modify it to:

1. Check if `kernelIntrinsic home name argTypes resultType` returns `Just intrinsic`
2. If yes: emit the eco op directly using **unboxed** argument types
3. If no: fall back to the existing behavior (box + eco.call)

```elm
Mono.MonoVarKernel _ home name _ ->
    let
        -- Generate arguments (same as before)
        ( argsOps, argVars, ctx1 ) =
            generateExprList ctx args

        -- Get argument types for intrinsic lookup
        argTypes : List Mono.MonoType
        argTypes =
            List.map Mono.typeOf args

        ( resultVar, ctx2 ) =
            freshVar ctx1
    in
    case kernelIntrinsic home name argTypes resultType of
        Just intrinsic ->
            -- Emit intrinsic op with UNBOXED types (no boxing!)
            let
                intrinsicOp : MlirOp
                intrinsicOp =
                    generateIntrinsicOp ctx2 intrinsic resultVar argVars args
            in
            { ops = argsOps ++ [ intrinsicOp ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        Nothing ->
            -- Fall back to kernel call (existing behavior)
            let
                argsWithTypes : List ( String, Mono.MonoType )
                argsWithTypes =
                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                ( boxOps, boxedVars, ctx2b ) =
                    boxArgsIfNeeded ctx2 argsWithTypes

                argVarPairs : List ( String, MlirType )
                argVarPairs =
                    List.map (\v -> ( v, ecoValue )) boxedVars

                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name
            in
            { ops = argsOps ++ boxOps ++ [ ecoCallNamed ctx2 resultVar kernelName argVarPairs (monoTypeToMlir resultType) ]
            , resultVar = resultVar
            , ctx = ctx2b
            }
```

### 3.2 Helper to Generate Intrinsic Ops

```elm
generateIntrinsicOp : Context -> Intrinsic -> String -> List String -> List Mono.MonoExpr -> MlirOp
generateIntrinsicOp ctx intrinsic resultVar argVars args =
    case intrinsic of
        UnaryInt { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, I64 ) I64

        BinaryInt { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I64
                _ ->
                    ecoUnaryOp ctx op resultVar ( "%error", I64 ) I64

        UnaryFloat { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) F64

        BinaryFloat { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) F64
                _ ->
                    ecoUnaryOp ctx op resultVar ( "%error", F64 ) F64

        IntToFloat ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx "eco.int.toFloat" resultVar ( operand, I64 ) F64

        FloatToInt { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) I64

        IntComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I1
                _ ->
                    ecoBinaryOp ctx op resultVar ( "%error", I64 ) ( "%error", I64 ) I1

        FloatComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) I1
                _ ->
                    ecoBinaryOp ctx op resultVar ( "%error", F64 ) ( "%error", F64 ) I1

        FloatClassify { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) I1
```

---

## Phase 4: Handle generateVarKernel (Function as Value)

When a kernel function is used as a **value** (not called directly), `generateVarKernel` is invoked. For intrinsic-eligible kernels, we generate a **wrapper function** that uses the intrinsic, then create a PAP to that wrapper.

### 4.1 Strategy

1. Check if the kernel is intrinsic-eligible
2. If yes: generate a wrapper function (marked for inlining) that calls the intrinsic
3. Create a PAP pointing to the wrapper
4. If no: fall back to existing behavior (PAP to kernel function)

### 4.2 Implementation

```elm
generateVarKernel : Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        ( var, ctx1 ) =
            freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
    in
    case monoType of
        Mono.MFunction argTypes returnType ->
            -- Function-typed kernel: check if intrinsic
            case kernelIntrinsic home name argTypes returnType of
                Just intrinsic ->
                    -- Generate wrapper function using intrinsic
                    let
                        wrapperName : String
                        wrapperName =
                            "__eco_intrinsic_" ++ name ++ "_" ++ typeSignature argTypes

                        arity : Int
                        arity =
                            List.length argTypes

                        -- Register wrapper function to be emitted later
                        ctx2 =
                            registerIntrinsicWrapper ctx1 wrapperName intrinsic argTypes returnType

                        papOp : MlirOp
                        papOp =
                            mlirOp "eco.papCreate" ctx2
                                |> withResult var ecoValue
                                |> withAttr "function" (SymbolRefAttr wrapperName)
                                |> withAttr "arity" (IntAttr arity)
                                |> withAttr "num_captured" (IntAttr 0)
                                |> withAttr "alwaysinline" (BoolAttr True)  -- Mark for inlining
                                |> build
                    in
                    { ops = [ papOp ]
                    , resultVar = var
                    , ctx = ctx2
                    }

                Nothing ->
                    -- Not an intrinsic: create PAP to kernel function
                    let
                        arity : Int
                        arity =
                            countTotalArity monoType

                        papOp : MlirOp
                        papOp =
                            mlirOp "eco.papCreate" ctx1
                                |> withResult var ecoValue
                                |> withAttr "function" (SymbolRefAttr kernelName)
                                |> withAttr "arity" (IntAttr arity)
                                |> withAttr "num_captured" (IntAttr 0)
                                |> build
                    in
                    { ops = [ papOp ]
                    , resultVar = var
                    , ctx = ctx1
                    }

        _ ->
            -- Non-function (e.g., constant like `pi` or `e`)
            { ops = [ ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType) ]
            , resultVar = var
            , ctx = ctx1
            }
```

### 4.3 Wrapper Function Generation

The wrapper function is emitted at module level:

```elm
generateIntrinsicWrapper : String -> Intrinsic -> List Mono.MonoType -> Mono.MonoType -> MlirFunc
generateIntrinsicWrapper name intrinsic argTypes returnType =
    -- Generate a function like:
    -- func.func @__eco_intrinsic_add_i64_i64(%arg0: i64, %arg1: i64) -> i64 attributes {alwaysinline} {
    --     %0 = eco.int.add %arg0, %arg1 : i64
    --     return %0 : i64
    -- }
    ...

typeSignature : List Mono.MonoType -> String
typeSignature types =
    types
        |> List.map monoTypeToShortName
        |> String.join "_"

monoTypeToShortName : Mono.MonoType -> String
monoTypeToShortName ty =
    case ty of
        Mono.MInt -> "i64"
        Mono.MFloat -> "f64"
        Mono.MBool -> "i1"
        _ -> "val"
```

### 4.4 Special Cases

#### logBase Expansion

`logBase` is expanded inline rather than using the intrinsic table:

```elm
-- In generateCall, check for logBase specially:
( "Basics", "logBase", [ base, x ] ) ->
    -- logBase base x = log(x) / log(base)
    let
        ( logX, ctx1 ) = freshVar ctx
        ( logBase, ctx2 ) = freshVar ctx1
        ( result, ctx3 ) = freshVar ctx2
    in
    { ops =
        [ ecoUnaryOp ctx "eco.float.log" logX ( xVar, F64 ) F64
        , ecoUnaryOp ctx "eco.float.log" logBase ( baseVar, F64 ) F64
        , ecoBinaryOp ctx "eco.float.div" result ( logX, F64 ) ( logBase, F64 ) F64
        ]
    , resultVar = result
    , ctx = ctx3
    }
```

#### Constants (pi, e)

`pi` and `e` are emitted as `arith.constant` operations:

```elm
-- In generateVarKernel, check for constants:
( "Basics", "pi", Mono.MFloat ) ->
    let
        ( var, ctx1 ) = freshVar ctx
        piOp = mlirOp "arith.constant" ctx1
            |> withResult var F64
            |> withAttr "value" (FloatAttr 3.141592653589793)
            |> build
    in
    { ops = [ piOp ], resultVar = var, ctx = ctx1 }

( "Basics", "e", Mono.MFloat ) ->
    let
        ( var, ctx1 ) = freshVar ctx
        eOp = mlirOp "arith.constant" ctx1
            |> withResult var F64
            |> withAttr "value" (FloatAttr 2.718281828459045)
            |> build
    in
    { ops = [ eOp ], resultVar = var, ctx = ctx1 }
```

---

## Phase 5: Testing

### Unit Tests
- Verify `kernelIntrinsic` returns correct intrinsic for each case
- Verify fallback to `Nothing` for non-intrinsic kernels

### Integration Tests
- Compile simple arithmetic expressions, verify output contains `eco.int.add` etc.
- Compile comparison expressions, verify output contains `eco.int.lt` etc.
- Compile trig expressions, verify output contains `eco.float.sin` etc.
- Verify no `Elm_Kernel_Basics_add` calls for intrinsified operations
- Test kernels as values: `List.map (+) [1,2,3]` should generate wrapper

### Golden Tests
```elm
-- Should emit eco.int.add
add a b = a + b

-- Should emit eco.float.div
divide a b = a / b

-- Should emit eco.int.lt
lessThan a b = a < b

-- Should emit eco.float.sin
sine x = sin x

-- Should emit eco.float.isNaN
checkNaN x = isNaN x

-- Kernel as value: should generate wrapper with eco.int.add
addFunc = (+)
```

---

## Implementation Order

1. **Phase 0**: Add missing eco dialect ops (trig, isNaN, isInfinite) + lowerings
2. **Phase 1**: Add `Intrinsic` type and `kernelIntrinsic` lookup table
3. **Phase 2**: Add `ecoUnaryOp`, `ecoBinaryOp` builders
4. **Phase 3**: Modify `generateCall` to use intrinsics
5. **Phase 4**: Update `generateVarKernel` to generate wrapper functions
6. **Phase 5**: Testing

