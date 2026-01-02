# Big Fix: MLIR Code Generation and Type System Corrections

## Overview

This plan addresses 8 interrelated issues in the Guida compiler's MLIR code generation that collectively cause ~100+ E2E test failures. The fixes are organized by category with specific implementation details.

---

## Issue 1: Declare Type Signatures Correctly

**Error Pattern:** `expected N operand type(s) but had 0`

**Affected Tests:** ~32 tests (AnonymousFunctionTest, ListMapTest, RecursiveFactorialTest, etc.)

### Root Cause

The MLIR generator produces operations with operands but empty type signatures in the output position:

```mlir
-- WRONG: Has operands (%x, %xs) but declares () as input types
%4 = "eco.call"(%x, %xs) <{callee = @List_cons}> : () -> !eco.value

-- CORRECT: Type signature matches operands
%4 = "eco.call"(%x, %xs) <{callee = @List_cons}> : (!eco.value, !eco.value) -> !eco.value
```

This affects `eco.call`, `eco.project`, and `eco.papExtend` operations.

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### Fix Details

#### 1.1 Fix `ecoCallNamed` (lines ~2936-2960)

The function already builds `_operand_types` attribute correctly, but the issue is that the MLIR output format needs the type signature after the `:`. Ensure `opBuilder` emits the correct function type signature:

```elm
-- Current: The opBuilder.withOperands/withResults should emit:
--   : (operandTypes...) -> resultType
-- Verify the MLIR serialization in the opBuilder produces this format
```

**Action:** Audit `opBuilder.build` to ensure it serializes operand types in the MLIR text output, not just in `_operand_types` attribute.

#### 1.2 Fix `ecoProject` (lines ~2965-2990)

```elm
ecoProject ctx resultVar index isUnboxed operand operandType =
    -- Ensure the output includes: : (operandType) -> resultType
    -- The _operand_types attribute AND the inline type signature must both be correct
```

#### 1.3 Fix `eco.papExtend` generation (lines ~1870-1930)

Same pattern - ensure type signature includes operand types.

### Verification

After fix, MLIR should show:
```mlir
%4 = "eco.call"(%x, %xs) <{callee = @fn}> : (!eco.value, !eco.value) -> !eco.value
%5 = "eco.project"(%obj) {index = 0} : (!eco.value) -> !eco.value
%6 = "eco.papExtend"(%f, %a, %b) {remaining_arity = 0} : (!eco.value, !eco.value, !eco.value) -> !eco.value
```

---

## Issue 2: Each Tag Alternative Needs Its Own Region

**Error Pattern:** `'eco.case' op number of tags (N) must match number of alternative regions (1)`

**Affected Tests:** CaseIntTest, CaseManyBranchesTest, CaseStringTest

### Root Cause

The compiler generates `eco.case` with multiple tags but puts all alternatives in a single region:

```mlir
-- WRONG: 2 tags, 1 region
"eco.case"(%n) ({
    %1 = "eco.string_literal"() {value = "one"} : () -> !eco.value
    %3 = "eco.string_literal"() {value = "two"} : () -> !eco.value
}) {tags = array<i64: 1, 2>} : (!eco.value) -> ()

-- CORRECT: 2 tags, 2 regions (plus fallback = 3 total)
"eco.case"(%n) ({
    %1 = "eco.string_literal"() {value = "one"} : () -> !eco.value
    "eco.return"(%1)
}, {
    %2 = "eco.string_literal"() {value = "two"} : () -> !eco.value
    "eco.return"(%2)
}, {
    -- fallback
    %3 = "eco.string_literal"() {value = "other"} : () -> !eco.value
    "eco.return"(%3)
}) {tags = array<i64: 1, 2>} : (!eco.value) -> ()
```

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
**Function:** `generateFanOut` (lines ~2582-2633)

### Fix Details

The `generateFanOut` function should be generating separate regions. Check:

1. **Region list construction** - ensure `allRegions` contains N+1 regions (one per tag + fallback)
2. **Each region must be separate** - not concatenated into one
3. **Each region must terminate** with `eco.return` or `eco.jump`

```elm
generateFanOut ctx root path edges fallback resultTy =
    let
        -- Generate one region per edge
        ( edgeRegions, ctx2 ) =
            List.foldl
                (\( test, subTree ) ( accRegions, accCtx ) ->
                    let
                        subRes = generateDecider accCtx root subTree resultTy
                        -- Each subRes.ops should end with eco.return
                        region = mkRegionFromOps subRes.ops
                    in
                    ( accRegions ++ [ region ], subRes.ctx )
                )
                ( [], ctx1 )
                edges

        -- Generate fallback region
        fallbackRes = generateDecider ctx2 root fallback resultTy
        fallbackRegion = mkRegionFromOps fallbackRes.ops

        -- Combine: edge regions + fallback region
        allRegions = edgeRegions ++ [ fallbackRegion ]

        -- Tags should match number of edge regions (fallback has no tag)
        tags = List.map testToTagInt edges
    in
    ...
```

---

## Issue 3: Terminate Basic Blocks Correctly

