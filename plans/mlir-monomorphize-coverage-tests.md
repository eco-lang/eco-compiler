# MLIR and Monomorphize Coverage Test Plan

## Overview

This plan outlines ~200 new test cases to improve coverage of the MLIR code generation and Monomorphization compiler passes. Tests are organized by the specific functions they exercise.

## Coverage Analysis Summary

### MLIR Backend Modules

| Module | Case Branches | Declarations | If/Else | Lambdas | Let-Decls |
|--------|---------------|--------------|---------|---------|-----------|
| TypeTable | 28/29 (97%) | 14/14 (100%) | 6/6 (100%) | 47/47 (100%) | - |
| Patterns | 29/57 (51%) | 7/7 (100%) | 6/11 (55%) | 1/1 (100%) | 47/62 (76%) |
| Names | 2/2 (100%) | - | - | - | - |
| Expr | 65/98 (66%) | 38/43 (88%) | 39/59 (66%) | 19/21 (90%) | 225/310 (73%) |
| Lambdas | 3/4 (75%) | 3/4 (75%) | 2/4 (50%) | 5/9 (56%) | 21/38 (55%) |
| Backend | 1/2 (50%) | 2/2 (100%) | 3/3 (100%) | 11/11 (100%) | - |
| Functions | 14/50 (28%) | 10/15 (67%) | 0/4 (0%) | 6/11 (55%) | 51/92 (55%) |
| Types | 21/31 (68%) | 9/11 (82%) | 1/3 (33%) | - | - |
| Ops | 2/14 (14%) | 34/38 (89%) | 6/10 (60%) | 5/6 (83%) | 31/35 (89%) |
| Intrinsics | 42/113 (37%) | 5/8 (63%) | 0/6 (0%) | 0/1 (0%) | 5/11 (45%) |
| Context | 23/38 (61%) | 13/14 (93%) | 0/2 (0%) | 5/5 (100%) | 9/12 (75%) |

### Monomorphize Modules

| Module | Case Branches | Declarations | If/Else | Lambdas | Let-Decls |
|--------|---------------|--------------|---------|---------|-----------|
| KernelAbi | 17/35 (49%) | 10/10 (100%) | 10/11 (91%) | 2/6 (33%) | 4/9 (44%) |
| Closure | 29/47 (62%) | 12/12 (100%) | 6/6 (100%) | 10/12 (83%) | 37/37 (100%) |
| Specialize | 87/146 (60%) | 33/39 (85%) | 5/12 (42%) | 20/28 (71%) | 179/242 (74%) |
| TypeSubst | 47/54 (87%) | 8/8 (100%) | 6/6 (100%) | 6/9 (67%) | 21/22 (95%) |
| State | 1/3 (33%) | 0/1 (0%) | - | - | - |
| Analysis | 34/61 (56%) | 5/7 (71%) | 14/21 (67%) | 11/15 (73%) | - |
| Monomorphize | 25/48 (52%) | 15/28 (54%) | 8/17 (47%) | 3/7 (43%) | 34/39 (87%) |

---

## Part 1: Functions with Incomplete Coverage

### 1.1 MLIR.Intrinsics (37% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `intrinsicOperandTypes` | 0/12 (0%) | Maps intrinsic to expected operand types |
| `bitwiseIntrinsic` | 0/8 (0%) | Bitwise operations (and, or, xor, shifts) |
| `basicsIntrinsic` | 21/56 (38%) | Basic math ops - missing many float/comparison ops |
| `generateIntrinsicOp` | 12/22 (55%) | Op generation - missing some intrinsic types |
| `intrinsicResultMlirType` | 7/12 (58%) | Result type mapping |
| `kernelIntrinsic` | 2/3 (67%) | Kernel intrinsic dispatch |

**Untested Elm constructs:**
- `Bitwise.and`, `Bitwise.or`, `Bitwise.xor`, `Bitwise.complement`
- `Bitwise.shiftLeftBy`, `Bitwise.shiftRightBy`, `Bitwise.shiftRightZfBy`
- Float comparison: `<`, `<=`, `>`, `>=` on Float
- `Basics.e`, `Basics.pi` (constants)
- Float math: `sqrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`
- `Basics.isNaN`, `Basics.isInfinite`
- `Basics.round`, `Basics.floor`, `Basics.ceiling`, `Basics.truncate`

