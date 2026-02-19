# Compiler Intrinsics Theory

## Overview

Compiler intrinsics are operations that bypass the normal kernel function call mechanism and lower directly to efficient MLIR operations. This eliminates function call overhead for core arithmetic, boolean, and bitwise operations on primitive types.

**Phase**: MLIR Generation

**Pipeline Position**: During kernel call emission, before fallback to kernel ABI

**Related Modules**:
- `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` (call site)
- `runtime/src/codegen/Eco/EcoOps.td` (MLIR op definitions)

## Motivation

Consider `Basics.add : number -> number -> number`. In standard compilation:

1. Monomorphization determines argument types (Int or Float)
2. Kernel ABI (NumberBoxed) would box arguments as `eco.value`
3. C++ kernel receives boxed values, dispatches by tag
4. Result is returned boxed, then unboxed

With intrinsics:

1. Monomorphization determines argument types
2. **Intrinsic lookup intercepts**: `add` with `[MInt, MInt]` → `eco.int.add`
3. Arguments stay unboxed (`i64`)
4. Single MLIR op emitted
5. No function call, no boxing overhead

**Key insight**: Intrinsics are selected based on **monomorphized argument types**, not the polymorphic kernel signature. This means `NumberBoxed` kernels like `add`, `sub`, `mul` are rarely used—intrinsics handle the concrete `Int` and `Float` cases directly.

## Intrinsic Categories

```elm
type Intrinsic
    = UnaryInt { op : String }      -- i64 -> i64
    | BinaryInt { op : String }     -- i64, i64 -> i64
    | UnaryFloat { op : String }    -- f64 -> f64
    | BinaryFloat { op : String }   -- f64, f64 -> f64
    | UnaryBool { op : String }     -- i1 -> i1
    | BinaryBool { op : String }    -- i1, i1 -> i1
    | IntToFloat                    -- i64 -> f64
    | FloatToInt { op : String }    -- f64 -> i64
    | IntComparison { op : String } -- i64, i64 -> i1
    | FloatComparison { op : String } -- f64, f64 -> i1
    | FloatClassify { op : String } -- f64 -> i1
    | ConstantFloat { value : Float } -- () -> f64
```

Each category specifies:
- Expected operand types
- Result type
- The ECO dialect operation to emit

## Intrinsic Lookup

The `kernelIntrinsic` function maps kernel calls to intrinsics:

```elm
kernelIntrinsic : Name -> Name -> List MonoType -> MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics"  -> basicsIntrinsic name argTypes resultType
        "Bitwise" -> bitwiseIntrinsic name argTypes resultType
        "Utils"   -> utilsIntrinsic name argTypes resultType
        _         -> Nothing
```

### Basics Module Intrinsics

| Elm Function | Arg Types | Intrinsic | MLIR Op |
|--------------|-----------|-----------|---------|
| `add` | `[MInt, MInt]` | `BinaryInt` | `eco.int.add` |
| `add` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.add` |
| `sub` | `[MInt, MInt]` | `BinaryInt` | `eco.int.sub` |
| `sub` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.sub` |
| `mul` | `[MInt, MInt]` | `BinaryInt` | `eco.int.mul` |
| `mul` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.mul` |
| `idiv` | `[MInt, MInt]` | `BinaryInt` | `eco.int.div` |
| `fdiv` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.div` |
| `modBy` | `[MInt, MInt]` | `BinaryInt` | `eco.int.modby` |
| `remainderBy` | `[MInt, MInt]` | `BinaryInt` | `eco.int.remainderby` |
| `negate` | `[MInt]` | `UnaryInt` | `eco.int.negate` |
| `negate` | `[MFloat]` | `UnaryFloat` | `eco.float.negate` |
| `abs` | `[MInt]` | `UnaryInt` | `eco.int.abs` |
| `abs` | `[MFloat]` | `UnaryFloat` | `eco.float.abs` |
| `pow` | `[MInt, MInt]` | `BinaryInt` | `eco.int.pow` |
| `pow` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.pow` |
| `sqrt` | `[MFloat]` | `UnaryFloat` | `eco.float.sqrt` |
| `min` | `[MInt, MInt]` | `BinaryInt` | `eco.int.min` |
| `min` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.min` |
| `max` | `[MInt, MInt]` | `BinaryInt` | `eco.int.max` |
| `max` | `[MFloat, MFloat]` | `BinaryFloat` | `eco.float.max` |