**Error Pattern:** `Assertion 'mightHaveTerminator()' failed` (SIGABRT)

**Affected Tests:** CaseBoolTest

### Root Cause

MLIR basic blocks must end with a terminator operation. Some generated regions lack proper `eco.return` terminators.

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### Fix Details

#### 3.1 Add helper to ensure termination

```elm
ensureTerminated : List MlirOp -> String -> MlirType -> Context -> ( List MlirOp, Context )
ensureTerminated ops resultVar resultTy ctx =
    case List.reverse ops of
        [] ->
            -- Empty ops: add eco.return with dummy value
            let
                ( dummyVar, ctx1 ) = freshVar ctx
                ( ctx2, constOp ) = ecoConstruct ctx1 dummyVar 0 0 0 []
                ( ctx3, retOp ) = ecoReturn ctx2 dummyVar resultTy
            in
            ( [ constOp, retOp ], ctx3 )

        lastOp :: _ ->
            if isTerminator lastOp then
                ( ops, ctx )
            else
                -- Add eco.return for the result
                let
                    ( ctx1, retOp ) = ecoReturn ctx resultVar resultTy
                in
                ( ops ++ [ retOp ], ctx1 )
```

#### 3.2 Apply to region builders

In `generateIf`, `generateChain`, `generateFanOut`, ensure every region's ops list ends with a terminator before calling `mkRegionFromOps`.

---

## Issue 4: Monomorphized Number Functions Should Expect Unboxed Values

**Error Pattern:** SIGSEGV when calling `Basics_negate_$_2` and similar

**Affected Tests:** IntAddTest, FloatAddTest, IntMulTest, etc. (~35 tests)

### Root Cause

The compiler generates calls passing unboxed `i64`/`f64` to wrapper functions that expect `!eco.value`:

```mlir
-- Call site passes i64:
%9 = "eco.call"(%8) <{callee = @Basics_negate_$_2}> : (i64) -> i64

-- But function expects !eco.value:
"func.func"() ({
  ^bb0(%n: !eco.value):    -- MISMATCH!
    ...
}) {sym_name = "Basics_negate_$_2"}
```

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
**Functions:** `generateNode`, wrapper function generation

### Fix Details

When generating specialized/monomorphized versions of polymorphic functions:

1. **Wrapper parameter types must match call sites**
2. **If caller passes `i64`, wrapper must accept `i64`**
3. **If wrapper calls kernel that needs `!eco.value`, wrapper does the boxing**

#### 4.1 Consistent monomorphization

For a function `negate : number -> number` specialized to `Int`:

```mlir
-- Specialized wrapper accepts and returns i64:
"func.func"() ({
  ^bb0(%n: i64):
    -- If kernel needs boxed, box here
    %boxed = "eco.box"(%n) : (i64) -> !eco.value
    %result = "eco.call"(%boxed) <{callee = @Elm_Kernel_Basics_negate}> : (!eco.value) -> !eco.value
    %unboxed = "eco.unbox"(%result) : (!eco.value) -> i64
    "eco.return"(%unboxed) : (i64) -> ()
}) {function_type = (i64) -> (i64), sym_name = "Basics_negate_$_Int"}
```

Or better - use type-specific intrinsics:

```mlir
"func.func"() ({
  ^bb0(%n: i64):
    %zero = "arith.constant"() {value = 0 : i64} : () -> i64
    %result = "eco.int.sub"(%zero, %n) : (i64, i64) -> i64
    "eco.return"(%result) : (i64) -> ()
}) {function_type = (i64) -> (i64), sym_name = "Basics_negate_$_Int"}
```

#### 4.2 Audit all `Basics_*` wrappers

Ensure each monomorphized wrapper has consistent types between:
- Function signature (`function_type`)
- Block argument types
- Call sites

---

## Issue 5: (Skipped - covered by Issue 4)

---

## Issue 6: Do Not Box `eco.value`, Only Unbox Unboxed Values

**Error Pattern:** Wrong output values (pointer addresses instead of values)

**Affected Tests:** AddTest, TupleSecondTest, CharToCodeTest, etc. (~12 tests)

### Root Cause

Code boxes already-boxed values, creating double indirection:

```mlir
-- WRONG: result is already !eco.value, boxing it again creates garbage
%result = "eco.construct"(%0) {size = 1, tag = 0} : (i64) -> !eco.value
%2 = "eco.box"(%result) : (!eco.value) -> !eco.value   -- Double boxing!
```

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
**Functions:** Wherever `eco.box` is emitted

### Fix Details

#### 6.1 Add type-aware boxing helper

