# Elm Compiler Test Failure Analysis Report (v2)

## Summary

**Elm compiler tests:**
- Total test files: 65+
- Passing: 61+ test files
- Failing: 4 test files
- Total failures: 48

**Eco end-to-end tests:**
- Total: 136 tests
- Passing: 96
- Failing: 40

All failures are in the **CodeGen phase** (MLIR generation).

---

## Elm Compiler Test Failures by Category

### Category 1: Case Scrutinee Type Mismatch (19 failures)
**Test File:** `CaseKindScrutineeTest.elm`

**Error Pattern:**
```
case_kind='int' requires i64 scrutinee, got eco.value
case_kind='chr' requires i16 (ECO char) scrutinee, got eco.value
```

**Root Cause:**
In `generateFanOutGeneral` (Expr.elm:2154-2225), when generating case expressions for Int/Char literal patterns:

1. `caseKind` is correctly set to `"int"` or `"chr"` based on `DT.IsInt`/`DT.IsChr` tests
2. BUT `generateDTPath` is called with `Types.ecoValue` (line 2160)
3. AND `Ops.ecoCase` is called with `Types.ecoValue` as scrutinee type (line 2216)

The code assumes all cases use boxed scrutinees, but `case_kind='int'` and `case_kind='chr'` require primitive scrutinees (i64, i16 respectively).

**Location:** `Expr.elm:2154-2225` - `generateFanOutGeneral`

---

### Category 2: Operand Type Consistency - Scrutinee (15 failures)
**Test File:** `OperandTypeConsistencyTest.elm`

**Error Pattern:**
```
eco.case (opN): operand 0 ('%X'): _operand_types declares eco.value but SSA type is i64/i16
```

**Root Cause:**
Same underlying issue as Category 1, seen from a different angle:
- The scrutinee variable HAS been unboxed to i64/i16 (by `generateDTPath`)
- But `_operand_types` still declares `eco.value`

When `generateDTPath` is called with `Types.ecoValue` but the root variable is already unboxed (e.g., from a function parameter), the function returns the already-unboxed variable. But `ecoCase` still uses `Types.ecoValue` for `_operand_types`.

---

### Category 3: Operand Type Consistency - Extraction (10 failures)
**Test File:** `OperandTypeConsistencyTest.elm`

**Error Pattern:**
```
eco.return (opN): operand 0 ('%X'): _operand_types declares i64 but SSA type is eco.value
eco.papExtend (opN): operand 0 ('%X'): _operand_types declares eco.value but SSA type is i64
```

**Root Cause:**
When extracting values from custom types (e.g., `unbox (Box x) = x`):

1. `generateDestruct` (Expr.elm:1805-1842) extracts a field with target type `i64` (for Int)
2. `generateMonoPath` calls `Ops.ecoProjectCustom` with `targetType = i64`
3. The projection op declares result type as `i64`
4. BUT the actual heap extraction returns `eco.value` (boxed)
5. When the value is returned, `_operand_types` uses the declared `i64` but SSA type is `eco.value`

The issue: Heap projections always return boxed values (`eco.value`), but the code declares them with their semantic type (e.g., `i64`). This creates a mismatch when the value is used.

**Location:**
- `Expr.elm:1805-1842` - `generateDestruct`
- `Patterns.elm:33-112` - `generateMonoPath`

---

### Category 4: Jump Target Missing (2 failures)
**Test File:** `JumpTargetTest.elm`

**Error Pattern:**
```
eco.jump missing target attribute
```

**Root Cause:**
Tail-recursive function optimization generates `eco.jump` operations without the required `target` attribute. The jump should reference a joinpoint label.

**Location:** `Expr.elm` - tail call generation

---

### Category 5: Call Target Validity (2 failures)
**Test File:** `CallTargetValidityTest.elm`

**Error Pattern:**
```
eco.call targets stub 'Test_X_$_1' but non-stub 'Test_X_$_2' exists
```