### 1.2 MLIR.Functions (28% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `dumpMonoExprStructure` | 0/10 (0%) | Debug dumping (low priority) |
| `generateCtor` | 0/4 (0%) | Constructor generation |
| `createDummyValue` | 0/5 (0%) | Stub value creation |
| `generateEnum` | 0/4 (0%) | Enum type generation |
| `generateNode` | 3/11 (27%) | Node code generation |
| `generateStubValueFromMlirType` | 2/5 (40%) | Type-based stub generation |

**Untested Elm constructs:**
- Custom type constructors with multiple arguments
- Nullary constructors (enums)
- External function stubs

### 1.3 MLIR.Patterns (51% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `computeFallbackTag` | 1/5 (20%) | Fallback tag computation |
| `testToTagInt` | 2/9 (22%) | Pattern test to tag conversion |
| `caseKindFromTest` | 2/8 (25%) | Case kind determination |
| `generateDTPath` | 4/8 (50%) | Decision tree path generation |
| `generateTest` | 10/16 (62%) | Pattern test generation |
| `generateChainCondition` | 2/3 (67%) | Chain condition generation |

**Untested Elm constructs:**
- Char patterns in case expressions
- String patterns in case expressions
- Nested constructor patterns
- Multiple guards/conditions in patterns
- Complex pattern matching with fallback

### 1.4 MLIR.Expr (66% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `generateVarKernel` | 0/7 (0%) | Kernel variable generation |
| `findBoolBranches` | 0/2 (0%) | Boolean branch detection |
| `generateVarGlobal` | 1/4 (25%) | Global variable generation |
| `createDummyValue` | 2/5 (40%) | Dummy value creation |
| `isBoolFanOut` | 2/4 (50%) | Boolean fanout detection |
| `generateFanOutGeneral` | 1/2 (50%) | General fanout generation |
| `generateChain` | 1/2 (50%) | Chain expression generation |
| `generateLeaf` | 1/2 (50%) | Leaf expression generation |
| `generateSaturatedCall` | 14/22 (64%) | Saturated call generation |
| `generateTupleCreate` | 2/3 (67%) | Tuple creation |
| `generateExpr` | 17/19 (89%) | Main expression generation |

**Untested Elm constructs:**
- Kernel function references
- Multi-way if expressions (if/elseif/else chains)
- Complex tuple creation patterns
- Boolean short-circuit evaluation

### 1.5 MLIR.Ops (14% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `ecoConstructCustom` | 0/2 (0%) | Custom type construction |
| `arithCmpI` | 1/11 (9%) | Integer comparison ops |

**Untested Elm constructs:**
- Various integer comparison operations
- Custom type construction at MLIR level

### 1.6 MLIR.Types (68% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `mlirTypeToString` | 0/7 (0%) | Type to string (debug) |
| `countTotalArity` | 0/2 (0%) | Arity counting |
| `monoTypeToMlir` | 13/14 (93%) | Type conversion |

### 1.7 MLIR.Context (61% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `isTypeVar` | 0/2 (0%) | Type variable check |
| `extractNodeSignature` | 6/16 (38%) | Node signature extraction |
| `registerKernelCall` | 1/2 (50%) | Kernel call registration |
| `buildSignatures` | 1/2 (50%) | Signature building |
| `lookupVar` | 1/2 (50%) | Variable lookup |

### 1.8 Monomorphize.Specialize (60% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `extractFieldTypes` | 0/2 (0%) | Field type extraction |
| `extractCtorResultType` | 0/2 (0%) | Constructor result type |
| `monoGlobalToTOpt` | 0/2 (0%) | Global to typed opt conversion |
| `specializeCycle` | 1/4 (25%) | Cycle specialization |
| `deriveKernelAbiType` | 1/3 (33%) | Kernel ABI type derivation |
| `resolveProcessedArg` | 4/9 (44%) | Argument resolution |
| `specializeNode` | 8/17 (47%) | Node specialization |
| `specializeExpr` | 37/60 (62%) | Expression specialization |

