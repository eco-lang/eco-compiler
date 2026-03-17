# Bootstrap Stage 6 Errors

Stage 6 (`eco-boot-native` parsing `eco-compiler.mlir`) fails with **37 MLIR verification errors** across 5 categories. This document catalogues each category with full location details and MLIR context.

---

## 1. Missing `predicate` attribute on `arith.cmpi` (12 errors)

**Error message:** `'arith.cmpi' op requires attribute 'predicate'`

**Root cause:** The Eco compiler emits `arith.cmpi` ops comparing `i16` operands without the required `predicate` attribute. Comparisons of `i32` operands correctly include `predicate = 0 : i64`, but `i16`-vs-`i16` comparisons (Char equality checks) omit it entirely.

All 12 errors follow the same pattern: an `i16` value is projected from a tuple or custom type, compared against an `i16` constant (character literal), and the `arith.cmpi` is emitted without `predicate`.

**Correct emission (i32 comparison):**
```mlir
%8 = "arith.cmpi"(%6, %7) {_operand_types = [i32, i32], predicate = 0 : i64} : (i32, i32) -> i1
```

**Incorrect emission (i16 comparison — missing predicate):**
```mlir
%250 = "arith.cmpi"(%248, %249) {_operand_types = [i16, i16]} : (i16, i16) -> i1
```

### Locations

