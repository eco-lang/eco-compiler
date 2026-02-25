# Kernel Function Return Type Mismatch Bug - Complete Analysis

## Bug Summary

**Issue**: Kernel wrapper function calls generate eco.call operations with monomorphized concrete return types (e.g., `i64`) instead of the kernel wrapper's declared return type (`!eco.value`).

**MLIR Verifier Error**: 
```
'eco.call' op result 0 has type 'i64' but callee returns '!eco.value'
```

**Root Cause**: In `Expr.elm` line 2602, the `ElmDerived` ABI policy path uses:
```elm
resultMlirType = Types.monoTypeToAbi elmSig.returnType
```
where `elmSig.returnType` is the monomorphized return type from the call site, not the kernel's wrapped return type.

---

## Key Invariant Violated

**REP_ABI_001** (invariants.csv line 9):
> "At all function call boundaries (kernel or compiled), only Int, Float, and Char are passed and returned as pass-by-value MLIR types; all other Elm values including Bool cross the ABI as !eco.value regardless of their heap field representation"

Kernel functions are C++ implementations that:
1. Are declared with signatures that take/return `!eco.value` (boxed types)
2. Are monomorphized at each Elm call site with concrete types (e.g., `i -> i`)
3. Must be called with `!eco.value` return type at the ABI boundary

---

## Code Path Analysis

### 1. Call Return Type Determination (Expr.elm lines 1820-2612)

**Function**: `generateSaturatedCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult`

**For Kernel Functions** (line 2171: `Mono.MonoVarKernel _ home name funcType`):

Two ABI policies are handled:

#### Case A: AllBoxed Policy (Lines 2538-2578) - CORRECT
```elm
Ctx.AllBoxed ->
    -- Comment: "Underlying C++ ABI: all args and result are !eco.value, 
    --  regardless of the monomorphic Elm wrapper type."
    ...
    resultMlirType = Types.ecoValue  -- CORRECT: Always !eco.value
    ( ctx3, callOp ) = Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
```

Used for: List.*, Utils.*, String.fromNumber, JsArray.*, Json.wrap
These kernels explicitly declare all parameters and returns as `!eco.value` in C++.

#### Case B: ElmDerived Policy (Lines 2580-2612) - BUGGY
```elm
Ctx.ElmDerived ->
    -- Comment: "ABI derived from the Elm wrapper's funcType.
    --  Polymorphic kernels have MVar in their funcType, which
    --  Types.monoTypeToAbi maps to !eco.value, so they naturally
    --  get all-boxed ABI without name-based checks."
    ...
    elmSig = Ctx.kernelFuncSignatureFromType funcType  -- funcType is MonoVarKernel's type
    resultMlirType = Types.monoTypeToAbi elmSig.returnType  -- BUG: Uses monomorphized return!
    ( ctx3, callOp ) = Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
```

Used for: Basics.*, Bitwise.*, Char.*, String.* (most), Json.* (most), Browser.*, Bytes.*, etc.

### 2. How kernelFuncSignatureFromType Works (Context.elm lines 82-90)

```elm
kernelFuncSignatureFromType funcType =
    let
        ( argTypes, retType ) = Mono.decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    }
```

**Critical**: `funcType` is the **MonoVarKernel's monomorphized type at the call site**.

Example:
- Kernel in C++ header: `unsafeGet : Polymorphic -> (JsArray a -> Int -> a)`
- At call site 1: `funcType = (JsArray Int -> Int -> Int)` → `retType = Int`
- At call site 2: `funcType = (JsArray String -> Int -> String)` → `retType = String`

When `retType` is converted to MLIR:
- `Types.monoTypeToAbi Int` → `i64`
- `Types.monoTypeToAbi String` → `!eco.value`

This creates **mismatched call sites for the same kernel**.

### 3. Kernel Declaration Generation (Backend.elm lines 91-102, Functions.elm 1022-1067)

```elm
-- In Backend.elm, for each kernel name:
( kernelDeclOps, _ ) = Dict.foldl
    (\name sig ( accOps, accCtx ) ->
        let
            ( newCtx, declOp ) = Functions.generateKernelDecl accCtx name sig
        in
        ( accOps ++ [ declOp ], newCtx )
    )
    ( [], finalCtx )
    finalCtx.kernelDecls  -- Dict: name -> (argTypes, returnType)
```

The `sig` comes from `finalCtx.kernelDecls`, which is populated by `Ops.ecoCallNamed` via `Ctx.registerKernelCall`.

**Critical Mismatch**: If multiple call sites register the same kernel with different return types:
1. First call site: `Elm_Kernel_JsArray_unsafeGet` registers with return type `i64` (for Int)
2. Second call site: Same kernel, returns `!eco.value` (for String)
3. Result: `registerKernelCall` crashes with "Kernel signature mismatch" 
   OR if Dict keeps last value, declaration uses wrong return type

### 4. registerKernelCall (Context.elm lines 622-648)