**Untested Elm constructs:**
- Complex recursive cycles with multiple nodes
- Kernel function polymorphism
- Record field extraction in complex contexts
- Specialized cycles with mixed function/value nodes

### 1.9 Monomorphize.Closure (62% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `extractRegion` | 2/17 (12%) | Region extraction from expressions |
| `collectDeciderFreeLocals` | 4/5 (80%) | Free local collection in deciders |
| `findFreeLocals` | 11/13 (85%) | Free local variable finding |

**Untested Elm constructs:**
- Closures capturing many different expression types
- Nested closures
- Closures in case expressions

### 1.10 Monomorphize.Analysis (56% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `collectDepsHelp` | 0/16 (0%) | Dependency collection helper |
| `collectDeciderDeps` | 0/5 (0%) | Decider dependency collection |
| `collectAllCustomTypes` | 4/8 (50%) | Custom type collection |
| `lookupUnion` | 1/2 (50%) | Union type lookup |

### 1.11 Monomorphize.KernelAbi (49% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `freeVarsHelper` | 3/8 (38%) | Free variable helper |
| `canTypeToMonoType_numberBoxed` | 3/8 (38%) | Number-boxed type conversion |
| `canTypeToMonoType_preserveVars` | 3/8 (38%) | Var-preserving type conversion |
| `convertTType` | 8/11 (73%) | Type conversion |

### 1.12 Monomorphize (52% case coverage)

**Functions needing tests:**

| Function | Coverage | Description |
|----------|----------|-------------|
| `deriveKernelAbiType` | 0/3 (0%) | Kernel ABI type derivation |
| `extractFieldTypes` | 0/2 (0%) | Field type extraction |
| `lookupFieldIndex` | 0/2 (0%) | Field index lookup |
| `getTupleLayout` | 0/2 (0%) | Tuple layout retrieval |
| `getRecordLayout` | 0/2 (0%) | Record layout retrieval |
| `checkCallableTopLevels` | 4/9 (44%) | Top-level callability check |
| `computeCtorLayoutsForGraph` | 2/4 (50%) | Constructor layout computation |

---

## Part 2: Proposed Test Cases

### Category 1: Bitwise Operations (~20 tests)

**Target file: `compiler/tests/Compiler/BitwiseTests.elm` (NEW)**

These tests exercise `MLIR.Intrinsics.bitwiseIntrinsic`.

```elm
-- Test 1: Bitwise.and
testValue = Bitwise.and 0xFF00 0x0F0F  -- Result: 0x0F00

-- Test 2: Bitwise.or
testValue = Bitwise.or 0xF0 0x0F  -- Result: 0xFF

-- Test 3: Bitwise.xor
testValue = Bitwise.xor 0xFF 0x0F  -- Result: 0xF0

-- Test 4: Bitwise.complement
testValue = Bitwise.complement 0  -- Result: -1

-- Test 5: Bitwise.shiftLeftBy
testValue = Bitwise.shiftLeftBy 4 1  -- Result: 16

-- Test 6: Bitwise.shiftRightBy
testValue = Bitwise.shiftRightBy 2 16  -- Result: 4

-- Test 7: Bitwise.shiftRightZfBy
testValue = Bitwise.shiftRightZfBy 2 (-8)  -- Zero-fill shift

-- Test 8: Combined bitwise ops
testValue = Bitwise.and (Bitwise.or 0xF0 0x0F) (Bitwise.complement 0x00)

-- Test 9: Bitwise in function
setBit : Int -> Int -> Int
setBit bit n = Bitwise.or n (Bitwise.shiftLeftBy bit 1)
testValue = setBit 3 0  -- Result: 8

-- Test 10: Bitwise mask extraction
getMask : Int -> Int -> Int
getMask start width =
    Bitwise.and (Bitwise.shiftRightBy start n) ((Bitwise.shiftLeftBy width 1) - 1)

-- Tests 11-20: More complex bitwise patterns with conditionals and recursion
```

### Category 2: Float Math Operations (~25 tests)

**Target file: `compiler/tests/Compiler/FloatMathTests.elm` (NEW)**