| # | Line | Char value | Enclosing context |
|---|------|------------|-------------------|
| 1 | 22202 | `44` (`,`) | Record type parsing — `Compiler_Reporting_Error_Syntax` |
| 2 | 30576 | `44` (`,`) | Record parsing — `Compiler_Reporting_Error_Syntax` |
| 3 | 415052 | `92` (`\`) | `Compiler_Generate_MLIR_Expr_decodeEscape_$_28067` |
| 4 | 485497 | `123` (`{`) | `Common_Format_Render_Box_formatComment_$_31987` area |
| 5 | 486029 | `123` (`{`) | `Common_Format_Render_Box` — comment formatting |
| 6 | 486757 | `123` (`{`) | `Common_Format_Render_Box` — trailing comment formatting |
| 7 | 518268 | `45` (`-`) | Cheapskate markdown parser — dash in list detection |
| 8 | 518740 | `92` (`\`) | `Common_Format_Cheapskate_ParserCombinators_Position` |
| 9 | 523408 | `40` (`(`) | Cheapskate markdown parser — parenthesis matching |
| 10 | 534968 | `53` (`5`) | Digit comparison in number parsing |
| 11 | 535089 | `92` (`\`) | `_tail_go_309331` — string escape processing |
| 12 | 662441 | `125` (`}`) | Cheapskate markdown — brace detection |

### MLIR context for representative error (line 22202)

```mlir
// Line 22198 — correct i32 comparison WITH predicate:
%245 = "arith.cmpi"(%243, %244) {_operand_types = [i32, i32], predicate = 0 : i64} : (i32, i32) -> i1

// Line 22200-22202 — incorrect i16 comparison WITHOUT predicate:
%248 = "eco.project.custom"(%246) {_operand_types = [!eco.value], field_index = 0} : (!eco.value) -> i16
%249 = "arith.constant"() {value = 44 : i16} : () -> i16
%250 = "arith.cmpi"(%248, %249) {_operand_types = [i16, i16]} : (i16, i16) -> i1   // <-- ERROR
```

---

## 2. `eco.papExtend` remaining_arity mismatch (12 errors)

**Error message:** `'eco.papExtend' op remaining_arity = N but computed remaining arity from papCreate chain is M`

**Root cause:** The `remaining_arity` attribute on `eco.papExtend` is inconsistent with the arity chain computed from the preceding `eco.papCreate` ops. Two distinct sub-patterns appear:

### Sub-pattern A: `remaining_arity = 4` but computed = 2 (7 errors)

All involve the same codegen pattern: `Pretty_append_$_115` (arity 2) is wrapped in a `Basics_Extra_lambda` closure (arity 3, capturing the append PAP), then `papExtend` claims `remaining_arity = 4` instead of the correct `2`.

**Chain analysis (line 6322–6324):**
```mlir
// Step 1: papCreate with arity=2, 0 captured → remaining = 2
%1 = "eco.papCreate"() {arity = 2, function = @Pretty_append_$_115, num_captured = 0, ...}

// Step 2: papCreate wrapping %1, arity=3, 1 captured → remaining = 3 - 1 = 2
%3 = "eco.papCreate"(%1) {arity = 3, function = @Basics_Extra_lambda_30379$clo, num_captured = 1, ...}

// Step 3: papExtend adds 1 arg → should be remaining = 2 - 1 = 1, but claims 4
%4 = "eco.papExtend"(%3, %arg0) {remaining_arity = 4}   // <-- ERROR: should be 1
```

| # | Line | Function | Closure lambda |
|---|------|----------|----------------|
| 1 | 6324 | `Pretty_a_$_446` | `Basics_Extra_lambda_30379` |
| 2 | 276421 | `Compiler_Type_Error_nameClashToDoc_$_20876` | `Basics_Extra_lambda_31330` |
| 3 | 328609 | (list bullet formatting) | `Basics_Extra_lambda_31397` |
| 4 | 447796 | `Terminal_Bump` (version prompt) | `Basics_Extra_lambda_31560` |
| 5 | 447845 | `Terminal_Bump_confirmVersionChange_$_30079` | `Basics_Extra_lambda_31561` |
| 6 | 466447 | `Terminal_Diff_writeDiff_$_31442` | `Basics_Extra_lambda_31584` |
| 7 | 560144 | `Terminal_Main_lambda_18849` | `Basics_Extra_lambda_31328` |

### Sub-pattern B: `remaining_arity = 2` but computed = 1 (5 errors)

All involve a `papCreate` with `arity = 3` and `num_captured = 2`, yielding a remaining arity of 1. The subsequent `papExtend` adds 1 argument but claims `remaining_arity = 2` instead of the correct `0` (saturated call).

**Chain analysis (line 301416–301417):**
```mlir
// papCreate: arity=3, 2 captured → remaining = 3 - 2 = 1
%8 = "eco.papCreate"(%1, %2) {arity = 3, function = @List_lambda_31356$clo, num_captured = 2, ...}

// papExtend: adds 1 arg → should be remaining = 1 - 1 = 0, but claims 2
%9 = "eco.papExtend"(%8, %arg0) {remaining_arity = 2}   // <-- ERROR: should be 0
```

| # | Line | Function |
|---|------|----------|
| 1 | 196310 | `Compiler_Type_Solve_patternExpectationToVariable_$_16249` |
| 2 | 196361 | `Compiler_Type_Solve_expectedToVariable_$_16254` |
| 3 | 301417 | `Utils_Main_sequenceListMaybe_$_22401` |
| 4 | 434672 | `Utils_Main_sequenceListMaybe_$_29075` |
| 5 | 477810 | `Compiler_AST_Source_sequenceAC2_$_32143` |
| 6 | 479338 | `Result_Extra_combine_$_32223` |

---

## 3. `eco.papExtend` saturated result type mismatch (2 errors)

**Error message:** `'eco.papExtend' op saturated papExtend result type '!eco.value' does not match function result type 'i64'`

**Root cause:** When a `papExtend` saturates a partial application (fills the last argument), its result type should match the target function's return type. The target function `Maybe_withDefault_$_17582` returns `i64` (for the monomorphized specialization), but the `papExtend` result is typed `!eco.value`.

Both errors are in identical monomorphized copies of `arrayGetOr`:

### Location 1: Line 222757

```mlir
// In function: Compiler_LocalOpt_Erased_Case_arrayGetOr_$_18106
// Signature: (i64, i64, !eco.value) -> (i64)

%6 = "eco.papCreate"() {arity = 2, function = @Maybe_withDefault_$_17582, ...}
%4 = "eco.papExtend"(%6, %default) {newargs_unboxed_bitmap = 1, remaining_arity = 2} : (!eco.value, i64) -> !eco.value
%8 = "eco.papExtend"(%4, %3) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value  // <-- ERROR
//   saturated result should be i64, not !eco.value
%9 = "eco.unbox"(%8) : (!eco.value) -> i64   // tries to unbox, but type is already wrong
```

### Location 2: Line 255381

```mlir
// In function: Compiler_LocalOpt_Typed_Case_arrayGetOr_$_20171
// (identical pattern — different monomorphized copy)
```

---

## 4. `eco.papCreate` unboxed_bitmap mismatch (3 errors)

**Error message:** `'eco.papCreate' op unboxed_bitmap bit N doesn't match operand type: bit is unset but operand type is 'i1'`

**Root cause:** When an `i1` (Bool) operand is captured into a closure via `papCreate`, the `unboxed_bitmap` should have the corresponding bit set (since `i1` is an unboxed scalar). Instead, the bit is unset (0), telling the runtime the operand is a boxed `!eco.value` pointer — but it is actually a bare `i1`.

### Location 1: Line 203125 — bit 0

```mlir
// In function containing List_member check (cycle detection in type-checker)
%4 = "eco.unbox"(%3) : (!eco.value) -> i1     // i1 value
%5 = "arith.constant"() {value = true} : () -> i1
%7 = "eco.papCreate"(%5) {
    _operand_types = [i1],
    arity = 2,
    function = @Terminal_Main_lambda_30632$clo,
    num_captured = 1,
    unboxed_bitmap = 0        // <-- ERROR: bit 0 should be set for i1 operand
} : (i1) -> !eco.value
```

### Location 2: Line 294768 — bit 2

```mlir
// In function processing Elm outlines (Terminal_Main)
%31 = "eco.papCreate"(%root, %8, %10, %7, %15, %5) {
    _operand_types = [!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value],
    arity = 7,
    function = @Terminal_Main_lambda_31337$clo,
    num_captured = 6,
    unboxed_bitmap = 0        // <-- ERROR: bit 2 should be set (operand %10 is i1)
} : (!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value) -> !eco.value
```

### Location 3: Line 528555 — bit 2

```mlir
// In function processing build with kernel package
%36 = "eco.papCreate"(%root, %maybeKernelPackage, %18, %maybeBuildDir, %20, %key) {
    _operand_types = [!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value],
    arity = 7,
    function = @Terminal_Main_lambda_31568$clo,
    num_captured = 6,
    unboxed_bitmap = 0        // <-- ERROR: bit 2 should be set (%18 is i1)
} : (!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value) -> !eco.value
```

### Location 4: Line 533309 — bit 2

```mlir
// Same pattern as Location 3, different monomorphized copy
%36 = "eco.papCreate"(%root, %maybeKernelPackage, %18, %maybeBuildDir, %20, %key) {
    _operand_types = [!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value],
    arity = 7,
    function = @Terminal_Main_lambda_31542$clo,
    num_captured = 6,
    unboxed_bitmap = 0        // <-- ERROR: bit 2 should be set (%18 is i1)
} : (!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value) -> !eco.value
```

**Note:** The `unboxed_bitmap` is a bitmask where bit `i` indicates that captured operand `i` is an unboxed scalar (i64, f64, i16, or i1). The codegen correctly sets bits for `i64` captures (e.g. `unboxed_bitmap = 2` when operand 1 is `i64`) but fails to set bits for `i1` captures. This is related to the Bool-representation invariant: Bool (`i1`) is unboxed in SSA but the bitmap generation doesn't account for it.

---

## 5. `eco.case` yield type mismatch: `i1` vs `!eco.value` (3 errors)

**Error message:** `'eco.case' op alternative N eco.yield operand M has type 'i1' but eco.case result M has type '!eco.value'`

**Root cause:** Inside `scf.while` loop bodies, `eco.case` branches yield `i1` values in positions where the case result type is `!eco.value`. The eco.case result types are determined by the scf.while carry types, which declare `!eco.value` for these positions. But certain branches yield bare `i1` (Bool) values without boxing them first.

### Location 1: Line 60260 — alternative 0, operand 4

```mlir
// In function: Compiler_Elm_Package_chompName_$_5208
// scf.while carry types: (!eco.value, !eco.value, i64, i64, !eco.value, i1, !eco.value)
//                                                          ^operand 4 = !eco.value

%79, %80, %81, %82, %83, %84, %85 = "eco.case"(%40) ({
    // alternative 0 yields:
    "eco.yield"(%23, %24, %42, %26, %43, %44, %45)
    // operand types:  !eco.value, !eco.value, i64, i64, i1,  i1, !eco.value
    //                                                   ^^   ^^
    // operand 4 is i1 (%43 = false), but eco.case result 4 expects !eco.value
}, { ... })
```

The `prevWasDash` Bool is yielded as bare `i1` but the while-loop carry declares it as `!eco.value`. Similar branches at deeper nesting levels within the same function also yield `i1` in the `!eco.value` position.

### Location 2: Line 353167 — alternative 1, operand 3

```mlir
// In function: (Dict_foldl-related, List_filterMap style)
// sym_name not directly on this function, enclosing context is a scf.while body
// scf.while carry types: (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, i1, !eco.value)
//                         0           1           2           3 = !eco.value

// The inner eco.case at line 353169 yields (in the "True" branch):
"eco.yield"(%23, %24, %25, %26, %27, %38, %37)
// all !eco.value — this is fine

// But the OUTER eco.case at 353167, alternative 1 (the Cons branch) eventually yields
// through the inner case, and the result types propagate. The error reports alternative 1
// operand 3 as i1 vs !eco.value.
```

### Location 3: Line 535240 — alternative 1, operand 0

```mlir
// In function: _tail_go_309331 (string escape processing)
// scf.while carry types: (!eco.value, !eco.value, !eco.value, i1, !eco.value)
//                         0=!eco.value

%66, %67, %68, %69, %70 = "eco.case"(%28) ({
    // alternative 0 (from inner eco.case on %30 i1):
    "eco.yield"(%31, %34, %29, %35, %36)
    // types:    i1,  !eco.value, !eco.value, i1, !eco.value
    //           ^^-- operand 0 is i1, but case result 0 expects !eco.value
}, { ... })
```

The pattern is: a Bool flag is carried through a while-loop as `!eco.value` (boxed), but inside case branches the codegen yields the bare `i1` without re-boxing it via `eco.box`.

---

## 6. SSA dominance violation (1 error)

**Error message:** `operand #0 does not dominate this use`

### Location: Line 539701

```mlir
// In function: _tail_firstInlineExpr_275172
// This is inside an scf.while loop body

// The while loop iterates with carries: (!eco.value, i1, !eco.value)
// %3, %4, %5 = "scf.while"(%decider, %1, %2) ({
//     ^bb0(%6, %7, %8): ...condition block...
// }, {
//     ^bb0(%9, %10, %11): ...body block...

// At line 539698 (inside the "else" branch of an eco.case on tag of %11):
%27 = "eco.project.custom"(%11) {field_index = 1} : (!eco.value) -> !eco.value
%28 = "eco.project.custom"(%11) {field_index = 2} : (!eco.value) -> !eco.value
%29 = "eco.papExtend"(%3, %27) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
//                     ^^ %3 is the RESULT of scf.while, defined AFTER the loop body
```

**Analysis:** `%3` is the first result of the `scf.while` operation (defined at line 539674). Inside the while-loop body block, `%3` is not yet defined — the body block's arguments are `%9`, `%10`, `%11` (or similar renumbered SSA values). The codegen incorrectly references the while-loop *result* `%3` instead of the body block *argument* that corresponds to the same carry position.

The correct operand should be the body block argument for carry position 0 (i.e., `%decider`'s evolving value inside the loop), not the post-loop result `%3`.

---

## Summary

| Category | Count | Severity | Likely codegen module |
|----------|-------|----------|----------------------|
| Missing `predicate` on `arith.cmpi` for i16 | 12 | Easy fix | MLIR Expr codegen (Char comparison emission) |
| `papExtend` remaining_arity wrong | 12 | Medium | Closure/PAP arity tracking in codegen |
| `papExtend` saturated result type wrong | 2 | Medium | Monomorphized return type propagation |
| `papCreate` unboxed_bitmap missing i1 bit | 4 | Medium | Closure bitmap computation (Bool not treated as unboxed) |
| `eco.case` yield i1 vs !eco.value | 3 | Medium | While-loop carry type / case yield boxing |
| SSA dominance violation | 1 | Hard | While-loop body SSA variable scoping |
| **Total** | **37** | | |