**Root Cause:**
For tail-recursive functions, specialization creates:
- Stub version (SpecId 1) - original entry point
- Real version (SpecId 2) - the actual loop

Calls incorrectly target the stub instead of the real implementation.

**Location:** `Functions.elm` - tail function specialization

---

## Eco End-to-End Test Failures by Category

### Category A: Type Mismatch Errors (20+ failures)
**Pattern:**
```
error: use of value '%X' expects different type than prior uses: 'i64' vs '!eco.value'
error: use of value '%X' expects different type than prior uses: '!eco.value' vs 'i64'
```

**Affected Tests:**
- CaseIntTest, MaybeAndThenTest, MaybeMapTest, MaybeWithDefaultTest
- PartialApplicationTest, PipelineTest, RecursiveListLengthTest
- ResultAndThenTest, ResultMapTest, ResultWithDefaultTest
- TupleMapFirstTest, TupleMapSecondTest, ListTakeDropTest

**Root Cause:**
Same as Categories 2-3 above. The generated MLIR declares mismatched types for the same SSA variable in different contexts.

---

### Category B: Segmentation Faults (5 failures)
**Pattern:** `SIGSEGV (Segmentation fault)`

**Affected Tests:**
- CaseNestedTest, PartialAppChainTest, MaybePatternMatchTest
- StringLengthTest, RecordAccessorFunctionTest

**Root Cause:**
Likely caused by type mismatches leading to incorrect memory access. When a value is treated as a primitive (`i64`) but is actually a boxed pointer (`eco.value`), dereferencing it causes a crash.

---

### Category C: Incorrect Output (5+ failures)
**Pattern:** Functions return 0 or empty results

**Affected Tests:**
- ListFoldlTest, ListLengthTest, ListReverseTest
- TailRecursiveSumTest, RecordUpdateTest

**Root Cause:**
Related to tail recursion issues (Categories 4-5) or possibly type mismatches affecting computation.

---

## Root Cause Analysis Summary

### Primary Issue: Type Declaration vs Runtime Type Mismatch

The core problem is that the MLIR generator declares types based on **semantic/Elm types** but the **runtime representation** differs:

| Semantic Type | Declared MLIR Type | Actual Runtime Type |
|---------------|-------------------|---------------------|
| Int (in case scrutinee) | eco.value | i64 (after unbox) |
| Int (from heap extraction) | i64 | eco.value (boxed) |
| Char (in case scrutinee) | eco.value | i16 (after unbox) |
| Any custom type field | varies | eco.value (boxed) |

### The Two-Way Mismatch

1. **Case scrutinee (Categories 1-2):**
   - Declared: `eco.value`
   - Actual: `i64`/`i16` (primitives)
   - Fix: Use correct primitive type based on `case_kind`

2. **Heap extraction (Category 3):**
   - Declared: `i64` (or other primitive)
   - Actual: `eco.value` (boxed)
   - Fix: Either unbox after extraction OR declare as `eco.value` and unbox at use

---

## Recommended Fix Order

1. **Case Scrutinee Type (34 failures)** - Categories 1-2
   - Single fix in `generateFanOutGeneral`
   - Determine scrutinee type from `case_kind`
   - Pass correct type to both `generateDTPath` and `ecoCase`

2. **Heap Extraction Type (10 failures)** - Category 3
   - Fix in `generateDestruct`/`generateMonoPath`
   - Either add unbox ops after projection, OR
   - Declare result as `eco.value` and unbox at use sites

3. **Tail Recursion (4 failures)** - Categories 4-5
   - Fix jump target attribute
   - Fix stub/real function targeting

---

## Key Code Locations

| Issue | File | Function | Lines |
|-------|------|----------|-------|
| Case scrutinee type | Expr.elm | generateFanOutGeneral | 2154-2225 |
| Heap extraction type | Expr.elm | generateDestruct | 1805-1842 |
| Heap extraction type | Patterns.elm | generateMonoPath | 33-112 |
| Jump target | Expr.elm | (tail call gen) | TBD |
| Call target | Functions.elm | (specialization) | TBD |