These tests exercise `MLIR.Intrinsics.basicsIntrinsic` float branches.

```elm
-- Test 1: Basics.pi
testValue = Basics.pi  -- 3.14159...

-- Test 2: Basics.e
testValue = Basics.e  -- 2.71828...

-- Test 3: sqrt
testValue = sqrt 16.0  -- 4.0

-- Test 4: sin
testValue = sin 0.0  -- 0.0

-- Test 5: cos
testValue = cos 0.0  -- 1.0

-- Test 6: tan
testValue = tan 0.0  -- 0.0

-- Test 7: asin
testValue = asin 0.0  -- 0.0

-- Test 8: acos
testValue = acos 1.0  -- 0.0

-- Test 9: atan
testValue = atan 0.0  -- 0.0

-- Test 10: atan2
testValue = atan2 1.0 1.0  -- pi/4

-- Test 11: logBase (might fall through to kernel)
testValue = logBase 2.0 8.0  -- 3.0

-- Test 12: isNaN
testValue = isNaN (0.0 / 0.0)  -- True

-- Test 13: isInfinite
testValue = isInfinite (1.0 / 0.0)  -- True

-- Test 14: Float comparison <
testValue = 1.5 < 2.5  -- True

-- Test 15: Float comparison <=
testValue = 2.0 <= 2.0  -- True

-- Test 16: Float comparison >
testValue = 3.0 > 2.0  -- True

-- Test 17: Float comparison >=
testValue = 2.0 >= 2.0  -- True

-- Test 18: Float min
testValue = min 1.5 2.5  -- 1.5

-- Test 19: Float max
testValue = max 1.5 2.5  -- 2.5

-- Test 20: round
testValue = round 2.7  -- 3

-- Test 21: floor
testValue = floor 2.7  -- 2

-- Test 22: ceiling
testValue = ceiling 2.3  -- 3

-- Test 23: truncate
testValue = truncate 2.7  -- 2

-- Test 24: toFloat
testValue = toFloat 42  -- 42.0

-- Test 25: Combined float ops
testValue = sqrt (sin pi * sin pi + cos pi * cos pi)  -- 1.0
```

### Category 3: Pattern Matching (~30 tests)

**Target file: `compiler/tests/Compiler/PatternMatchingTests.elm` (NEW)**

These tests exercise `MLIR.Patterns` functions.

```elm
-- Test 1: Char pattern
charName : Char -> String
charName c =
    case c of
        'a' -> "letter a"
        'b' -> "letter b"
        _ -> "other"
testValue = charName 'a'

-- Test 2: Multiple char patterns
isVowel : Char -> Bool
isVowel c =
    case c of
        'a' -> True
        'e' -> True
        'i' -> True
        'o' -> True
        'u' -> True
        _ -> False
testValue = isVowel 'e'

-- Test 3: String pattern
greet : String -> String
greet name =
    case name of
        "Alice" -> "Hello Alice!"
        "Bob" -> "Hi Bob!"
        _ -> "Hello stranger"
testValue = greet "Alice"

-- Test 4: Nested constructor pattern
type Tree a = Leaf a | Node (Tree a) a (Tree a)
depth : Tree a -> Int
depth tree =
    case tree of
        Leaf _ -> 1
        Node left _ right -> 1 + max (depth left) (depth right)
testValue = depth (Node (Leaf 1) 2 (Leaf 3))

-- Test 5: Multiple constructors with fields
type Shape = Circle Float | Rectangle Float Float | Triangle Float Float Float
area : Shape -> Float
area shape =
    case shape of
        Circle r -> 3.14159 * r * r
        Rectangle w h -> w * h
        Triangle a b c ->
            let s = (a + b + c) / 2
            in sqrt (s * (s - a) * (s - b) * (s - c))
testValue = area (Rectangle 3.0 4.0)

-- Test 6: Guards in patterns (if-else in branches)
classify : Int -> String
classify n =
    case n of
        0 -> "zero"
        x -> if x > 0 then "positive" else "negative"
testValue = classify (-5)

-- Test 7: As-pattern with nested matching
type List a = Nil | Cons a (List a)
firstTwo : List a -> Maybe (a, a)
firstTwo list =
    case list of
        Cons x ((Cons y _) as rest) -> Just (x, y)
        _ -> Nothing

-- Test 8: Wildcard in middle of pattern
getMiddle : (a, b, c) -> b
getMiddle tuple =
    case tuple of
        (_, middle, _) -> middle
testValue = getMiddle (1, 2, 3)

-- Tests 9-30: More complex pattern combinations, fallback patterns, etc.
```

