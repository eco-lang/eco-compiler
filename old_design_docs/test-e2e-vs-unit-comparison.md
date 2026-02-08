# Test Suite Comparison: StandardTestSuites vs E2E Tests

## Executive Summary

This document compares two test suites in the eco-runtime project:

1. **StandardTestSuites** (`compiler/tests/Compiler/`) - Unit tests for the compiler's AST canonicalization and transformation phases. These tests construct Source AST nodes using `SourceBuilder` helpers and verify they pass through compiler phases correctly.

2. **E2E Tests** (`test/elm/src/`) - End-to-end tests that compile and execute actual Elm code, verifying runtime behavior using `Debug.log` output matched against `-- CHECK:` comments.

---

## Section 1: Patterns Tested by BOTH Suites

### 1.1 Literals
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Integer literals | `intExpr 42` in LiteralTests | `IntegerTests.elm`, `IntBasics.elm` |
| Float literals | `floatExpr 3.14` in LiteralTests | `FloatTests.elm`, `FloatBasics.elm` |
| String literals | `strExpr "hello"` in LiteralTests | `StringTests.elm`, `StringBasics.elm` |
| Char literals | `charExpr 'a'` in LiteralTests | `CharTests.elm`, `CharBasics.elm` |
| Bool literals | `boolExpr True` in LiteralTests | `BoolTests.elm` |