```elm
boxIfNeeded : Context -> String -> MlirType -> ( List MlirOp, String, Context )
boxIfNeeded ctx varName varType =
    case varType of
        EcoValue ->
            -- Already boxed, don't box again
            ( [], varName, ctx )

        I64 ->
            let
                ( boxedVar, ctx1 ) = freshVar ctx
                ( ctx2, boxOp ) = ecoBox ctx1 boxedVar varName I64
            in
            ( [ boxOp ], boxedVar, ctx2 )

        F64 ->
            let
                ( boxedVar, ctx1 ) = freshVar ctx
                ( ctx2, boxOp ) = ecoBox ctx1 boxedVar varName F64
            in
            ( [ boxOp ], boxedVar, ctx2 )

        I1 ->
            -- Bools: box as i64
            let
                ( extVar, ctx1 ) = freshVar ctx
                ( ctx2, extOp ) = zextI1ToI64 ctx1 extVar varName
                ( boxedVar, ctx3 ) = freshVar ctx2
                ( ctx4, boxOp ) = ecoBox ctx3 boxedVar extVar I64
            in
            ( [ extOp, boxOp ], boxedVar, ctx4 )

        _ ->
            -- Already a reference type
            ( [], varName, ctx )
```

#### 6.2 Apply consistently

Before calling Debug.log or any function expecting `!eco.value`, use `boxIfNeeded` instead of unconditional `eco.box`.

---

## Issue 7: Eco Uses 64-bit Bitwise Operations (Update Tests)

**Error Pattern:** `shift32: 0` expected but got `4294967296`

**Affected Tests:** BitwiseLargeShiftTest

### Root Cause

Elm's bitwise operations operate on 32-bit integers (JavaScript semantics), but Eco uses 64-bit integers. This is a **design choice difference**, not a bug.

### Fix Location

**File:** `/work/test/elm/src/BitwiseLargeShiftTest.elm`

### Fix Details

Update the test expectations to match 64-bit behavior:

```elm
-- OLD (32-bit Elm semantics):
-- CHECK: shift32: 0
-- CHECK: shift63: -9223372036854775808

-- NEW (64-bit Eco semantics):
-- CHECK: shift32: 4294967296
-- CHECK: shift63: -9223372036854775808
```

Or add a comment explaining the difference:

```elm
{-| Test large bitwise shifts.

Note: Eco differs from standard Elm - bitwise operations work on 64-bit integers,
not 32-bit. Shifting left by 32 produces 2^32, not 0.
-}

-- CHECK: shift32: 4294967296
```

---

## Issue 8: Char is i16, Kernel Function Signatures are i16

**Error Pattern:** `'llvm.call' op operand type mismatch: 'i64' != 'i16'`

**Affected Tests:** CharIsAlphaTest, CharIsDigitTest

### Root Cause

The kernel functions use `uint16_t` for Char:

```cpp
// elm-kernel-cpp/src/KernelExports.h
uint16_t Elm_Kernel_Char_fromCode(int64_t code);
int64_t Elm_Kernel_Char_toCode(uint16_t c);
uint16_t Elm_Kernel_Char_toLower(uint16_t c);
```

But the compiler generates calls passing `i64`.

### Fix Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### Fix Details

#### 8.1 Add Char type representation

```elm
-- Add I16 to MlirType if not present
type MlirType
    = I1
    | I16    -- NEW: for Char
    | I32
    | I64
    | F64
    | EcoValue
    | ...
```

#### 8.2 Map Elm Char to i16

```elm
monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoType =
    case monoType of
        Mono.MChar ->
            I16   -- Was I64, change to I16
        ...
```

#### 8.3 Update kernel intrinsic signatures

In the `kernelIntrinsic` function, ensure Char functions have correct signatures:

```elm
kernelIntrinsic home name argTypes resultType =
    case ( home, name ) of
        ( "Char", "toCode" ) ->
            Just { argTypes = [ I16 ], resultType = I64 }

        ( "Char", "fromCode" ) ->
            Just { argTypes = [ I64 ], resultType = I16 }

        ( "Char", "toLower" ) ->
            Just { argTypes = [ I16 ], resultType = I16 }

        ( "Char", "toUpper" ) ->
            Just { argTypes = [ I16 ], resultType = I16 }
        ...
```

#### 8.4 Add truncation/extension at boundaries

When calling Char kernel functions:

```elm
-- If caller has i64 but kernel expects i16, truncate:
%charI16 = "arith.trunci"(%charI64) : (i64) -> i16
%result = "eco.call"(%charI16) <{callee = @Elm_Kernel_Char_toLower}> : (i16) -> i16

-- If kernel returns i16 but caller expects i64, extend:
%resultI64 = "arith.extui"(%result) : (i16) -> i64
```

---

## Implementation Order

1. **Issue 1** (Type signatures) - Highest impact, enables parsing
2. **Issue 2** (Case regions) - Required for case expressions
3. **Issue 3** (Terminators) - Stability fix
4. **Issue 4 + 6** (Boxing/unboxing) - Fix runtime crashes and wrong values
5. **Issue 8** (Char types) - Type correctness
6. **Issue 7** (Test update) - Last, just test file change

## Files to Modify

| File | Issues |
|------|--------|
| `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm` | 1, 2, 3, 4, 6, 8 |
| `/work/test/elm/src/BitwiseLargeShiftTest.elm` | 7 |

## Expected Outcome

After all fixes:
- ~100 tests should change from FAILED to OK
- Remaining failures may reveal additional issues (partial application, records, etc.)