### Category 4: Custom Type Constructors (~20 tests)

**Target file: Add to `compiler/tests/Compiler/SpecializeConstructorTests.elm`**

These tests exercise `MLIR.Functions.generateCtor` and `generateEnum`.

```elm
-- Test: Nullary constructors (enum)
type Suit = Hearts | Diamonds | Clubs | Spades
suitValue : Suit -> Int
suitValue s =
    case s of
        Hearts -> 1
        Diamonds -> 2
        Clubs -> 3
        Spades -> 4
testValue = suitValue Hearts

-- Test: Constructor with 4+ fields
type Record4 = Rec4 Int Int Int Int
sumRec4 : Record4 -> Int
sumRec4 r =
    case r of
        Rec4 a b c d -> a + b + c + d
testValue = sumRec4 (Rec4 1 2 3 4)

-- Test: Recursive type constructor
type Nat = Zero | Succ Nat
natToInt : Nat -> Int
natToInt n =
    case n of
        Zero -> 0
        Succ m -> 1 + natToInt m
testValue = natToInt (Succ (Succ Zero))

-- Additional 17 tests covering various constructor patterns
```

### Category 5: Closure and Free Variables (~25 tests)

**Target file: `compiler/tests/Compiler/ClosureTests.elm` (NEW)**

These tests exercise `Monomorphize.Closure` functions.

```elm
-- Test 1: Simple closure over local
makeAdder : Int -> (Int -> Int)
makeAdder x = \y -> x + y
testValue = makeAdder 5 10  -- 15

-- Test 2: Closure over multiple locals
makeCombiner : Int -> Int -> (Int -> Int)
makeCombiner a b = \x -> a * x + b
testValue = makeCombiner 2 3 5  -- 13

-- Test 3: Nested closure
makeNestedAdder : Int -> (Int -> (Int -> Int))
makeNestedAdder x = \y -> \z -> x + y + z
testValue = makeNestedAdder 1 2 3  -- 6

-- Test 4: Closure in let binding
letClosure : Int -> Int
letClosure n =
    let
        f = \x -> x + n
    in
    f 10
testValue = letClosure 5  -- 15

-- Test 5: Closure in case expression
caseClosure : Maybe Int -> (Int -> Int)
caseClosure m =
    case m of
        Just n -> \x -> x + n
        Nothing -> \x -> x
testValue = caseClosure (Just 5) 10  -- 15

-- Test 6: Closure capturing record
closureWithRecord : { x : Int, y : Int } -> (Int -> Int)
closureWithRecord rec = \n -> rec.x + rec.y + n
testValue = closureWithRecord { x = 1, y = 2 } 3  -- 6

-- Test 7: Closure capturing tuple
closureWithTuple : (Int, Int) -> (Int -> Int)
closureWithTuple (a, b) = \n -> a + b + n
testValue = closureWithTuple (1, 2) 3  -- 6

-- Tests 8-25: More complex closure patterns, closures in recursion, etc.
```

### Category 6: Kernel Function Calls (~20 tests)

**Target file: Add to `compiler/tests/Compiler/KernelTests.elm`**

These tests exercise kernel function handling in MLIR codegen.

```elm
-- Test: List.length
testValue = List.length [1, 2, 3, 4, 5]  -- 5

-- Test: List.reverse
testValue = List.reverse [1, 2, 3]  -- [3, 2, 1]

-- Test: List.member
testValue = List.member 3 [1, 2, 3, 4]  -- True

-- Test: String.length
testValue = String.length "hello"  -- 5

-- Test: String.append
testValue = String.append "hello" " world"  -- "hello world"

-- Test: String.split
testValue = String.split "," "a,b,c"  -- ["a", "b", "c"]

-- Test: Char.toCode
testValue = Char.toCode 'A'  -- 65

-- Test: Char.fromCode
testValue = Char.fromCode 65  -- 'A'

-- Additional kernel function tests
```