### 1.2 Arithmetic Operators
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Addition (+) | BinopTests, OperatorTests | `IntegerTests.elm`, `FloatTests.elm` |
| Subtraction (-) | BinopTests, OperatorTests | `IntegerTests.elm`, `FloatTests.elm` |
| Multiplication (*) | BinopTests, OperatorTests | `IntegerTests.elm`, `FloatTests.elm` |
| Division (/) | BinopTests | `FloatTests.elm` |
| Integer division (//) | BinopTests | `IntegerTests.elm` |
| Modulo (modBy) | BinopTests | `IntegerTests.elm` |
| Negation | OperatorTests (`negateExpr`) | `IntegerTests.elm`, `FloatTests.elm` |

### 1.3 Comparison Operators
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Equality (==) | BinopTests | Various comparison tests |
| Inequality (/=) | BinopTests | Various comparison tests |
| Less than (<) | BinopTests | `CompareTests.elm` |
| Greater than (>) | BinopTests | `CompareTests.elm` |
| Less/equal (<=) | BinopTests | `CompareTests.elm` |
| Greater/equal (>=) | BinopTests | `CompareTests.elm` |

### 1.4 Logical Operators
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| And (&&) | BinopTests | `BoolTests.elm` |
| Or (\|\|) | BinopTests | `BoolTests.elm` |
| Not | OperatorTests (`notExpr`) | `BoolTests.elm` |

### 1.5 Data Structures

#### Tuples
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| 2-tuples | TupleTests (`tupleExpr`) | `TupleTests.elm` |
| 3-tuples | TupleTests (`tuple3Expr`) | `TupleTests.elm` |
| Tuple.first | TupleTests | `TupleTests.elm` |
| Tuple.second | TupleTests | `TupleTests.elm` |
| Nested tuples | TupleTests | `TupleTests.elm` |

#### Lists
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Empty list | ListTests (`listExpr []`) | `ListTests.elm` |
| List literals | ListTests | `ListTests.elm`, `ListBasics.elm` |
| Cons (::) | ListTests, BinopTests | `ListTests.elm` |
| List.map | HigherOrderTests | `ListTests.elm` |
| List.filter | HigherOrderTests | `ListTests.elm` |
| List.foldl/foldr | HigherOrderTests | `ListTests.elm` |
| List.head/tail | ListTests | `ListTests.elm` |
| List.length | ListTests | `ListTests.elm` |
| List.reverse | ListTests | `ListTests.elm` |
| List.append (++) | BinopTests | `ListTests.elm` |

#### Records
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Record creation | RecordTests (`recordExpr`) | `RecordTests.elm` |
| Field access | RecordTests (`accessExpr`) | `RecordTests.elm` |
| Field accessor functions | RecordTests (`accessorExpr .field`) | `RecordTests.elm` |
| Record update | RecordTests (`updateExpr`) | `RecordTests.elm` |
| Empty record | EdgeCaseTests | `RecordTests.elm` |
| Multi-field records | RecordTests | `RecordTests.elm` |

### 1.6 Functions

| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Named functions | FunctionTests (`define`) | Multiple files |
| Anonymous functions (lambdas) | FunctionTests (`lambdaExpr`) | `LambdaTests.elm`, `ClosureTests.elm` |
| Function application | FunctionTests (`callExpr`) | Multiple files |
| Multi-argument functions | FunctionTests | Multiple files |
| Currying/partial application | FunctionTests, HigherOrderTests | `CurryTests.elm` |
| Higher-order functions | HigherOrderTests | `HigherOrderTests.elm` |

### 1.7 Pattern Matching

#### Case Expressions
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Case on literals | CaseTests | `PatternMatchTests.elm` |
| Case on tuples | CaseTests (`pTuple`) | `PatternMatchTests.elm` |
| Case on lists | CaseTests (`pCons`, `pList`) | `PatternMatchTests.elm` |
| Case on records | CaseTests (`pRecord`) | `PatternMatchTests.elm` |
| Case on custom types | CaseTests (`pCtor`) | `PatternMatchTests.elm`, `CustomTypeTests.elm` |
| Wildcard pattern | CaseTests (`pAnything`) | `PatternMatchTests.elm` |
| As-patterns | AsPatternTests (`pAlias`) | `PatternMatchTests.elm` |
| Nested patterns | CaseTests, DecisionTreeAdvancedTests | `PatternMatchTests.elm` |
| Multiple branches | CaseTests | `PatternMatchTests.elm` |

#### Function Argument Patterns
| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Variable patterns | PatternArgTests (`pVar`) | Multiple files |
| Tuple destructuring | PatternArgTests | `TupleTests.elm` |
| Record destructuring | PatternArgTests | `RecordTests.elm` |
| List destructuring | PatternArgTests | `ListTests.elm` |

### 1.8 Control Flow

| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| If-then-else | OperatorTests (`ifExpr`) | `ControlFlowTests.elm`, `IfTests.elm` |
| Nested if | OperatorTests | `ControlFlowTests.elm` |

### 1.9 Let Expressions

| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Simple let | LetTests (`letExpr`, `define`) | `LetTests.elm` |
| Multiple definitions | LetTests | `LetTests.elm` |
| Nested let | LetTests | `LetTests.elm` |
| Let with destructuring | LetDestructTests (`destruct`) | `LetTests.elm` |
| Recursive let (letrec) | LetRecTests | `RecursionTests.elm` |
| Mutually recursive | LetRecTests | `MutualRecursionTests.elm` |

### 1.10 Custom Types

| Pattern | StandardTestSuites | E2E Tests |
|---------|-------------------|-----------|
| Constructors with no args | CaseTests (`ctorExpr "Nothing" []`) | `MaybeTests.elm`, `CustomTypeTests.elm` |
| Constructors with args | CaseTests (`ctorExpr "Just" [...]`) | `MaybeTests.elm`, `CustomTypeTests.elm` |
| Pattern matching on custom types | CaseTests, DecisionTreeAdvancedTests | `CustomTypeTests.elm` |
| Maybe type | CaseTests | `MaybeTests.elm` |
| Result type | (via custom type patterns) | `ResultTests.elm` |

---

## Section 2: Patterns Tested ONLY in StandardTestSuites

These patterns are tested at the compiler transformation level but not verified for runtime execution:

### 2.1 Type Annotations
- **AnnotatedTests.elm** - Tests type annotations on values and functions
  - `typeVar "a"`, `typeFunction`, `typeRecord`
  - Polymorphic type annotations
  - Higher-order function annotations
  - Constrained type variables

### 2.2 Closure-Specific Tests
- **ClosureTests.elm** - Tests closure creation patterns
  - Closures capturing multiple variables
  - Closures with nested scopes
  - Closures in recursive contexts

### 2.3 Compiler-Specific Constructs
- **PortTests.elm** - Port declarations (JavaScript interop)
- **SpecializationTests.elm** - Type specialization during compilation
- **PostSolveTests.elm** - Post-solving type constraint resolution
- **DeepFuzzTests.elm** - Fuzz testing of compiler transformations

### 2.4 AST Structure Tests
- **EdgeCaseTests.elm** - Edge cases in AST construction
  - Empty records
  - Empty lists
  - Unit expressions
  - Deep nesting (lists, tuples, records, lets)
  - Complex expression combinations

### 2.5 Decision Tree Compilation
- **DecisionTreeAdvancedTests.elm** - Pattern match compilation to decision trees
  - Literal pattern optimization
  - Constructor patterns
  - Overlapping patterns

---

## Section 3: Patterns Tested ONLY in E2E Tests

These patterns verify runtime behavior that the compiler unit tests don't cover:

### 3.1 Integer Edge Cases
- **IntBasics.elm**, **IntegerTests.elm**
  - Integer overflow behavior
  - Negative number operations
  - Zero edge cases
  - `abs`, `min`, `max` functions
  - `clamp` function

### 3.2 Float Special Values
- **FloatTests.elm**, **FloatBasics.elm**
  - Infinity handling
  - NaN behavior
  - Floating point precision
  - `floor`, `ceiling`, `round`, `truncate`
  - `isNaN`, `isInfinite`
  - Scientific notation

### 3.3 Bitwise Operations
- **BitwiseTests.elm**
  - `Bitwise.and`, `Bitwise.or`, `Bitwise.xor`
  - `Bitwise.complement`
  - `Bitwise.shiftLeftBy`, `Bitwise.shiftRightBy`, `Bitwise.shiftRightZfBy`

### 3.4 Character Operations
- **CharTests.elm**, **CharBasics.elm**
  - `Char.toCode`, `Char.fromCode`
  - Unicode handling
  - `Char.isUpper`, `Char.isLower`, `Char.isDigit`, `Char.isAlpha`
  - `Char.toUpper`, `Char.toLower`

### 3.5 String Operations
- **StringTests.elm**, **StringBasics.elm**
  - `String.length`, `String.isEmpty`
  - `String.reverse`, `String.repeat`
  - `String.left`, `String.right`, `String.dropLeft`, `String.dropRight`
  - `String.contains`, `String.startsWith`, `String.endsWith`
  - `String.split`, `String.join`
  - `String.toInt`, `String.fromInt`, `String.toFloat`, `String.fromFloat`
  - `String.toList`, `String.fromList`
  - `String.map`, `String.filter`, `String.foldl`, `String.foldr`
  - Unicode/emoji handling
  - Multi-line strings

### 3.6 Standard Library Functions
- **List functions** (beyond basic)
  - `List.range`, `List.repeat`, `List.indexedMap`
  - `List.filterMap`, `List.concatMap`
  - `List.any`, `List.all`, `List.member`
  - `List.sort`, `List.sortBy`, `List.sortWith`
  - `List.take`, `List.drop`
  - `List.partition`, `List.unzip`
  - `List.intersperse`

- **Maybe functions**
  - `Maybe.map`, `Maybe.map2`, etc.
  - `Maybe.andThen`
  - `Maybe.withDefault`

- **Result functions**
  - `Result.map`, `Result.mapError`
  - `Result.andThen`
  - `Result.withDefault`
  - `Result.toMaybe`, `Result.fromMaybe`

### 3.7 Composition and Pipes
- **CompositionTests.elm**, **PipeTests.elm**
  - Forward pipe (`|>`)
  - Backward pipe (`<|`)
  - Function composition (`>>`, `<<`)
  - Complex pipe chains

### 3.8 Recursion Patterns
- **RecursionTests.elm**, **TailRecursionTests.elm**
  - Tail call optimization verification
  - Deep recursion without stack overflow
  - Accumulator patterns

### 3.9 Comparison and Ordering
- **CompareTests.elm**
  - `compare` function returning `Order`
  - Lexicographic comparison of tuples/lists
  - Custom type comparison

### 3.10 Debug Functions
- **DebugTests.elm**
  - `Debug.log`, `Debug.toString`
  - Debug output formatting

### 3.11 Basics Module Functions
- **BasicsTests.elm**
  - `identity`, `always`
  - `never`
  - Number conversion functions

---

## Section 4: Gap Analysis

### 4.1 Coverage Gaps in StandardTestSuites

The compiler unit tests don't verify:
1. **Runtime correctness** - Whether generated code executes correctly
2. **Standard library behavior** - Most Elm core functions
3. **Edge case values** - Overflow, NaN, Infinity, Unicode
4. **Tail call optimization** - Whether recursion is properly optimized
5. **Bitwise operations** - Low-level integer manipulation

### 4.2 Coverage Gaps in E2E Tests

The E2E tests don't verify:
1. **Compiler error handling** - Invalid code rejection
2. **Type inference** - Correct type derivation
3. **AST transformation correctness** - Internal compiler representations
4. **Port handling** - JavaScript interop generation
5. **Optimization passes** - Specialization, dead code elimination

### 4.3 Overlap Assessment

**High overlap areas** (tested similarly in both):
- Basic literals and arithmetic
- Simple functions and lambdas
- Basic pattern matching
- Tuples, lists, records
- If-then-else expressions
- Let expressions

**Complementary coverage** (different aspects tested):
- StandardTestSuites: AST structure, type annotations, compiler internals
- E2E Tests: Runtime behavior, standard library, edge cases

---

## Section 5: Recommendations

### 5.1 Potential E2E Test Additions for StandardTestSuites

Consider adding compiler unit tests for:
1. **Bitwise operations** - Ensure correct code generation for bit ops
2. **String operations** - Verify string handling compilation
3. **Float special values** - Test NaN/Infinity code paths

### 5.2 Potential StandardTestSuites Additions for E2E

Consider adding E2E tests for:
1. **Type annotation validation** - Ensure annotated code runs correctly
2. **Closure behavior** - Verify closures capture correctly at runtime
3. **Complex pattern matching** - Decision tree correctness

### 5.3 Test Architecture Observations

The two test suites serve different purposes:
- **StandardTestSuites**: "Does the compiler transform code correctly?"
- **E2E Tests**: "Does the compiled code run correctly?"

Both are necessary for complete coverage. They complement each other well, with minimal true redundancy (different aspects of the same features are tested).