```elm
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    case Dict.get name ctx.kernelDecls of
        Nothing ->
            -- First registration: store as-is
            { ctx | kernelDecls = Dict.insert name ( callSiteArgTypes, callSiteReturnType ) ctx.kernelDecls }
        
        Just ( existingArgs, existingReturn ) ->
            if existingArgs == callSiteArgTypes && existingReturn == callSiteReturnType then
                -- Consistent registration
                ctx
            else
                -- CRASH: Signature mismatch
                crash ("Kernel signature mismatch for " ++ name ++ ": existing (...) vs new (...)")
```

---

## The Problem Scenario

**Example Kernel**: `JsArray.unsafeGet : JsArray a -> Int -> a` (polymorphic)

**Call Site 1**: `(List.map (\x -> JsArray.unsafeGet arr 0) intList)`
- Monomorphized: `JsArray Int -> Int -> Int`
- Call at line 2602: `elmSig.returnType = Int` → `monoTypeToAbi = i64`
- Registers kernel: `("Elm_Kernel_JsArray_unsafeGet", ([!eco.value, i64], i64))`
- Generates call: `eco.call(...) -> i64`

**Call Site 2**: `(List.map (\x -> JsArray.unsafeGet arr 0) stringList)`
- Monomorphized: `JsArray String -> Int -> String`
- Call at line 2602: `elmSig.returnType = String` → `monoTypeToAbi = !eco.value`
- Attempts to register kernel: `("Elm_Kernel_JsArray_unsafeGet", ([!eco.value, i64], !eco.value))`
- **ERROR**: Signature mismatch! Or Dict keeps last one, causing MLIR verifier error.

---

## Why AllBoxed Works

For `AllBoxed` kernels (JsArray.*, List.*, etc.), the C++ implementations are audited to:
1. Accept all parameters as `uint64_t` (mapped to `!eco.value` in MLIR)
2. Return all results as `uint64_t` (mapped to `!eco.value` in MLIR)
3. Box/unbox primitives internally

So code at line 2568 `Types.ecoValue` is always correct - there's no monomorphization variation.

---

## Why The Comment is Misleading

Lines 2581-2584:
```elm
-- ABI derived from the Elm wrapper's funcType.
-- Polymorphic kernels have MVar in their funcType, which
-- Types.monoTypeToAbi maps to !eco.value, so they naturally
-- get all-boxed ABI without name-based checks.
```

**The comment is WRONG**. When a kernel is **monomorphized**, the `funcType` no longer has `MVar` - it has concrete types like `Int`, `String`, etc. The assumption that "MVar → !eco.value" is only true if:
- The kernel is never monomorphized (stays polymorphic)
- OR the monomorphization was never generated at MLIR codegen time

But in reality, if a kernel is called at multiple call sites with different type arguments, it gets monomorphized to each concrete type in the MonoGraph.

---

## The Real Solution

Kernel functions **must always return `!eco.value`** at the call site, not the monomorphized type.

The fix should be:

```elm
Ctx.ElmDerived ->
    let
        elmSig : Ctx.FuncSignature
        elmSig = Ctx.kernelFuncSignatureFromType funcType
        
        ( boxOps, argVarPairs, ctx1b ) =
            boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes
        
        ( resVar, ctx2 ) = Ctx.freshVar ctx1b
        
        kernelName : String
        kernelName = "Elm_Kernel_" ++ home ++ "_" ++ name
        
        -- FIX: Kernel return type is always !eco.value at ABI boundary (REP_ABI_001)
        resultMlirType : MlirType
        resultMlirType = Types.ecoValue  -- Was: Types.monoTypeToAbi elmSig.returnType
        
        ( ctx3, callOp ) =
            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
    in
    { ops = argOps ++ boxOps ++ [ callOp ]
    , resultVar = resVar
    , resultType = resultMlirType
    , ctx = ctx3
    , isTerminated = False
    }
```

---

## Verification Points

1. **Declaration Consistency**: All calls to the same kernel register with the same return type
2. **Type Verification**: `generateKernelDecl` receives `(argMlirTypes, !eco.value)` consistently
3. **MLIR Validity**: `eco.call` result type matches callee function return type
4. **Invariant Compliance**: REP_ABI_001 requirement enforced

---

## Affected Kernels

Kernels using `ElmDerived` policy that could be called polymorphically:
- Basics.* (e.g., `negate`, `sqrt`, `sin`)
- Bitwise.* (e.g., `and`, `or`)
- String.* (e.g., `cons`, `slice`, `repeat`)
- Json.* (e.g., `decodeIndex`, `encode`)
- Bytes.* (e.g., `read functions with Float/Int polymorphism`)
- Browser.* (e.g., `go`, `reload`)
- Any kernel with generic type variables that get monomorphized to different concrete types

---

## Files to Modify

**Primary**: `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`
- Line 2600-2602: Change from `Types.monoTypeToAbi elmSig.returnType` to `Types.ecoValue`
- Update comment on lines 2581-2584 to clarify the fix
