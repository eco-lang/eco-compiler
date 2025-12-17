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

Recognize arithmetic/bitwise/comparison kernel functions and emit the native eco dialect operations:
- `eco.int.add`, `eco.int.sub`, `eco.int.mul`, etc.
- `eco.float.add`, `eco.float.div`, `eco.float.sqrt`, etc.
- `eco.int.cmp`, `eco.float.cmp` for comparisons
- No boxing needed since eco ops work on unboxed primitives

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
    | IntToFloat { op : String }         -- eco.int.toFloat: i64 -> f64
    | FloatToInt { op : String }         -- eco.float.round/floor/ceiling/truncate: f64 -> i64
    | IntCmp { predicate : String }      -- eco.int.cmp with predicate
    | FloatCmp { predicate : String }    -- eco.float.cmp with predicate
```

### 1.2 Create the Intrinsic Lookup Function

The function `kernelIntrinsic` maps `(home, name, argTypes, resultType)` to an intrinsic:

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

        -- ===== Type Conversions =====
        ( "Basics", "toFloat", [ Mono.MInt ], Mono.MFloat ) ->
            Just (IntToFloat { op = "eco.int.toFloat" })

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

        -- ===== Bitwise Operations =====
        -- Note: Elm Bitwise module uses 32-bit integers, but eco.int.* uses 64-bit
        -- We still emit eco.int.* ops (64-bit) since MonoType is MInt (64-bit)
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

        -- ===== Comparisons (via Utils kernel) =====
        -- Note: Elm comparisons go through Utils kernel, not Basics
        ( "Utils", "lt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntCmp { predicate = "lt" })

        ( "Utils", "le", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntCmp { predicate = "le" })

        ( "Utils", "gt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntCmp { predicate = "gt" })

        ( "Utils", "ge", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntCmp { predicate = "ge" })

        ( "Utils", "lt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatCmp { predicate = "lt" })

        ( "Utils", "le", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatCmp { predicate = "le" })

        ( "Utils", "gt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatCmp { predicate = "gt" })

        ( "Utils", "ge", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatCmp { predicate = "ge" })

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

### 2.2 Comparison Op Builder (Special Case)

The `eco.int.cmp` and `eco.float.cmp` operations use a predicate attribute that appears **before** the operands in the assembly format:

```mlir
%lt = eco.int.cmp lt %a, %b : i64
```

This requires special handling in the pretty printer. Two options:

**Option A: Store predicate as a regular attribute**

```elm
{-| Build a comparison op with predicate -}
ecoCmpOp : Context -> String -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirOp
ecoCmpOp ctx opName predicate resultVar ( lhs, lhsTy ) ( rhs, rhsTy ) =
    mlirOp opName ctx
        |> withOperands [ ( lhs, lhsTy ), ( rhs, rhsTy ) ]
        |> withResult resultVar I1
        |> withAttr "predicate" (StringAttr predicate)
        |> build
```

Then modify `Mlir.Pretty` to recognize `eco.int.cmp` / `eco.float.cmp` and print the predicate in the bare position.

**Option B: Use a custom attribute type**

Add a new MlirAttr variant for enum attributes (would require modifying the external elm-mlir package).

**Recommendation:** Option A is simpler and keeps changes localized to the pretty printer.

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
                    -- Error case, should not happen
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

        IntToFloat { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, I64 ) F64

        FloatToInt { op } ->
            let
                operand = List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) I64

        IntCmp { predicate } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoCmpOp ctx "eco.int.cmp" predicate resultVar ( lhs, I64 ) ( rhs, I64 )
                _ ->
                    ecoCmpOp ctx "eco.int.cmp" predicate resultVar ( "%error", I64 ) ( "%error", I64 )

        FloatCmp { predicate } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoCmpOp ctx "eco.float.cmp" predicate resultVar ( lhs, F64 ) ( rhs, F64 )
                _ ->
                    ecoCmpOp ctx "eco.float.cmp" predicate resultVar ( "%error", F64 ) ( "%error", F64 )
```

---

## Phase 4: Handle generateVarKernel (Function as Value)

When a kernel function is used as a **value** (not called directly), `generateVarKernel` is invoked. Currently it emits a 0-arg call:

```elm
generateVarKernel ctx home name monoType =
    { ops = [ ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType) ]
    , ...
    }
```

For intrinsics, we have two options:

### Option A: Create a PAP Wrapper (Recommended)

Similar to how `generateVarGlobal` handles function-typed globals:

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
        Mono.MFunction argTypes _ ->
            -- Function-typed kernel: create a PAP
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

This approach means intrinsic functions passed as values still use the runtime kernel implementation. Since passing operators as values is less common, this is acceptable.

### Option B: Generate Wrapper Functions (More Complex)

Generate a wrapper function that uses the intrinsic, then create a PAP to it. This is more complex and only worth doing if passing operators as values is performance-critical.

---

## Phase 5: Pretty Printer Updates

### 5.1 Handle Comparison Predicates

The `eco.int.cmp` and `eco.float.cmp` ops need special formatting:

```mlir
-- Current generic format (wrong):
%0 = eco.int.cmp %a, %b {predicate = "lt"} : i64

-- Correct format:
%0 = eco.int.cmp lt %a, %b : i64
```

**Modify `Mlir.Pretty`** to detect these ops and print the predicate attribute in the bare position:

```elm
-- In the pretty printer, when printing eco.int.cmp or eco.float.cmp:
-- 1. Extract the "predicate" attribute
-- 2. Print it before operands (without quotes)
-- 3. Remove it from the attr-dict when printing remaining attrs
```

---

## Open Questions (Decisions Required Before Implementation)

### Q1: Bitwise Integer Width