### Category 7: Complex Monomorphization (~25 tests)

**Target file: Add to `compiler/tests/Compiler/SpecializeCycleTests.elm`**

These tests exercise complex monomorphization paths.

```elm
-- Test: Polymorphic identity in cycle
id : a -> a
id x = x
testValue = id (id 42)

-- Test: Higher-kinded polymorphism
map : (a -> b) -> List a -> List b
map f xs =
    case xs of
        [] -> []
        x :: rest -> f x :: map f rest
testValue = map (\x -> x + 1) [1, 2, 3]

-- Test: Mutually recursive with different instantiations
evenOdd : Int -> Bool
evenOdd n = if n == 0 then True else oddEven (n - 1)
oddEven : Int -> Bool
oddEven n = if n == 0 then False else evenOdd (n - 1)
testValue = evenOdd 10

-- Additional complex monomorphization tests
```

### Category 8: Record Operations (~20 tests)

**Target file: Add to `compiler/tests/Compiler/RecordTests.elm`**

These exercise record-related code paths.

```elm
-- Test: Record with many fields
type alias BigRecord = { a : Int, b : Int, c : Int, d : Int, e : Int }
sumBigRecord : BigRecord -> Int
sumBigRecord r = r.a + r.b + r.c + r.d + r.e
testValue = sumBigRecord { a = 1, b = 2, c = 3, d = 4, e = 5 }

-- Test: Nested record access
type alias Outer = { inner : { value : Int } }
getNestedValue : Outer -> Int
getNestedValue o = o.inner.value
testValue = getNestedValue { inner = { value = 42 } }

-- Test: Record update with multiple fields
updateMultiple : { x : Int, y : Int, z : Int } -> { x : Int, y : Int, z : Int }
updateMultiple r = { r | x = r.x + 1, y = r.y + 1 }
testValue = (updateMultiple { x = 1, y = 2, z = 3 }).x

-- Additional record tests
```

### Category 9: Tuple Operations (~15 tests)

**Target file: Add to `compiler/tests/Compiler/TupleTests.elm`**

```elm
-- Test: Triple creation and access
makeTriple : a -> b -> c -> (a, b, c)
makeTriple x y z = (x, y, z)
getFirst3 : (a, b, c) -> a
getFirst3 (x, _, _) = x
testValue = getFirst3 (makeTriple 1 2 3)

-- Test: Nested tuples
type alias NestedTuple = ((Int, Int), (Int, Int))
sumNested : NestedTuple -> Int
sumNested ((a, b), (c, d)) = a + b + c + d
testValue = sumNested ((1, 2), (3, 4))

-- Additional tuple tests
```

### Category 10: Boolean and Control Flow (~20 tests)

**Target file: Add to `compiler/tests/Compiler/ControlFlowTests.elm` (NEW)**

```elm
-- Test: Multiple if branches
classify : Int -> String
classify n =
    if n < 0 then "negative"
    else if n == 0 then "zero"
    else if n < 10 then "small"
    else if n < 100 then "medium"
    else "large"
testValue = classify 50

-- Test: Boolean short-circuit
shortCircuit : Int -> Bool
shortCircuit n = n > 0 && (1000 // n > 10)
testValue = shortCircuit 50

-- Test: Complex boolean expression
complexBool : Int -> Int -> Bool
complexBool a b = (a > 0 || b > 0) && (a < 100 && b < 100)
testValue = complexBool 50 50

-- Additional control flow tests
```

---

## Part 3: Test Organization

### New Test Files to Create

1. **`BitwiseTests.elm`** - ~20 tests for bitwise operations
2. **`FloatMathTests.elm`** - ~25 tests for float math functions
3. **`PatternMatchingTests.elm`** - ~30 tests for complex patterns
4. **`ClosureTests.elm`** - ~25 tests for closure/free variable handling
5. **`ControlFlowTests.elm`** - ~20 tests for control flow

### Existing Files to Extend

