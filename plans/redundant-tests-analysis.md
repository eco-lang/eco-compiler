# Redundant Test Case Analysis Report

## Executive Summary

After analyzing all test modules in `StandardTestSuites` (excluding `DeepFuzzTests`), I identified **~150-170 test cases** that are candidates for removal out of approximately **~600 total tests**. This represents a potential **25-28% reduction** in test count without reducing test coverage.

The redundancies fall into several categories:
1. **Trivial Value Variations** - Tests that differ only in literal values (e.g., `intExpr 0` vs `intExpr 42`)
2. **Type Variations** - Same AST structure with different element types
3. **Size Scaling** - Tests that differ only in element count (2-field vs 5-field records)
4. **Duplicate Tests** - Tests with identical AST structures, sometimes with different names
5. **Multi-Module Tests** - Tests that repeat the same pattern across multiple modules
6. **Cross-File Duplicates** - Same patterns tested in different test files

---

## Detailed Analysis by Module

### 1. LiteralTests.elm (31 tests)

**Recommended: Keep 10, Drop 21**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Int 1 | Subsumed by "Positive int" (trivial value difference) |
| Int -1 | Subsumed by "Negative int" (trivial value difference) |
| Large positive int | Same AST as "Positive int" (boundary values don't matter for AST) |
| Large negative int | Same AST as "Negative int" |
| Pi | Same AST as any float literal |
| Large float | Same AST as any float literal |
| Scientific notation positive | Same AST as any float literal |
| Scientific notation negative exponent | Same AST as any float literal |
| Single char string | Same AST as non-empty string |
| Hello world | Same AST as any non-empty string |
| String with quotes | Escape handling is parser concern |
| Long string | Same AST structure, length irrelevant |
| Digit char | Same AST as "Letter char" |
| Symbol char | Same AST as "Letter char" |
| Space char | Same AST as "Letter char" |
| Uppercase char | Same AST as "Letter char" |
| Multiple unit modules | Tests same AST in separate modules |
| Two bools in different modules | Tests same AST in separate modules |
| Int and float in separate modules | Multi-module testing is orthogonal |
| String and char in separate modules | Multi-module testing is orthogonal |
| Int with unit in separate modules | Multi-module testing is orthogonal |
| All literal types | Multi-module testing is orthogonal |

#### Tests to KEEP:
- Zero, Positive int, Negative int (3)
- Zero float, Small positive float, Negative float (3)
- Empty string, String with escapes, Unicode string (3)
- Letter char (1)
- Unit expression (1)
- True, False (2)

---

### 2. TupleTests.elm (24 tests)

**Recommended: Keep 9, Drop 15**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Pair of floats | Same structure as "Pair of ints" |
| Pair of strings | Same structure as "Pair of ints" |
| Pair with unit | Same structure as "Pair of ints" |
| Pair of bools | Same structure as "Pair of ints" |
| Pair of chars | Same structure as "Pair of ints" |
| Triple with bools | Same structure as "Triple of ints" |
| Triple of strings | Same structure as "Triple of ints" |
| Triple of floats | Same structure as "Triple of ints" |
| Triple with units | Same structure as "Triple of ints" |
| Tuple containing nested tuples | Subsumed by "Deeply nested tuple" |
| 3-tuple containing 2-tuples | Similar to "2-tuple containing 3-tuples" |
| Triple nested three levels deep | Same concept as "Deeply nested tuple" |
| Int and String pair | Subsumed by "Triple of mixed types" |
| Tuple with char | Same structure as "Int and String pair" |
| Triple of int, string, float | Duplicate of "Triple of mixed types" |

---

### 3. RecordTests.elm (33 tests)

**Recommended: Keep 17, Drop 16**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Two empty records | Multi-module testing |
| Record with string field | Same structure as "Record with int field" |
| Record with float field | Same structure as "Record with int field" |
| Record with bool field | Same structure as "Record with int field" |
| Three-field record | Between two-field and five-field |
| Record with two int fields | Same as "Two-field record" |
| Record with ten fields | Scaling test, same structure |
| Record with list field (nested) | Duplicate of single-field version |
| Record with tuple field (nested) | Duplicate of single-field version |
| Multiple levels of nesting | Similar to "Deeply nested record" |
| Access from multi-field record | Same AST as "Access single field" |
| Multiple accesses | Just two "Access single field" in tuple |
| Different accessor function | Same structure as "Accessor function" |
| Accessor in list | Tests list composition, not accessor |
| Update with value | Identical to "Update single field" |
| Update all fields | Same structure as "Update multiple fields" |

---

### 4. ListTests.elm (27 tests)

**Recommended: Keep 12, Drop 15**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Two empty lists in separate modules | Multi-module testing |
| Empty int list | Same as "Empty list" |
| Empty string list | Same as "Empty list" |
| Single string list | Same structure as "Single int list" |
| Single float list | Same structure as "Single int list" |
| Single char list | Same structure as "Single int list" |
| Two-element int list | Same pattern as 3-element |
| Five-element int list | Same pattern, different count |
| Two-element string list | Same structure as int version |
| Three-element float list | Same structure as int version |
| Ten-element int list | Same pattern, different count |
| Large int list | Same pattern, different count |
| List of string tuples | Same structure as "List of int tuples" |
| List with nested lists different types | Duplicate of "List of lists" |

---

### 5. FunctionTests.elm (43 tests)

**Recommended: Keep 24, Drop 19**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Const lambda | Same structure as "Identity lambda" |
| Three-argument lambda | Same pattern as "Two-argument lambda" |
| Lambda returning record | Tests composition, not lambda |
| Lambda returning list | Tests composition, not lambda |
| Call with three args | Same structure as "Call with two args" |
| Call with complex args | Tests argument types, not call structure |
| Partially applied three-arg function | Same pattern as two-arg |
| Partial application with complex arg | Tests argument type |
| Triple nested lambda | Extension of "Lambda returning lambda" |
| Lambda in list | Tests composition |
| Lambda in record | Tests composition |
| Function returning function | Subsumed by "Lambda returning lambda" |
| Negate float | Same AST structure as "Negate int" |
| Abs negative int | Same structure as "Abs positive int" |
| Abs zero int | Same structure as "Abs positive int" |
| Abs positive float | Same structure as "Abs positive int" |
| Abs negative float | Same structure as "Abs positive int" |
| Abs zero float | Same structure as "Abs positive int" |
| zabs with zero Float | Same as "zabs with Float" |

---

### 6. LetTests.elm (28 tests)

**Recommended: Keep 16, Drop 12**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Let with int binding | Exact duplicate of "Let with single int binding" |
| Let with string binding | Same structure as int binding |
| Let with tuple body | Tests result type, not let structure |
| Let with list body | Tests result type, not let structure |
| Let with three bindings | Same pattern as two bindings |
| Let with two int bindings | Duplicate of "Let with two bindings" |
| Let with five bindings | Same pattern, different count |
| Deeply nested let | Extension of "Let inside let" |
| Nested let with int value | Same as "Let in binding value" |
| Let with two-arg function | Same pattern as single-arg |
| Let with function using int value | Same as basic "Let with function" |
| Let with all complex types | Combination of others |

---

### 7. LetRecTests.elm (21 tests)

**Recommended: Keep 10, Drop 11**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Recursive function returning tuple | Same recursion pattern |
| Recursive function with fixed base case | Same as "Simple recursive function" |
| Recursive function with lambda body | Same structure |
| Three mutually recursive functions | Extension of two-way |
| Mutually recursive with fixed value | Same as two-way |
| Mutually recursive returning tuples | Same pattern |
| Recursive function in list | Tests result container |
| Recursive function in record | Tests result container |

---

### 8. LetDestructTests.elm (29 tests)

**Recommended: Keep 21, Drop 8**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Destruct tuple with values | Same as "Destruct 2-tuple" |
| Destruct 3-tuple with values | Same as "Destruct 3-tuple" |
| Destruct record with values | Same as "Destruct multi-field record" |
| Destruct record many fields | Same pattern as multi-field |
| Destruct list with values | Same as "Destruct cons pattern" |
| Destruct record with nested tuple | Actually tests record access |
| Nested destruct with values | Same as "Destruct tuple of tuples" |
| Alias destruct with value | Same as "Destruct with simple alias" |

---

### 9. CaseTests.elm (32 tests)

**Recommended: Keep 29, Drop 3**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Case on tuple | Identical to "Case on tuple with var patterns" |
| Case on record | Identical to "Case on single-field record pattern" |
| Case with alias pattern | Identical to "Case with simple alias pattern" |

---

### 10. BinopTests.elm (48 tests)

**Recommended: Keep 38, Drop 10**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Addition with constants | Identical to "Simple addition" |
| Comparison with constants | Identical to "Less than" |
| And with constants | Identical to "And" |
| Or with constants | Identical to "Or" |
| String concat with constants | Nearly identical to "String concat" |
| List append with constants | Nearly identical to "List append" |
| Chain with constants | Identical to "Three-element addition chain" |
| Chain of comparisons | Misleading name; same as "Less than" |
| Binop with lambda | Does NOT test binops; tests tuples with lambdas |

---

### 11. OperatorTests.elm (20 tests)

**Recommended: Keep 16, Drop 4**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| If with bool condition | Identical to "Simple if" |
| If with fixed values | Identical to "If with int branches" |
| Negate int value | Identical to "Negate int" |
| Negate float value | Identical to "Negate float" |

---

### 12. HigherOrderTests.elm (29 tests)

**Recommended: Keep 28, Drop 1**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Manual compose | Subset of "Compose two functions" (just returns the compose var) |

---

### 13. AsPatternTests.elm (24 tests)

**Recommended: Keep 20, Drop 4**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Alias on single-field record | Very similar to "Alias on record pattern" |
| Alias in case branch | Very similar to "Alias with value" |
| Alias pattern with tuple values | Overlaps with "Alias on 2-tuple" |

---

### 14. AnnotatedTests.elm (18 tests)

**Recommended: Keep 14, Drop 4**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Make pair | Identical to "Pair function" |
| Duplicate | Identical to "Wrap in tuple" |
| Apply function | Subset of "Apply with usage" |
| Compose | Subset of "Compose with usage" |

---

### 15. DecisionTreeAdvancedTests.elm (50 tests)

**Recommended: Keep 44, Drop 6**

#### Tests to DROP (cross-file duplicates with PatternMatchingTests):

| Test | Reason |
|------|--------|
| Tuple2 pattern | Identical to PatternMatchingTests.simpleTuplePatternTest |
| Nested tuple pattern | Identical to PatternMatchingTests.nestedTuplePatternTest |
| Empty list pattern | Identical to PatternMatchingTests.emptyListPatternTest |
| Cons pattern | Identical to PatternMatchingTests.headTailPatternTest |
| Char literal pattern | Similar to PatternMatchingTests.vowelDetectionTest |
| String literal pattern | Similar to PatternMatchingTests.simpleStringPatternTest |

---

### 16. EdgeCaseTests.elm (23 tests)

**Recommended: Keep 21, Drop 2**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| Record access in binop | Duplicate of BinopTests "Binop with record access" |
| Lambda with no body complexity | Identical pattern in many other tests |

---

### 17. PatternArgTests.elm (44 tests)

**Recommended: Keep 42, Drop 2**

#### Tests to DROP:

| Test | Reason |
|------|--------|
| All wildcards | Very similar to "Multiple wildcards" (4 vs 3 wildcards) |
| Multiple functions with variable patterns | Tests two identity-like functions |

---

### Other Modules (No Changes Recommended)

The following modules have no redundant tests:
- ArrayTest.elm (6 tests)
- BitwiseTests.elm (16 tests)
- ClosureTests.elm (22 tests)
- ControlFlowTests.elm (18 tests)
- FloatMathTests.elm (26 tests)
- MultiDefTests.elm (17 tests)
- PatternMatchingTests.elm (22 tests)
- PortEncodingTests.elm (32 tests)
- SpecializeAccessorTests.elm (9 tests)
- SpecializeConstructorTests.elm (10 tests)
- SpecializeCycleTests.elm (9 tests)
- SpecializeExprTests.elm (11 tests)
- PostSolveExprTests.elm (53 tests)

---

## Summary Statistics

| Module | Total | Keep | Drop | Reduction |
|--------|-------|------|------|-----------|
| LiteralTests | 31 | 10 | 21 | 68% |
| TupleTests | 24 | 9 | 15 | 63% |
| RecordTests | 33 | 17 | 16 | 48% |
| ListTests | 27 | 12 | 15 | 56% |
| FunctionTests | 43 | 24 | 19 | 44% |
| LetTests | 28 | 16 | 12 | 43% |
| LetRecTests | 21 | 10 | 11 | 52% |
| LetDestructTests | 29 | 21 | 8 | 28% |
| CaseTests | 32 | 29 | 3 | 9% |
| BinopTests | 48 | 38 | 10 | 21% |
| OperatorTests | 20 | 16 | 4 | 20% |
| HigherOrderTests | 29 | 28 | 1 | 3% |
| AsPatternTests | 24 | 20 | 4 | 17% |
| AnnotatedTests | 18 | 14 | 4 | 22% |
| DecisionTreeAdvancedTests | 50 | 44 | 6 | 12% |
| EdgeCaseTests | 23 | 21 | 2 | 9% |
| PatternArgTests | 44 | 42 | 2 | 5% |
| **SUBTOTAL (Modified)** | **524** | **371** | **153** | **29%** |

---

## Key Redundancy Patterns Identified

### Pattern 1: Trivial Value Variations
Many tests differ only in literal values when the compiler treats all values of that type identically.

**Example:**
```elm
-- These test identical AST structures:
intExpr 0       -- "Zero"
intExpr 42      -- "Positive int"
intExpr 1       -- "Int 1"
intExpr 2147483647  -- "Large positive int"
```

### Pattern 2: Type Element Variations
Tests that create the same structure but with different element types.

**Example:**
```elm
-- These test identical tupleExpr structures:
tupleExpr (intExpr 1) (intExpr 2)       -- "Pair of ints"
tupleExpr (floatExpr 1.5) (floatExpr 2.5)  -- "Pair of floats"
tupleExpr (strExpr "a") (strExpr "b")   -- "Pair of strings"
```

### Pattern 3: Count Scaling
Tests that differ only in the number of elements.

**Example:**
```elm
-- These test the same pattern at different scales:
recordExpr [("x", ...), ("y", ...)]        -- "Two-field record"
recordExpr [("a", ...), ("b", ...), ("c", ...)]  -- "Three-field record"
recordExpr [5 fields]                      -- "Five-field record"
recordExpr [10 fields]                     -- "Ten-field record"
```

### Pattern 4: Multi-Module Tests
Tests that run the same pattern in separate modules don't test AST structure.

**Example:**
```elm
-- These don't add AST coverage:
"Two bools in different modules"
"Int and float in separate modules"
"All literal types" (6 separate modules)
```

### Pattern 5: Exact Duplicates
Some tests are literally the same with different names.

**Example:**
```elm
-- Identical:
"Let with single int binding"
"Let with int binding"
```

---

## Recommendations

### Immediate Actions (High Confidence)
1. Remove exact duplicates (e.g., "Let with int binding")
2. Remove trivial value variations in LiteralTests
3. Remove type element variations in TupleTests, ListTests
4. Remove "with constants" duplicates in BinopTests
5. Remove multi-module tests in LiteralTests

### Consider for Removal (Medium Confidence)
1. Size scaling tests (keep smallest + one medium size)
2. Cross-file duplicates between DecisionTreeAdvancedTests and PatternMatchingTests

### Keep (Distinct Value)
1. Tests with different AST node types (lambdaExpr vs callExpr)
2. Tests with different pattern structures (pVar vs pTuple vs pRecord)
3. Tests that exercise specific compiler code paths (DeepFuzzTests, SpecializeTests)

---

## Implementation Notes

When implementing these removals:

1. **Remove test cases** from the `*Cases` functions
2. **Keep the helper functions** if they might be useful for debugging
3. **Run full test suite** after each batch of removals to verify
4. **Consider commenting** rather than deleting initially for easy rollback