**Context:** Elm's `Bitwise` module operates on **32-bit** integers (per JavaScript semantics), but our `MonoType.MInt` is 64-bit. The kernel implementations (`Elm_Kernel_Bitwise_*`) use `int32_t`.

**Question:** How should we handle the 32-bit vs 64-bit mismatch?

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A** | Use `eco.int.*` (64-bit) for now | Simplest, no dialect changes | Results may differ for edge cases (e.g., overflow, sign extension) |
| **B** | Add 32-bit bitwise ops to eco dialect | Correct semantics | More dialect ops to maintain |
| **C** | Add truncation/extension ops | Explicit about conversions | Verbose generated code |

**Recommendation:** Option A (simplest). Add 32-bit support later if needed.

**Decision:** `[ ]` A  `[ ]` B  `[ ]` C  `[ ]` Other: _______________

---

### Q2: Comparisons - Utils vs Basics Module

**Context:** Looking at `KernelExports.h`, comparison functions (`lt`, `le`, `gt`, `ge`) are in the **Utils** module:
```c
int64_t Elm_Kernel_Utils_lt(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_le(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_gt(uint64_t a, uint64_t b);
int64_t Elm_Kernel_Utils_ge(uint64_t a, uint64_t b);
```

**Question:** What `home` module name does `MonoVarKernel` use when compiling `<`, `>`, `<=`, `>=`?

**Action Required:** Trace a comparison through the compiler to determine if the home is `"Utils"` or `"Basics"`.

**Answer:** _______________

---

### Q3: Trigonometric Functions

**Context:** The kernel exports include trig functions: `sin`, `cos`, `tan`, `acos`, `asin`, `atan`, `atan2`, `log`, `e`, `pi`.

**Question:** Should these become intrinsics (eco.float.sin, etc.) or stay as kernel calls?

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A** | Keep as kernel calls | No dialect changes, simpler | Extra function call overhead |
| **B** | Add eco.float.sin, etc. | Can inline to llvm.sin, etc. | More ops to define and lower |

**Recommendation:** Option A - these are not typically performance-critical hot paths.

**Decision:** `[ ]` A (kernel calls)  `[ ]` B (intrinsics)

---

### Q4: isNaN and isInfinite

**Context:** `Basics.isNaN` and `Basics.isInfinite` are in the kernel but not currently eco ops.

**Question:** Should these become eco ops?

| Option | Description |
|--------|-------------|
| **A** | Keep as kernel calls |
| **B** | Add `eco.float.isNaN` and `eco.float.isInfinite` ops |

**Recommendation:** Option A initially. Can add eco ops if needed.

**Decision:** `[ ]` A (kernel calls)  `[ ]` B (intrinsics)

---

### Q5: Pretty Printer for Comparison Predicates

**Context:** The `eco.int.cmp` and `eco.float.cmp` ops use a predicate that must appear **before** operands:

```mlir
-- Required format:
%0 = eco.int.cmp lt %a, %b : i64

-- Generic format (wrong):
%0 = eco.int.cmp %a, %b {predicate = "lt"} : i64
```

The pretty printer is in the external `the-sett/elm-mlir` package.

**Question:** How should we handle this special formatting?

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A** | Fork/modify elm-mlir package | Clean integration | Maintain fork divergence |
| **B** | Post-process MLIR output | No package changes | Fragile text manipulation |
| **C** | Build eco-specific printer | Full control | More code to maintain |
| **D** | Use generic format, fix in MLIR parser | Simple emission | Parser must handle both formats |

**Recommendation:** Try Option A first. If that's difficult, Option C gives us full control.

**Decision:** `[ ]` A  `[ ]` B  `[ ]` C  `[ ]` D  `[ ]` Other: _______________

---

### Q6: Kernel Functions as Values (Partial Application)

**Context:** When a kernel function is used as a value (not called directly), e.g., `List.map (+)`, we need to create a PAP. Currently `generateVarKernel` handles this.

**Question:** For intrinsic-eligible kernels used as values, should we:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A** | Create PAP pointing to kernel function | Simple, reuses runtime | No intrinsic benefit for HOF usage |
| **B** | Generate wrapper function using intrinsic, create PAP to wrapper | Consistent intrinsic usage | More complex, generates extra functions |

**Recommendation:** Option A - passing operators as values is uncommon and not typically a hot path.

**Decision:** `[ ]` A (PAP to kernel)  `[ ]` B (wrapper function)

---

## Implementation Order

1. **Phase 1**: Add `Intrinsic` type and `kernelIntrinsic` lookup table
2. **Phase 2**: Add `ecoUnaryOp`, `ecoBinaryOp`, `ecoCmpOp` builders
3. **Phase 3**: Modify `generateCall` to use intrinsics
4. **Phase 4**: Update `generateVarKernel` for function-typed kernels
5. **Phase 5**: Update pretty printer for comparison predicates
6. **Testing**: Add tests verifying intrinsic emission

---

## Testing Strategy

### Unit Tests
- Verify `kernelIntrinsic` returns correct intrinsic for each case
- Verify fallback to `Nothing` for non-intrinsic kernels

### Integration Tests
- Compile simple arithmetic expressions, verify output contains `eco.int.add` etc.
- Compile comparison expressions, verify output contains `eco.int.cmp lt` etc.
- Verify no `Elm_Kernel_Basics_add` calls for intrinsified operations
- Verify `Elm_Kernel_Basics_sin` etc. still generate kernel calls

### Golden Tests
Add MLIR output comparison tests for:
```elm
-- Should emit eco.int.add
add a b = a + b

-- Should emit eco.float.div
divide a b = a / b

-- Should emit eco.int.cmp lt
lessThan a b = a < b

-- Should emit kernel call (not intrinsic)
sine x = sin x
```