1. **`SpecializeConstructorTests.elm`** - Add ~20 constructor tests
2. **`SpecializeCycleTests.elm`** - Add ~25 monomorphization tests
3. **`RecordTests.elm`** - Add ~20 record operation tests
4. **`TupleTests.elm`** - Add ~15 tuple operation tests
5. **`KernelTests.elm`** - Add ~20 kernel function tests

### Integration Into Test Suites

All new test modules must:

1. Export `expectSuite : (Src.Module -> Expectation) -> String -> Test`
2. Be imported in `TypedOptimizedMonomorphizeTest.elm`
3. Be added to `InvariantTests.elm` under appropriate sections

**Add to `TypedOptimizedMonomorphizeTest.elm`:**
```elm
import Compiler.BitwiseTests as BitwiseTests
import Compiler.FloatMathTests as FloatMathTests
import Compiler.PatternMatchingTests as PatternMatchingTests
import Compiler.ClosureTests as ClosureTests
import Compiler.ControlFlowTests as ControlFlowTests

suite =
    Test.describe "TypedOptimized code monomorphizes successfully"
        [ -- existing tests...
        , BitwiseTests.expectSuite expectMonomorphization "monomorphizes"
        , FloatMathTests.expectSuite expectMonomorphization "monomorphizes"
        , PatternMatchingTests.expectSuite expectMonomorphization "monomorphizes"
        , ClosureTests.expectSuite expectMonomorphization "monomorphizes"
        , ControlFlowTests.expectSuite expectMonomorphization "monomorphizes"
        ]
```

---

## Part 4: Implementation Steps

### Phase 1: Create BitwiseTests.elm (~20 tests)
1. Create new file with `expectSuite` pattern
2. Add tests for all Bitwise module functions
3. Integrate into test suites
4. Run tests, fix any canonicalization/type errors

### Phase 2: Create FloatMathTests.elm (~25 tests)
1. Create new file with float math tests
2. Cover all Basics float functions
3. Cover float comparisons
4. Integrate and test

### Phase 3: Create PatternMatchingTests.elm (~30 tests)
1. Create tests for Char patterns
2. Create tests for String patterns
3. Create tests for nested patterns
4. Create tests for complex fallback patterns
5. Integrate and test

### Phase 4: Create ClosureTests.elm (~25 tests)
1. Create simple closure tests
2. Create nested closure tests
3. Create closure-in-case tests
4. Create closure capturing different types
5. Integrate and test

### Phase 5: Create ControlFlowTests.elm (~20 tests)
1. Create multi-branch if tests
2. Create boolean short-circuit tests
3. Create complex boolean expression tests
4. Integrate and test

### Phase 6: Extend Existing Test Files (~80 tests)
1. Add ~20 tests to SpecializeConstructorTests.elm
2. Add ~25 tests to SpecializeCycleTests.elm
3. Add ~20 tests to RecordTests.elm
4. Add ~15 tests to TupleTests.elm

### Phase 7: Final Integration
1. Verify all tests pass through canonicalization
2. Verify all tests pass through type checking
3. Document any Monomorphization/MLIR failures found
4. Update InvariantTests.elm with all new suites

---

## Part 5: Expected Outcomes

### Coverage Improvements

| Module | Before | Target |
|--------|--------|--------|
| MLIR.Intrinsics | 37% | 70%+ |
| MLIR.Functions | 28% | 60%+ |
| MLIR.Patterns | 51% | 75%+ |
| MLIR.Expr | 66% | 80%+ |
| Monomorphize.Specialize | 60% | 80%+ |
| Monomorphize.Closure | 62% | 80%+ |

### Test Count

- New test files: 5 files, ~120 tests
- Extended existing files: ~80 tests
- **Total new tests: ~200**

---

## Part 6: Notes on Test Failures

If a test fails during implementation:

1. **Canonicalization failure**: Fix the test - likely bad Elm syntax
2. **Type checking failure**: Fix the test - type mismatch
3. **Typed optimization failure**: Fix the test - optimization issue
4. **Monomorphization failure**: Document as potential compiler bug
5. **MLIR codegen failure**: Document as potential compiler bug

Do NOT fix compiler code during this implementation - only document failures for later investigation.