**Trigonometric functions** (Float only):
- `sin`, `cos`, `tan` → `eco.float.{sin,cos,tan}`
- `asin`, `acos`, `atan` → `eco.float.{asin,acos,atan}`
- `atan2` → `eco.float.atan2`
- `log` → `eco.float.log`

**Type conversions**:
- `toFloat : Int -> Float` → `IntToFloat` → `eco.int.toFloat`
- `round`, `floor`, `ceiling`, `truncate` → `FloatToInt` → `eco.float.{round,floor,ceiling,truncate}`

**Comparisons**:
- `lt`, `le`, `gt`, `ge`, `eq`, `neq` for both `[MInt, MInt]` and `[MFloat, MFloat]`
- Int comparisons → `IntComparison` → `eco.int.{lt,le,gt,ge,eq,ne}`
- Float comparisons → `FloatComparison` → `eco.float.{lt,le,gt,ge,eq,ne}`

**Float classification**:
- `isNaN` → `FloatClassify` → `eco.float.isNaN`
- `isInfinite` → `FloatClassify` → `eco.float.isInfinite`

**Boolean operations**:
- `not : Bool -> Bool` → `UnaryBool` → `eco.bool.not`
- `and`, `or`, `xor : Bool -> Bool -> Bool` → `BinaryBool` → `eco.bool.{and,or,xor}`

**Constants**:
- `pi` → `ConstantFloat { value = 3.141592653589793 }`
- `e` → `ConstantFloat { value = 2.718281828459045 }`

### Bitwise Module Intrinsics

| Elm Function | Intrinsic | MLIR Op |
|--------------|-----------|---------|
| `and` | `BinaryInt` | `eco.int.and` |
| `or` | `BinaryInt` | `eco.int.or` |
| `xor` | `BinaryInt` | `eco.int.xor` |
| `complement` | `UnaryInt` | `eco.int.complement` |
| `shiftLeftBy` | `BinaryInt` | `eco.int.shl` |
| `shiftRightBy` | `BinaryInt` | `eco.int.shr` |
| `shiftRightZfBy` | `BinaryInt` | `eco.int.shru` |

### Utils Module Intrinsics

The `Utils` kernel module provides comparison primitives:

| Elm Function | Arg Types | MLIR Op |
|--------------|-----------|---------|
| `equal` | `[MInt, MInt]` | `eco.int.eq` |
| `notEqual` | `[MInt, MInt]` | `eco.int.ne` |
| `lt`, `le`, `gt`, `ge` | `[MInt, MInt]` | `eco.int.{lt,le,gt,ge}` |
| `equal` | `[MFloat, MFloat]` | `eco.float.eq` |
| `notEqual` | `[MFloat, MFloat]` | `eco.float.ne` |
| `lt`, `le`, `gt`, `ge` | `[MFloat, MFloat]` | `eco.float.{lt,le,gt,ge}` |

## Integration with MLIR Generation

During expression codegen, kernel calls are checked for intrinsic matches:

```elm
generateKernelCall : Context -> Name -> Name -> List MonoType -> MonoType -> List (String, MlirType) -> ...
generateKernelCall ctx home name argTypes resultType args =
    case Intrinsics.kernelIntrinsic home name argTypes resultType of
        Just intrinsic ->
            -- Emit direct MLIR op
            let
                (unboxOps, unboxedArgs, ctx1) = unboxArgsForIntrinsic ctx args intrinsic
                (resultVar, ctx2) = Ctx.freshVar ctx1
                (ctx3, intrinsicOp) = generateIntrinsicOp ctx2 intrinsic resultVar unboxedArgs
            in
            ( unboxOps ++ [intrinsicOp], resultVar, ctx3 )

        Nothing ->
            -- Fall back to kernel function call
            generateKernelFunctionCall ctx home name args resultType
```

