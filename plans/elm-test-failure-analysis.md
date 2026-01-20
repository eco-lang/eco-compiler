# Elm Compiler Test Failure Analysis Report

## Summary

**Total test files:** 58
**Passing files:** 52
**Failing files:** 6
**Total failures:** 62

All failures are in the **CodeGen phase** (MLIR generation).

---

## Failure Categories (Ordered by Compiler Phase)

All failures occur in the final CodeGen phase. Within CodeGen, the issues can be ordered by when they manifest in the generated MLIR:

### Category 1: Case Scrutinee Type Mismatch (19 failures)
**Test File:** `CaseKindScrutineeTest.elm`
**Compiler Phase:** CodeGen → Case expression generation
**Priority:** HIGH (most impactful)

**Error Pattern:**
```
case_kind='int' requires i64 scrutinee, got eco.value
case_kind='chr' requires i16 (ECO char) scrutinee, got eco.value
```

**Failing Tests:**
- Case with three branches
- Case on int literals
- Case with many int branches
- Case with negative int patterns
- Multiple int patterns
- Char literal pattern
- Multiple char patterns
- Multiple fallbacks
- Redundant wildcard
- Simple char pattern
- Char pattern with fallback
- Vowel detection
- Digit char pattern
- Variable capture fallback
- Multiple specific then fallback
- Simple case type
- Multi-branch case type
- Int literal patterns

**Root Cause Analysis:**

When generating `eco.case` for pattern matching on primitive types (Int, Char), the scrutinee expression is correctly computed with primitive type (i64, i16), but the `_operand_types` attribute declares `eco.value`. This indicates:

1. The scrutinee IS correctly unboxed to primitive type
2. But `_operand_types` attribute is NOT updated to match
3. The code path is in `generateCase` or related functions in `Expr.elm`

**Location:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` → `generateCase` and `generateDecider`

---

### Category 2: Operand Type Consistency (25 failures)
**Test File:** `OperandTypeConsistencyTest.elm`
**Compiler Phase:** CodeGen → Various operations
**Priority:** HIGH

**Error Patterns (Two distinct issues):**

**Pattern A: eco.case scrutinee (15 failures)**
```
eco.case: _operand_types declares eco.value but SSA type is i64/i16
```
Same root cause as Category 1 - scrutinee is primitive but `_operand_types` says `eco.value`.

**Pattern B: eco.return/eco.papExtend extracted value (10 failures)**
```
eco.return: _operand_types declares i64 but SSA type is eco.value
eco.papExtend: _operand_types declares eco.value but SSA type is i64
```
These are the OPPOSITE direction - the extracted value from a constructor payload is `eco.value` but code expects primitive.

**Failing Tests (Pattern A - scrutinee):**
- Case with three branches
- Case on int/char literals
- Multiple int/char patterns
- Redundant wildcard
- Variable capture fallback
- Multiple specific then fallback
- Simple/Multi-branch case type
- Int literal patterns
- Call with no args (papExtend)

**Failing Tests (Pattern B - extraction):**
- Case on custom type with payload extraction
- Constructor with one arg
- Nested constructor
- Custom type pattern with multiple extractors
- Double nested pattern
- Single-field wrapper type

**Root Cause Analysis (Pattern B):**

When extracting a field from a custom type constructor that has a primitive type, the extraction returns `eco.value` (boxed) but the code assumes it will be the primitive type. This could be in:
- `eco.project.custom` result type
- Pattern match variable binding type

**Location:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm` → field extraction

---

### Category 3: Block Terminator (7 failures)
**Test File:** `BlockTerminatorTest.elm`
**Compiler Phase:** CodeGen → Nested case generation
**Priority:** MEDIUM

**Error Pattern:**
```
region N entry block terminator 'eco.case' is not a valid terminator
```

**Failing Tests:**
- Case on tuple with literal patterns
- List pattern with fallback
- Tuple with literals
- Deeply nested constructor
- Multiple fallbacks
- Overlapping patterns
- Case with nested patterns type

**Root Cause Analysis:**

When generating nested case expressions (case inside case branch), the inner `eco.case` appears as a block terminator instead of a proper terminator (`eco.return`, `eco.jump`, `eco.crash`). This indicates:

1. The inner case is not being wrapped properly
2. Each case branch should end with a terminator, but nested cases don't

The MLIR structure requires each block to end with a terminator operation. When a case branch contains another case, the block terminator is `eco.case` which is not valid.

**Location:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` → `generateDecider` nested case handling

---

### Category 4: Case Termination (7 failures)
**Test File:** `CaseTerminationTest.elm`
**Compiler Phase:** CodeGen → Case branch generation
**Priority:** MEDIUM (same root cause as Category 3)

**Error Pattern:**
```
Branch 1 entry terminates with 'eco.case', expected eco.return, eco.jump, or eco.crash
```

**Root Cause Analysis:**

Same underlying issue as Category 3 - nested case expressions create blocks that terminate with `eco.case` instead of proper terminators.

**Location:** Same as Category 3

---

### Category 5: Jump Target Missing (2 failures)
**Test File:** `JumpTargetTest.elm`
**Compiler Phase:** CodeGen → Tail recursion
**Priority:** LOW (only affects tail recursion)

**Error Pattern:**
```
eco.jump missing target attribute
```

**Failing Tests:**
- Tail recursive sum
- Tail recursive with accumulator

**Root Cause Analysis:**

When generating tail-recursive functions, `eco.jump` operations are missing their `target` attribute. The jump should reference a joinpoint (block label) for the loop continuation.

This suggests the tail call generation is:
1. Creating the `eco.jump` op
2. NOT attaching the `target` attribute that specifies where to jump

**Location:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` → `generateTailCall` or joinpoint generation

---

### Category 6: Call Target Validity (2 failures)
**Test File:** `CallTargetValidityTest.elm`
**Compiler Phase:** CodeGen → Tail recursion
**Priority:** LOW (only affects tail recursion)

**Error Pattern:**
```
eco.call targets stub 'Test_X_$_1' but non-stub 'Test_X_$_2' exists
```

**Failing Tests:**
- Tail recursive sum (sumHelper)
- Tail recursive with accumulator (countdownHelper)

**Root Cause Analysis:**

For tail-recursive functions, two function variants may be created:
- A "stub" version (SpecId 1) - the original entry point
- A "real" version (SpecId 2) - the actual loop

When code calls the function, it's targeting the stub instead of the real implementation. This is likely a specialization ID mismatch in tail-call optimization.

**Location:** `compiler/src/Compiler/Generate/MLIR/Functions.elm` → tail function generation, or specialization registry handling

---

## Root Cause Summary

| Category | Failures | Root Cause | Fix Location |
|----------|----------|------------|--------------|
| Case Scrutinee Type | 19 | `_operand_types` not updated for primitive scrutinee | Expr.elm:generateCase |
| Operand Type (scrutinee) | 15 | Same as above | Expr.elm:generateCase |
| Operand Type (extraction) | 10 | Custom type field extraction type mismatch | Patterns.elm |
| Block Terminator | 7 | Nested case not properly wrapped | Expr.elm:generateDecider |
| Case Termination | 7 | Same as Block Terminator | Expr.elm:generateDecider |
| Jump Target Missing | 2 | `eco.jump` missing target attribute | Expr.elm:generateTailCall |
| Call Target Validity | 2 | Tail-recursive stub/real function mismatch | Functions.elm |

## Recommended Fix Order

1. **Case Scrutinee Type / Operand Type (scrutinee)** - 34 failures
   - Single fix will resolve both CaseKindScrutineeTest and most OperandTypeConsistencyTest failures
   - High impact

2. **Block Terminator / Case Termination** - 14 failures (7 + 7)
   - Same root cause, single fix
   - Medium impact

3. **Operand Type (extraction)** - 10 failures
   - Separate issue from scrutinee
   - Medium impact

4. **Jump Target / Call Target** - 4 failures (2 + 2)
   - Related to tail recursion
   - Low priority (limited scope)

## Passing Test Files (52)

All earlier compiler phases pass completely:
- **Canonicalize:** 6 test files, all passing
- **Type Checking:** 8 test files, all passing
- **Optimization:** 5 test files, all passing
- **Monomorphization:** 6 test files, all passing
- **CodeGen (other invariants):** 27 test files, all passing