### Automatic Unboxing

When arguments arrive as `!eco.value` but the intrinsic expects primitive types, `unboxArgsForIntrinsic` inserts unboxing:

```elm
unboxArgsForIntrinsic : Context -> List (String, MlirType) -> Intrinsic -> (List MlirOp, List String, Context)
```

This handles cases where values flow from polymorphic contexts into intrinsic-eligible calls.

## MLIR Operation Generation

The `generateIntrinsicOp` function emits typed ECO dialect operations:

```mlir
// BinaryInt { op = "eco.int.add" }
%result = eco.int.add %lhs, %rhs : i64, i64 -> i64
    { _operand_types = [i64, i64] }

// UnaryFloat { op = "eco.float.sin" }
%result = eco.float.sin %arg : f64 -> f64
    { _operand_types = [f64] }

// IntComparison { op = "eco.int.lt" }
%result = eco.int.lt %lhs, %rhs : i64, i64 -> i1
    { _operand_types = [i64, i64] }
```

## LLVM Lowering

ECO intrinsic operations are lowered to LLVM in `EcoToLLVM.cpp`:

| ECO Op | LLVM Lowering |
|--------|---------------|
| `eco.int.add` | `llvm.add` |
| `eco.int.sub` | `llvm.sub` |
| `eco.int.mul` | `llvm.mul` |
| `eco.int.div` | `llvm.sdiv` |
| `eco.float.add` | `llvm.fadd` |
| `eco.float.mul` | `llvm.fmul` |
| `eco.float.sin` | `llvm.sin` (intrinsic) |
| `eco.float.sqrt` | `llvm.sqrt` (intrinsic) |
| `eco.int.lt` | `llvm.icmp slt` |
| `eco.float.lt` | `llvm.fcmp olt` |
| `eco.int.shl` | `llvm.shl` |
| `eco.int.shr` | `llvm.ashr` |
| `eco.int.shru` | `llvm.lshr` |

## Relationship to Kernel ABI

Intrinsics and kernel ABIs are complementary:

1. **Intrinsics first**: During codegen, `kernelIntrinsic` is checked before kernel ABI
2. **NumberBoxed rarely used**: Most `Basics` operations that would use `NumberBoxed` ABI are caught by intrinsics when types are concrete
3. **Kernel fallback**: Operations without intrinsics (e.g., `String.fromNumber`) use kernel ABI

**Example flow**:
```
Elm: 2 + 3
Monomorphized: Basics.add : Int -> Int -> Int
                argTypes = [MInt, MInt]

Check intrinsics: basicsIntrinsic "add" [MInt, MInt] MInt
  → Just (BinaryInt { op = "eco.int.add" })

Emit: %result = eco.int.add %2, %3 : i64, i64 -> i64

(Kernel ABI never consulted)
```

**When kernels ARE used**:
- Polymorphic operations that remain polymorphic (rare after monomorphization)
- Operations without intrinsics: `String.fromNumber`, `List.cons`, etc.
- Debug module operations (always boxed ABI)

## Invariants

- **INTR_001**: Intrinsic lookup is based on monomorphized argument types, not polymorphic signatures
- **INTR_002**: Intrinsic operand types must match the actual SSA types of arguments
- **INTR_003**: Intrinsic result types are always primitive (`i64`, `f64`, `i1`) except for constants
- **INTR_004**: Unboxing is automatically inserted when arguments have `!eco.value` type
- **INTR_005**: Intrinsics have priority over kernel calls—if an intrinsic matches, it is always used

## Performance Benefits

1. **No function call overhead**: Direct MLIR ops instead of C++ kernel calls
2. **No boxing/unboxing**: Primitives stay in registers
3. **LLVM optimization**: Arithmetic ops can be optimized, inlined, vectorized
4. **Predictable codegen**: Same operation always generates the same MLIR

## See Also

- [Kernel ABI Theory](kernel_abi_theory.md) — Fallback path when intrinsics don't match
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Integration point for intrinsics
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — LLVM lowering of intrinsic operations
