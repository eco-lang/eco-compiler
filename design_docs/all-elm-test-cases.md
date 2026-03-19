# All Elm Test Cases (SourceIR)

This document contains every elm-test test case from `compiler/tests/SourceIR/`,
translated from the SourceBuilder DSL into plain Elm source code.

Each test case constructs a module with a `testValue` definition (and sometimes
supporting type/function definitions). The compiler test harness feeds each module
through the full compilation pipeline and checks various invariants.

## Table of Contents

| # | Section | Category |
|---|---------|----------|
| 1 | [LiteralCases](#literalcases) | Basics |
| 2 | [BinopCases](#binopcases) | Basics |
| 3 | [OperatorCases](#operatorcases) | Basics |
| 4 | [ControlFlowCases](#controlflowcases) | Basics |
| 5 | [BoolCaseCases](#boolcasecases) | Basics |
| 6 | [CaseCases](#casecases) | Basics |
| 7 | [FunctionCases](#functioncases) | Functions |
| 8 | [HigherOrderCases](#higherordercases) | Functions |
| 9 | [ClosureCases](#closurecases) | Functions |
| 10 | [ClosureAbiBranchCases](#closureabibranchcases) | Functions |
| 11 | [LetCases](#letcases) | Let/Pattern |
| 12 | [LetRecCases](#letreccases) | Let/Pattern |
| 13 | [LetDestructCases](#letdestructcases) | Let/Pattern |
| 14 | [LetDestructFnCases](#letdestructfncases) | Let/Pattern |
| 15 | [AsPatternCases](#aspatternCases) | Let/Pattern |
| 16 | [PatternMatchingCases](#patternmatchingcases) | Let/Pattern |
| 17 | [PatternArgCases](#patternargcases) | Let/Pattern |
| 18 | [ListCases](#listcases) | Data Structures |
| 19 | [TupleCases](#tuplecases) | Data Structures |
| 20 | [RecordCases](#recordcases) | Data Structures |
| 21 | [ArrayCases](#arraycases) | Data Structures |
| 22 | [FloatMathCases](#floatmathcases) | Data Structures |
| 23 | [KernelCases](#kernelcases) | Kernel |
| 24 | [KernelIntrinsicCases](#kernelintrinsicCases) | Kernel |
| 25 | [KernelHigherOrderCases](#kernelhigherordercases) | Kernel |
| 26 | [KernelCompositionCases](#kernelcompositioncases) | Kernel |
| 27 | [KernelOperatorCases](#kerneloperatorcases) | Kernel |
| 28 | [KernelComparisonCases](#kernelcomparisoncases) | Kernel |
| 29 | [KernelContextCases](#kernelcontextcases) | Kernel |
| 30 | [KernelPapAbiCases](#kernelpapabicases) | Kernel |
| 31 | [KernelCtorArgCases](#kernelctorargcases) | Kernel |
| 32 | [SpecializeExprCases](#specializeexprcases) | Specialization |
| 33 | [SpecializeAccessorCases](#specializeaccessorcases) | Specialization |
| 34 | [SpecializeConstructorCases](#specializeconstructorcases) | Specialization |
| 35 | [SpecializeRecordCtorCases](#specializerecordctorcases) | Specialization |
| 36 | [SpecializeCycleCases](#specializecyclecases) | Specialization |
| 37 | [SpecializePolyLetCases](#specializepolyletcases) | Specialization |
| 38 | [SpecializePolyTopCases](#specializepolytopcases) | Specialization |
| 39 | [PolyChainCases](#polychaincases) | Specialization |
| 40 | [PolyEscapeCases](#polyescapecases) | Specialization |
| 41 | [TailRecCaseCases](#tailreccasecases) | Recursion |
| 42 | [TailRecLetRecClosureCases](#tailrecletrecclosurecases) | Recursion |
| 43 | [LocalTailRecCases](#localtailreccases) | Recursion |
| 44 | [DecisionTreeAdvancedCases](#decisiontreeadvancedcases) | Recursion |
| 45 | [RecursiveTypeCases](#recursivetypecases) | Recursion |
| 46 | [MonoCompoundCases](#monocompoundcases) | Recursion |
| 47 | [AnnotatedCases](#annotatedcases) | Misc |
| 48 | [BitwiseCases](#bitwisecases) | Misc |
| 49 | [EdgeCaseCases](#edgecasecases) | Misc |
| 50 | [ForeignCases](#foreigncases) | Misc |
| 51 | [MultiDefCases](#multidefcases) | Misc |
| 52 | [ParamArityCases](#paramAritycases) | Misc |
| 53 | [JoinpointABICases](#joinpointabicases) | Misc |
| 54 | [PostSolveExprCases](#postsolveexprcases) | Misc |
| 55 | [BytesFusionCases](#bytesfusioncases) | Misc |
| 56 | [PortEncodingCases](#portencodingcases) | Misc |
| 57 | [TypeCheckFailsCases](#typecheckfailscases) | Misc |
| 58 | [PatternComplexityFuzzCases](#patterncomplexityfuzzcases) | Fuzz |
| 59 | [AccessorFuzzCases](#accessorfuzzcases) | Fuzz |
| 60 | [CombinatorCases](#combinatorcases) | Combinators |
| 61 | [CombinatorStdlibCases](#combinatorstdlibcases) | Combinators |

**Total: ~1053 test cases across 61 test modules**

---

## LiteralCases

### Zero
```elm
testValue = 0
```

### Positive int
```elm
testValue = 42
```

### Negative int
```elm
testValue = -42
```

### Zero float
```elm
testValue = 0.0
```

### Small positive float
```elm
testValue = 0.001
```

### Negative float
```elm
testValue = -3.14
```

### Empty string
```elm
testValue = ""
```

### String with escapes
```elm
testValue = "hello\\nworld\\ttab"
```

### Unicode string
```elm
testValue = "hello 世界"
```

### Letter char
```elm
testValue = 'a'
```

### Unit expression
```elm
testValue = ()
```

### True
```elm
testValue = True
```

### False
```elm
testValue = False
```

## BinopCases

### Simple addition
```elm
testValue = 1 + 2
```

### Simple subtraction
```elm
testValue = 5 - 3
```

### Simple multiplication
```elm
testValue = 4 * 5
```

### Simple division
```elm
testValue = 10.0 / 2.0
```

### Integer division
```elm
testValue = 10 // 3
```

### Modulo
```elm
testValue = 10 % 3
```

### Power
```elm
testValue = 2.0 ^ 3.0
```

### Equals
```elm
testValue = 1 == 1
```

### Not equals
```elm
testValue = 1 /= 2
```

### Less than
```elm
testValue = 1 < 2
```

### Greater than
```elm
testValue = 2 > 1
```

### Less than or equal
```elm
testValue = 1 <= 1
```

### Greater than or equal
```elm
testValue = 2 >= 1
```

### Compare on strings
```elm
testValue = "a" < "b"
```

### And
```elm
testValue = True && False
```

### Or
```elm
testValue = True || False
```

### Chained and
```elm
testValue = True && True && True
```

### Chained or
```elm
testValue = False || False || True
```

### String concat
```elm
testValue = "hello" ++ " world"
```

### Multiple string concat
```elm
testValue = "a" ++ "b" ++ "c"
```

### String concat with empty
```elm
testValue = "" ++ "test"
```

### List append
```elm
testValue = [1, 2] ++ [3, 4]
```

### Cons operator
```elm
testValue = 1 :: [2, 3]
```

### Cons with constant
```elm
testValue = 42 :: []
```

### Three-element addition chain
```elm
testValue = 1 + 2 + 3
```

### Mixed arithmetic chain
```elm
testValue = 1 + 2 * 3
```

### Long chain
```elm
testValue = 1 + 2 + 3 + 4 + 5
```

### Chain with different operators
```elm
testValue = 1 + 2 - 3 * 4
```

### Binop in tuple
```elm
testValue = (1 + 2, 3)
```

### Binop in list
```elm
testValue = [1 + 2, 3]
```

### Multiple binops in tuple
```elm
testValue = (1 + 2, 3 * 4)
```

### Binop with variable operands
```elm
testValue =
    let
        x = 1
        y = 2
    in
    x + y
```

### Binop with negate
```elm
testValue = -1 + 2
```

### Complex nested binops
```elm
testValue = (1 + 2) * (3 + 4)
```

### Binop with function call
```elm
testValue =
    let
        f x = x
    in
    f 1 + 2
```

### Binop with record access
```elm
testValue =
    let
        r = { x = 1, y = 2 }
    in
    r.x + r.y
```

### Binop with if expression
```elm
testValue = (if True then 1 else 0) + 2
```

### Binop inside let body
```elm
testValue =
    let
        x = 1
    in
    x + 2
```

### Binop with parens
```elm
testValue = (1 + 2) * 3
```

## OperatorCases

### Simple if
```elm
testValue = if True then 1 else 0
```

### If with int branches
```elm
testValue = if True then 1 else 2
```

### If returning tuples
```elm
testValue = if True then (1, 2) else (3, 4)
```

### If returning lists
```elm
testValue = if False then [1, 2] else []
```

### Nested if
```elm
testValue = if True then (if True then 1 else 2) else 0
```

### If in else branch
```elm
testValue = if False then 1 else if True then 2 else 3
```

### Deeply nested if
```elm
testValue = if True then 1 else if True then 2 else if True then 3 else 4
```

### If with variable condition
```elm
testValue =
    let
        cond = True
    in
    if cond then 1 else 0
```

### Negate int
```elm
testValue = -42
```

### Negate float
```elm
testValue = -3.14
```

### Double negate
```elm
testValue = -(-42)
```

### Negate variable
```elm
testValue =
    let
        x = 42
    in
    -x
```

### If with negate condition
```elm
testValue = if True then -1 else -2
```

### Negate inside if branches
```elm
testValue = if True then -1 else 1
```

### If inside tuple with negate
```elm
testValue = (if True then 1 else 0, -5)
```

### Multiple ifs and negates in list
```elm
testValue = [if True then 1 else 0, if False then 2 else 3, -4, -5]
```

## ControlFlowCases

### Three-way if
```elm
sign : Int -> Int
sign n =
    if n < 0 then
        -1
    else if n > 0 then
        1
    else
        0

testValue : Int
testValue = sign 42
```

### Four-way if
```elm
classify : Int -> String
classify n =
    if n < 0 then
        "negative"
    else if n == 0 then
        "zero"
    else if n < 10 then
        "small"
    else
        "large"

testValue : String
testValue = classify 50
```

### Five-way if
```elm
grade : Int -> String
grade score =
    if score >= 90 then
        "A"
    else if score >= 80 then
        "B"
    else if score >= 70 then
        "C"
    else if score >= 60 then
        "D"
    else
        "F"

testValue : String
testValue = grade 75
```

### If with function calls in conditions
```elm
isPositive : Int -> Bool
isPositive n = n > 0

isEven : Int -> Bool
isEven n = n // 2 * 2 == n

categorize : Int -> String
categorize n =
    if isPositive n then
        if isEven n then
            "positive even"
        else
            "positive odd"
    else
        "non-positive"

testValue : String
testValue = categorize 4
```

### If returning different types of expressions
```elm
selectList : Bool -> List Int
selectList flag =
    if flag then
        [1, 2, 3]
    else
        []

testValue : List Int
testValue = selectList True
```

### And short-circuit
```elm
safeDivide : Int -> Int -> Bool
safeDivide a b = b /= 0 && a // b > 0

testValue : Bool
testValue = safeDivide 10 2
```

### Or short-circuit
```elm
isZeroOrPositive : Int -> Bool
isZeroOrPositive n = n == 0 || n > 0

testValue : Bool
testValue = isZeroOrPositive 0
```

### Mixed and/or
```elm
inRange : Int -> Int -> Int -> Bool
inRange lo hi x = x >= lo && x <= hi || x == 0

testValue : Bool
testValue = inRange 1 10 5
```

### Short-circuit with function calls
```elm
isValid : Int -> Bool
isValid n = n > 0

isSmall : Int -> Bool
isSmall n = n < 100

checkBoth : Int -> Bool
checkBoth n = isValid n && isSmall n

testValue : Bool
testValue = checkBoth 50
```

### Triple and
```elm
allPositive : Int -> Int -> Int -> Bool
allPositive a b c = a > 0 && b > 0 && c > 0

testValue : Bool
testValue = allPositive 1 2 3
```

### Triple or
```elm
anyZero : Int -> Int -> Int -> Bool
anyZero a b c = a == 0 || b == 0 || c == 0

testValue : Bool
testValue = anyZero 1 0 3
```

### Nested boolean expressions
```elm
complexCheck : Int -> Int -> Bool
complexCheck a b = a > 0 && b > 0 || a < 0 && b < 0

testValue : Bool
testValue = complexCheck -1 -2
```

### Boolean with not
```elm
notPositive : Int -> Bool
notPositive n = not (n > 0)

testValue : Bool
testValue = notPositive -5
```

### If in if branch
```elm
nestedIf : Int -> Int -> Int
nestedIf a b =
    if a > 0 then
        if b > 0 then
            1
        else
            2
    else
        3

testValue : Int
testValue = nestedIf 5 10
```

### If in else branch
```elm
elseNested : Int -> Int -> Int
elseNested a b =
    if a > 0 then
        1
    else if b > 0 then
        2
    else
        3

testValue : Int
testValue = elseNested -1 10
```

### If in both branches
```elm
bothNested : Int -> Int -> Int
bothNested a b =
    if a > 0 then
        if b > 0 then
            1
        else
            2
    else if b > 0 then
        3
    else
        4

testValue : Int
testValue = bothNested -1 -2
```

### Deep nesting
```elm
deepNest : Int -> Int
deepNest n =
    if n > 100 then
        5
    else if n > 50 then
        4
    else if n > 25 then
        3
    else if n > 10 then
        2
    else if n > 0 then
        1
    else
        0

testValue : Int
testValue = deepNest 30
```

## BoolCaseCases

### Case on Bool True/False
```elm
classify b =
    case b of
        True -> 1
        False -> 0

testValue = classify True
```

### Case on Bool with function
```elm
boolToString : Bool -> String
boolToString b =
    case b of
        True -> "yes"
        False -> "no"

testValue : String
testValue = boolToString False
```

### Nested if-else chain
```elm
classify : Int -> String
classify n =
    if n < 0 then
        "negative"
    else if n == 0 then
        "zero"
    else
        "positive"

testValue : String
testValue = classify 5
```

### If with complex branches
```elm
pick : Bool -> Int
pick b =
    if b then
        10 + 20
    else
        5 * 3

testValue : Int
testValue = pick True
```

### Bool case returning different types
```elm
choose : Bool -> List Int
choose flag =
    if flag then
        [1, 2, 3]
    else
        []

testValue : List Int
testValue = choose True
```

### Multi-branch int case (fanout)
```elm
label : Int -> String
label n =
    case n of
        0 -> "zero"
        1 -> "one"
        2 -> "two"
        3 -> "three"
        _ -> "many"

testValue : String
testValue = label 2
```

### Case with record results
```elm
pick n =
    case n of
        0 -> { x = 0, y = 0 }
        _ -> { x = 1, y = 1 }

testValue = pick 1
```

### String escape newline
```elm
testValue = "line1\nline2"
```

### String escape tab
```elm
testValue = "col1\tcol2"
```

### String escape backslash
```elm
testValue = "path\\to\\file"
```

### String escape quote
```elm
testValue = "she said \"hello\""
```

### String with unicode
```elm
testValue = "hello \u{1F600} world"
```

## CaseCases

### Case on variable with wildcard
```elm
testValue =
    let
        x = 42
    in
    case x of
        _ -> 0
```

### Case with single variable pattern
```elm
testValue =
    let
        x = 42
    in
    case x of
        y -> y
```

### Case with two branches
```elm
testValue =
    let
        x = 1
    in
    case x of
        0 -> "zero"
        _ -> "other"
```

### Case with three branches
```elm
testValue =
    let
        x = 1
    in
    case x of
        0 -> "zero"
        1 -> "one"
        _ -> "other"
```

### Case returning complex expression
```elm
testValue =
    let
        x = 1
    in
    case x of
        n -> (n, [n])
```

### Case on int literals
```elm
testValue =
    case 5 of
        0 -> "zero"
        1 -> "one"
        5 -> "five"
        _ -> "other"
```

### Case on string literals
```elm
testValue =
    case "hello" of
        "hello" -> 1
        "world" -> 2
        _ -> 0
```

### Case with many int branches
```elm
testValue =
    case 5 of
        0 -> 0
        1 -> 10
        2 -> 20
        3 -> 30
        4 -> 40
        5 -> 50
        6 -> 60
        7 -> 70
        8 -> 80
        9 -> 90
        _ -> -1
```

### Case on string
```elm
testValue =
    case "hello" of
        "" -> 0
        x -> 1
```

### Case with negative int patterns
```elm
testValue =
    case -5 of
        -1 -> "minus one"
        0 -> "zero"
        1 -> "one"
        _ -> "other"
```

### Case on tuple with var patterns
```elm
testValue =
    case (1, 2) of
        (a, b) -> (b, a)
```

### Case on tuple with literal patterns
```elm
testValue =
    case (0, 1) of
        (0, 0) -> "both zero"
        (0, y) -> "first zero"
        (x, 0) -> "second zero"
        _ -> "neither"
```

### Case on nested tuples
```elm
testValue =
    case ((1, 2), 3) of
        ((a, b), c) -> a
```

### Case on empty list pattern
```elm
testValue =
    case [] of
        [] -> "empty"
        _ -> "not empty"
```

### Case on cons pattern
```elm
testValue =
    case [1, 2] of
        head :: tail -> head
        [] -> 0
```

### Case on fixed-length list pattern
```elm
testValue =
    case [1, 2, 3] of
        [a, b, c] -> b
        _ -> 0
```

### Case with nested cons patterns
```elm
testValue =
    case [1, 2, 3] of
        a :: b :: rest -> b
        _ -> 0
```

### Case on single-field record pattern
```elm
testValue =
    case { x = 10 } of
        { x } -> x
```

### Case on multi-field record pattern
```elm
testValue =
    case { x = 10, y = 20 } of
        { x, y } -> (x, y)
```

### Case on partial record pattern
```elm
testValue =
    case { a = 1, b = 2, c = 3 } of
        { a, c } -> (a, c)
```

### Case with simple alias pattern
```elm
testValue =
    case 42 of
        x as whole -> (x, whole)
```

### Case with tuple alias pattern
```elm
testValue =
    case (1, 2) of
        (a, b) as pair -> pair
```

### Case with list alias pattern
```elm
testValue =
    case [1, 2] of
        (h :: t) as list -> list
        [] -> []
```

### Case inside case
```elm
testValue =
    case 2 of
        0 -> "outer zero"
        _ ->
            case 1 of
                0 -> "zero"
                _ -> "other"
```

### Case in branch body
```elm
testValue =
    case (1, 2) of
        (a, b) ->
            case a of
                0 -> b
                _ -> a
```

### Case on custom type with multiple constructors
```elm
type Shape
    = Circle Int
    | Rectangle Int Int

area : Shape -> Int
area shape =
    case shape of
        Circle r -> r * r
        Rectangle w h -> w * h

testValue : Int
testValue = area (Circle 5)
```

### Case on custom type with payload extraction
```elm
type Wrapper
    = Wrap Int

unwrap : Wrapper -> Int
unwrap w =
    case w of
        Wrap x -> x

testValue : Int
testValue = unwrap (Wrap 99)
```

### String chain in tuple case with string equality (CGEN_038)
```elm
testFn x =
    let
        eq = x == "world"
        r =
            case (x, True) of
                ("foo", True) -> 1
                ("bar", False) -> 2
                _ -> 0
    in
    if eq then r else 0

testValue = testFn "hello"
```

### Single-ctor pair: Bool/Int (Bool matched, Int pollutant)
```elm
type WrapBool
    = WrapBool Bool

type WrapInt
    = WrapInt Int

matchBool : Bool -> String
matchBool b =
    let
        w = WrapBool b
    in
    case w of
        WrapBool True -> "yes"
        WrapBool False -> "no"

unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n -> n

testValue : String
testValue = matchBool True
```

### Single-ctor pair: Bool/Char (Bool matched, Char pollutant)
```elm
type WrapBool
    = WrapBool Bool

type WrapChar
    = WrapChar Char

matchBool : Bool -> String
matchBool b =
    let
        w = WrapBool b
    in
    case w of
        WrapBool True -> "yes"
        WrapBool False -> "no"

unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c -> c

testValue : String
testValue = matchBool True
```

### Single-ctor pair: Bool/Float (Bool matched, Float pollutant)
```elm
type WrapBool
    = WrapBool Bool

type WrapFloat
    = WrapFloat Float

matchBool : Bool -> String
matchBool b =
    let
        w = WrapBool b
    in
    case w of
        WrapBool True -> "yes"
        WrapBool False -> "no"

unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f -> f

testValue : String
testValue = matchBool True
```

### Single-ctor pair: Int/Float (both unboxed, different types)
```elm
type WrapInt
    = WrapInt Int

type WrapFloat
    = WrapFloat Float

unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n -> n

unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f -> f

testValue : Int
testValue = unwrapInt (WrapInt 42)
```

### Single-ctor pair: String/Int (String boxed, Int unboxed)
```elm
type WrapString
    = WrapString String

type WrapInt
    = WrapInt Int

unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s -> s

unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n -> n

testValue : String
testValue = unwrapString (WrapString "hello")
```

### Single-ctor pair: String/Bool (both boxed)
```elm
type WrapString
    = WrapString String

type WrapBool
    = WrapBool Bool

unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s -> s

matchBool : Bool -> String
matchBool b =
    let
        w = WrapBool b
    in
    case w of
        WrapBool True -> "yes"
        WrapBool False -> "no"

testValue : String
testValue = matchBool True
```

### Single-ctor pair: Char/Int (both unboxed, different widths)
```elm
type WrapChar
    = WrapChar Char

type WrapInt
    = WrapInt Int

unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c -> c

unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n -> n

testValue : Char
testValue = unwrapChar (WrapChar 'A')
```

### Single-ctor pair: Char/Float (both unboxed, different types)
```elm
type WrapChar
    = WrapChar Char

type WrapFloat
    = WrapFloat Float

unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c -> c

unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f -> f

testValue : Char
testValue = unwrapChar (WrapChar 'Z')
```

### Single-ctor pair: Float/Bool (Float unboxed, Bool boxed)
```elm
type WrapFloat
    = WrapFloat Float

type WrapBool
    = WrapBool Bool

unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f -> f

matchBool : Bool -> String
matchBool b =
    let
        w = WrapBool b
    in
    case w of
        WrapBool True -> "yes"
        WrapBool False -> "no"

testValue : String
testValue = matchBool False
```

---

## FunctionCases

### Identity lambda

```elm
testFn =
    \x -> x

testValue =
    testFn 1
```

### Two-argument lambda

```elm
testFn =
    \x y -> x

testValue =
    testFn 1 "a"
```

### Lambda returning tuple

```elm
testFn =
    \x y -> ( x, y )

testValue =
    testFn 1 "a"
```

### Lambda with wildcard pattern

```elm
testFn =
    \_ -> 42

testValue =
    testFn 1
```

### Call with one int arg

```elm
testValue =
    let
        f =
            \x -> x
    in
    f 42
```

### Call with two args

```elm
testValue =
    let
        f =
            \x y -> x
    in
    f 1 2
```

### Nested calls

```elm
testValue =
    let
        f =
            \x -> x
    in
    f (f 1)
```

### Partially applied two-arg function

```elm
testValue =
    let
        f =
            \x y -> ( x, y )
    in
    f 1
```

### Chained partial application

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f 1
    in
    p1 2
```

### Chained partial application (Float)

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f 1.5
    in
    p1 2
```

### Chained partial application (Char)

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f 'x'
    in
    p1 2
```

### Chained partial application (Bool)

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f True
    in
    p1 2
```

### Chained partial application (String)

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f "hello"
    in
    p1 2
```

### Chained partial application (Record)

```elm
testValue =
    let
        f =
            \a b c -> a

        p1 =
            f { x = 1, y = 2 }
    in
    p1 2
```

### Chained partial application (Custom)

```elm
type Wrapper
    = Wrapper Int

f : Wrapper -> Int -> Int -> Wrapper
f a b c =
    a

p1 : Int -> Int -> Wrapper
p1 =
    f (Wrapper 42)

testValue : Int -> Wrapper
testValue =
    p1 2
```

### Lambda returning lambda

```elm
testFn =
    \x -> \y -> y

testValue =
    testFn 1 "a"
```

### Lambda inside let inside lambda

```elm
testFn =
    \x ->
        let
            inner =
                \y -> y
        in
        inner x

testValue =
    testFn 1
```

### Multiple lambdas in tuple

```elm
testValue =
    ( \x -> x, \y -> 0 )
```

### Lambda with tuple pattern

```elm
testFn =
    \( x, y ) -> ( y, x )

testValue =
    testFn ( 1, "a" )
```

### Lambda with record pattern

```elm
testFn =
    \{ x } -> x

testValue =
    testFn { x = 1 }
```

### Lambda with mixed patterns

```elm
testFn =
    \a ( b, c ) _ -> b

testValue =
    testFn 1 ( "a", 2 ) 3
```

### Top-level function with patterns

```elm
swap ( a, b ) =
    ( b, a )

testValue =
    swap ( 1, "a" )
```

### Apply function

```elm
testValue =
    let
        apply =
            \f x -> f x
    in
    apply (\y -> y) 42
```

### Compose functions applied

```elm
testValue =
    let
        compose =
            \f g x -> f (g x)
    in
    compose (\n -> n) (\n -> n) 42
```

### Compose functions

```elm
testValue =
    let
        compose =
            \f g x -> f (g x)
    in
    compose
```

### Four-arg lambda as value

```elm
testValue =
    let
        fourArgs =
            \a b c d -> [ a, b, c, d ]
    in
    fourArgs
```

### Two-arg lambda as value

```elm
testValue =
    let
        twoArgs =
            \a b -> ( a, b )
    in
    twoArgs
```

### Multi-arg lambda partially applied

```elm
testValue =
    let
        threeArgs =
            \a b c -> [ a, b, c ]
    in
    threeArgs 1
```

### Flip as lambda value

```elm
testValue =
    let
        flip =
            \f b a -> f a b
    in
    flip
```

### Negate int

```elm
testValue =
    -42
```

### Double negate

```elm
testValue =
    -(-42)
```

### Abs positive int

```elm
testValue =
    Basics.abs 5
```

### zabs with Int (baseline)

```elm
zabs : number -> number
zabs n =
    if n < 0 then
        -n
    else
        n

testValue : Int
testValue =
    zabs 5
```

### zabs with Float (Int literal promoted)

```elm
zabs : number -> number
zabs n =
    if n < 0 then
        -n
    else
        n

testValue : Float
testValue =
    zabs 3.14
```

### comparable min with Int

```elm
zmin : comparable -> comparable -> comparable
zmin a b =
    if a < b then
        a
    else
        b

testValue : Int
testValue =
    zmin 3 5
```

### appendable concat with String

```elm
zconcat : appendable -> appendable -> appendable
zconcat a b =
    a ++ b

testValue : String
testValue =
    zconcat "hello" " world"
```

### compappend with String

```elm
zsortConcat : compappend -> compappend -> compappend
zsortConcat a b =
    if a < b then
        a ++ b
    else
        b ++ a

testValue : String
testValue =
    zsortConcat "hello" "world"
```

### unannotated comparable

```elm
zmin x y =
    if x < y then
        x
    else
        y

testValue =
    0
```

### unannotated appendable

```elm
zappend x y =
    x ++ y

testValue =
    0
```

### unannotated compappend

```elm
zsortcat x y =
    if x < y then
        x ++ y
    else
        y ++ x

testValue =
    0
```

## HigherOrderCases

### Pass lambda to function

```elm
testValue =
    let
        apply f x =
            f x
    in
    apply (\n -> n) 42
```

### Pass named function to higher-order

```elm
testValue =
    let
        identity x =
            x

        apply f x =
            f x
    in
    apply identity 42
```

### Map-like function

```elm
testValue =
    let
        myMap f list =
            case list of
                [] ->
                    []

                h :: t ->
                    [ f h ]
    in
    myMap (\x -> ( x, x )) [ 1, 2 ]
```

### Filter-like function

```elm
testValue =
    let
        myFilter pred list =
            case list of
                [] ->
                    []

                h :: t ->
                    if pred h then
                        [ h ]
                    else
                        []
    in
    myFilter (\_ -> True) [ 1 ]
```

### Pass accessor function

```elm
testValue =
    let
        apply f x =
            f x
    in
    apply .name { name = "test" }
```

### Function returning lambda

```elm
testValue =
    let
        makeAdder n =
            \x -> ( n, x )
    in
    (makeAdder 5) 3
```

### Curried function

```elm
testValue =
    let
        add a =
            \b -> ( a, b )
    in
    add 1 2
```

### Triple nested function

```elm
testValue =
    let
        triple a =
            \b ->
                \c ->
                    [ a, b, c ]
    in
    triple 1 2 3
```

### Function factory

```elm
testValue =
    let
        makeTransform factor =
            \x -> ( x, factor )

        double =
            makeTransform 2
    in
    double 5
```

### Return lambda based on condition

```elm
testValue =
    let
        choose flag =
            if flag then
                \x -> x
            else
                \_ -> 0
    in
    (choose True) 42
```

### Closure over multiple variables

```elm
testValue =
    let
        makeClosure a b c =
            \x -> [ a, b, c, x ]
    in
    makeClosure 1 2 3 4
```

### Compose two functions

```elm
testValue =
    let
        compose f g =
            \x -> f (g x)
    in
    (compose (\n -> ( n, 0 )) (\n -> n)) 42
```

### Flip function

```elm
testValue =
    let
        flip f =
            \a b -> f b a
    in
    (flip (\x y -> ( x, y ))) 1 2
```

### Const function

```elm
testValue =
    let
        const a =
            \_ -> a
    in
    (const 42) "ignored"
```

### Identity composition

```elm
testValue =
    let
        identity x =
            x

        compose f g =
            \x -> f (g x)
    in
    (compose identity identity) 1
```

### Pipe-like apply

```elm
testValue =
    let
        pipe x f =
            f x
    in
    pipe 5 (\n -> ( n, n ))
```

### Partially applied function stored

```elm
testValue =
    let
        add a b =
            ( a, b )

        add5 =
            add 5
    in
    add5 3
```

### Multiple partial applications

```elm
testValue =
    let
        fn a b c =
            [ a, b, c ]

        p1 =
            fn 1

        p2 =
            p1 2
    in
    p2 3
```

### Partial application in list

```elm
testValue =
    let
        add a b =
            ( a, b )
    in
    [ add 1, add 2, add 3 ]
```

### Partial application in record

```elm
testValue =
    let
        mult a b =
            ( a, b )
    in
    { double = mult 2, triple = mult 3 }
```

### Identity used with different types

```elm
testValue =
    let
        id x =
            x
    in
    ( id 1, id "hello" )
```

### Apply used with different function types

```elm
testValue =
    let
        apply f x =
            f x

        intId n =
            n

        strId s =
            s
    in
    ( apply intId 1, apply strId "hi" )
```

### Higher-order function preserving polymorphism

```elm
testValue =
    let
        twice f x =
            f (f x)

        id y =
            y
    in
    ( twice id 1, twice id "hi" )
```

### Higher-order with tuple pattern

```elm
testValue =
    let
        applyToPair f ( a, b ) =
            f a b
    in
    applyToPair (\x y -> ( x, y )) ( 1, 2 )
```

### Higher-order with record pattern

```elm
testValue =
    let
        transformRecord f { value } =
            { value = f value }
    in
    transformRecord (\x -> ( x, x )) { value = 21 }
```

### Higher-order with list pattern

```elm
testValue =
    let
        mapHead f (h :: t) =
            [ f h ]
    in
    mapHead (\x -> x) [ 1, 2 ]
```

### Higher-order with alias pattern

```elm
testValue =
    let
        withOriginal f (x as original) =
            ( f x, original )
    in
    withOriginal (\n -> n) 42
```

### Case returns curried binary operator

```elm
type Op
    = Add
    | Sub
    | Mul

getOp : Op -> Int -> Int -> Int
getOp op =
    case op of
        Add ->
            \a b -> a + b

        Sub ->
            \a b -> a - b

        Mul ->
            \a b -> a * b

applyOp : (Op -> Int -> Int -> Int) -> Op -> Int -> Int -> Int
applyOp f op a b =
    f op a b

testValue : Int
testValue =
    applyOp getOp Add 3 4
```

### Case returns curried ternary function

```elm
type Mode
    = First
    | Second
    | Third

choose : Mode -> Int -> Int -> Int -> Int
choose mode =
    case mode of
        First ->
            \a b c -> a

        Second ->
            \a b c -> b

        Third ->
            \a b c -> c

applyChoice : (Mode -> Int -> Int -> Int -> Int) -> Mode -> Int -> Int -> Int -> Int
applyChoice f mode a b c =
    f mode a b c

testValue : Int
testValue =
    applyChoice choose First 10 20 30
```

### Case returns differently staged lambdas

```elm
type Selector
    = UseFlat
    | UseNested

selectFn : Selector -> Int -> Int -> Int -> Int
selectFn sel a =
    case sel of
        UseFlat ->
            \b c -> a + b + c

        UseNested ->
            \b -> \c -> a + b + c

testValue : Int
testValue =
    selectFn UseFlat 1 2 3
```

## ClosureCases

### Closure over single local

```elm
makeAdder : Int -> Int -> Int
makeAdder x =
    \y -> x + y

testValue : Int
testValue =
    (makeAdder 5) 10
```

### Closure over two locals

```elm
makeCombiner : Int -> Int -> Int -> Int
makeCombiner a b =
    \x -> a * x + b

testValue : Int
testValue =
    (makeCombiner 2 3) 5
```

### Closure in let binding

```elm
letClosure : Int -> Int
letClosure n =
    let
        f =
            \x -> x + n
    in
    f 10

testValue : Int
testValue =
    letClosure 5
```

### Closure as return value

```elm
makeMultiplier : Int -> Int -> Int
makeMultiplier factor =
    \x -> x * factor

applyTwice : (Int -> Int) -> Int -> Int
applyTwice f x =
    f (f x)

testValue : Int
testValue =
    applyTwice (makeMultiplier 2) 3
```

### Closure applied immediately

```elm
immediate : Int -> Int
immediate n =
    (\x -> x + n) 10

testValue : Int
testValue =
    immediate 5
```

### Double nested closure

```elm
makeNestedAdder : Int -> Int -> Int -> Int
makeNestedAdder x =
    \y -> \z -> x + y + z

testValue : Int
testValue =
    ((makeNestedAdder 1) 2) 3
```

### Closure returning closure

```elm
makeClosureFactory : Int -> Int -> Int -> Int
makeClosureFactory base =
    \multiplier -> \x -> base + multiplier * x

testValue : Int
testValue =
    ((makeClosureFactory 10) 2) 5
```

### Nested let closures

```elm
nestedLets : Int -> Int
nestedLets n =
    let
        outer =
            \x ->
                let
                    inner =
                        \y -> x + y + n
                in
                inner 10
    in
    outer 5

testValue : Int
testValue =
    nestedLets 3
```

### Triple nested closure

```elm
tripleNested : Int -> Int -> Int -> Int -> Int
tripleNested a =
    \b -> \c -> \d -> a + b + c + d

testValue : Int
testValue =
    (((tripleNested 1) 2) 3) 4
```

### Closure in case branch

```elm
type Maybe a
    = Just a
    | Nothing

caseClosure : Maybe Int -> Int -> Int
caseClosure m =
    case m of
        Just n ->
            \x -> x + n

        Nothing ->
            \x -> x

testValue : Int
testValue =
    (caseClosure (Just 5)) 10
```

### Different closures per branch

```elm
opClosure : Int -> Int -> Int
opClosure op =
    case op of
        n ->
            if n == 0 then
                \x -> x + 1
            else if n == 1 then
                \x -> x * 2
            else
                \x -> x

testValue : Int
testValue =
    (opClosure 1) 10
```

### Closure capturing scrutinee

```elm
captureScrutinee : List Int -> Int -> Int
captureScrutinee xs =
    case xs of
        [] ->
            \x -> x

        h :: _ ->
            \x -> x + h

testValue : Int
testValue =
    (captureScrutinee [ 5, 6 ]) 10
```

### Closure in Maybe case

```elm
type Maybe a
    = Just a
    | Nothing

withDefault : Int -> Maybe Int -> Int -> Int
withDefault default m =
    case m of
        Just val ->
            \x -> x + val

        Nothing ->
            \x -> x + default

testValue : Int
testValue =
    (withDefault 0 Nothing) 10
```

### Closure capturing record

```elm
closureWithRecord : { x : Int, y : Int } -> Int -> Int
closureWithRecord rec =
    \n -> rec.x + rec.y + n

testValue : Int
testValue =
    (closureWithRecord { x = 1, y = 2 }) 3
```

### Closure capturing tuple

```elm
closureWithTuple : ( Int, Int ) -> Int -> Int
closureWithTuple pair =
    case pair of
        ( a, b ) ->
            \n -> a + b + n

testValue : Int
testValue =
    (closureWithTuple ( 1, 2 )) 3
```

### Closure capturing list head

```elm
closureFromList : List Int -> Int -> Int
closureFromList xs =
    case xs of
        [] ->
            \x -> x

        h :: _ ->
            \x -> x * h

testValue : Int
testValue =
    (closureFromList [ 3, 4 ]) 10
```

### Closure capturing multiple types

```elm
multiCapture : Int -> List Int -> Int -> Int
multiCapture base xs =
    case xs of
        [] ->
            \x -> x + base

        h :: _ ->
            \x -> x + base + h

testValue : Int
testValue =
    (multiCapture 10 [ 5, 6 ]) 100
```

### Closure in recursive function

```elm
mapList : (Int -> Int) -> List Int -> List Int
mapList f xs =
    case xs of
        [] ->
            []

        h :: t ->
            f h :: mapList f t

addToAll : Int -> List Int -> List Int
addToAll n xs =
    mapList (\x -> x + n) xs

testValue : List Int
testValue =
    addToAll 10 [ 1, 2, 3 ]
```

### Recursive closure

```elm
recursiveLet : Int -> Int
recursiveLet n =
    let
        go acc m =
            if m <= 0 then
                acc
            else
                go (acc + m) (m - 1)
    in
    go 0 n

testValue : Int
testValue =
    recursiveLet 5
```

### Closure with tail recursion

```elm
tailRecWithClosure : Int -> Int -> Int
tailRecWithClosure factor n =
    let
        go acc m =
            if m <= 0 then
                acc
            else
                go (acc + factor) (m - 1)
    in
    go 0 n

testValue : Int
testValue =
    tailRecWithClosure 10 5
```

### Hetero closure: Int vs Float capture

```elm
addN : Int -> Int -> Int
addN n x =
    n + x

mulF : Float -> Int -> Int
mulF f x =
    Basics.truncate (f * Basics.toFloat x)

testValue : Int
testValue =
    let
        f =
            if True then
                addN 10
            else
                mulF 2.5
    in
    f 3
```

### Hetero closure: boxed vs unboxed capture

```elm
type Shape
    = Circle
    | Square

shapeBonus : Shape -> Int -> Int
shapeBonus shape x =
    case shape of
        Circle ->
            x + 10

        Square ->
            x + 20

addN : Int -> Int -> Int
addN n x =
    n + x

testValue : Int
testValue =
    let
        f =
            if True then
                shapeBonus Circle
            else
                addN 5
    in
    f 3
```

### Closure captures variable used only in single-ctor destruct

```elm
type Wrapper a
    = Wrap a

unwrapLater : Wrapper Int -> Int -> Int
unwrapLater w =
    \dummy ->
        case w of
            Wrap x ->
                x

testValue : Int
testValue =
    (unwrapLater (Wrap 42)) 0
```

### Closure captures Maybe variable used only in case destruct

```elm
type Maybe a
    = Just a
    | Nothing

toLabel : Maybe String -> Int -> String
toLabel m =
    \dummy ->
        case m of
            Just s ->
                s

            Nothing ->
                "none"

testValue : String
testValue =
    (toLabel (Just "hello")) 0
```

### Closure captures variable used only as case scrutinee (custom type)

```elm
type Intensity
    = Dull
    | Vivid

pickByIntensity : Intensity -> Int -> Int -> Int
pickByIntensity intensity dullVal vividVal =
    let
        pick a b =
            case intensity of
                Dull ->
                    a

                Vivid ->
                    b
    in
    pick dullVal vividVal

testValue : Int
testValue =
    pickByIntensity Vivid 1 2
```

### Closure captures variable used only as case scrutinee (Int)

```elm
chooseByN : Int -> Int -> Int -> Int
chooseByN n a b =
    let
        pick x y =
            case n of
                0 ->
                    x

                _ ->
                    y
    in
    pick a b

testValue : Int
testValue =
    chooseByN 0 10 20
```

### Closure captures variable used only as case scrutinee (Bool)

```elm
pickByBool : Bool -> Int -> Int -> Int
pickByBool flag a b =
    let
        pick x y =
            case flag of
                True ->
                    x

                False ->
                    y
    in
    pick a b

testValue : Int
testValue =
    pickByBool True 10 20
```

### Nested closure captures case scrutinee from outer scope

```elm
type Dir
    = Left
    | Right

nestedPick : Dir -> Int -> Int -> Int
nestedPick dir a b =
    let
        outer x y =
            let
                inner p q =
                    case dir of
                        Left ->
                            p

                        Right ->
                            q
            in
            inner x y
    in
    outer a b

testValue : Int
testValue =
    nestedPick Right 10 20
```

## ClosureAbiBranchCases

### Apply different lambdas

```elm
apply : (Int -> Int) -> Int -> Int
apply f x =
    f x

testValue : Int
testValue =
    let
        a =
            apply (\n -> n + 1) 5

        b =
            apply (\n -> n * 2) 5
    in
    a + b
```

### Case returning lambdas

```elm
picker : Bool -> Int -> Int
picker b =
    if b then
        \x -> x + 10
    else
        \x -> x * 10

testValue : Int
testValue =
    let
        f =
            picker True
    in
    f 3
```

### Higher-order called at multiple sites

```elm
applyTwice : (Int -> Int) -> Int -> Int
applyTwice f x =
    f (f x)

testValue : Int
testValue =
    let
        a =
            applyTwice (\n -> n + 1) 0

        b =
            applyTwice (\n -> n * 3) 1
    in
    a + b
```

### Lambda capturing different vars

```elm
makeAdder : Int -> Int -> Int
makeAdder n =
    \x -> x + n

testValue : Int
testValue =
    let
        add1 =
            makeAdder 1

        add10 =
            makeAdder 10

        a =
            add1 5

        b =
            add10 5
    in
    a + b
```

### If returning closures

```elm
choose : Bool -> Int -> Int -> Int -> Int
choose flag a b =
    if flag then
        \x -> x + a
    else
        \x -> x + b

testValue : Int
testValue =
    (choose True 100 200) 5
```

### Custom type with function field

```elm
type Op
    = Op (Int -> Int)

runOp : Op -> Int
runOp op =
    case op of
        Op f ->
            f 10

testValue : Int
testValue =
    let
        a =
            runOp (Op (\x -> x + 1))

        b =
            runOp (Op (\x -> x * 2))
    in
    a + b
```

---

# Part 3: Let, LetRec, LetDestruct, LetDestructFn, AsPattern, PatternMatching, PatternArg

## LetCases

### Let with single int binding
```elm
testValue =
    let
        x = 42
    in
    x
```

### Let with unit body
```elm
testValue =
    let
        x = 42
    in
    ()
```

### Let with two bindings
```elm
testValue =
    let
        x = 1
        y = 2
    in
    ( x, y )
```

### Let with binding using previous binding
```elm
testValue =
    let
        x = 1
        y = ( x, 2 )
    in
    y
```

### Let with chained references
```elm
testValue =
    let
        a = 1
        b = a
        c = b
    in
    c
```

### Let inside let
```elm
testValue =
    let
        x = 1
    in
    let
        y = 2
    in
    y
```

### Let in binding value
```elm
testValue =
    let
        x =
            let
                inner = 42
            in
            inner
    in
    x
```

### Multiple nested lets
```elm
testValue =
    ( let
        a = 1
      in
      a
    , let
        b = 2
      in
      b
    )
```

### Let inside list inside let
```elm
testValue =
    let
        x = 0
    in
    [ 1
    , let
        y = 2
      in
      y
    , 3
    ]
```

### Let with function
```elm
testValue =
    let
        f x = x
    in
    f 42
```

### Let with lambda binding
```elm
testValue =
    let
        f = \x -> x
    in
    f 42
```

### Let with multiple functions
```elm
testValue =
    let
        identity x = x
        const x y = x
    in
    ( identity 1, const 2 3 )
```

### Let with function calling another function
```elm
testValue =
    let
        double x = ( x, x )
        doubleTwice y = double (double y)
    in
    doubleTwice 1
```

### Let with record binding
```elm
testValue =
    let
        r = { x = 1, y = 2 }
    in
    r.x
```

### Let with tuple binding
```elm
testValue =
    let
        pair = ( 1, "one" )
    in
    pair
```

### Let with list binding
```elm
testValue =
    let
        items = [ 1, 2, 3 ]
    in
    items
```

---

## LetRecCases

### Simple recursive function
```elm
testValue =
    let
        f n =
            if True then
                1
            else
                f 0
    in
    f 5
```

### Recursive function with case
```elm
testValue =
    let
        len list =
            case list of
                [] ->
                    0

                h :: t ->
                    len t
    in
    len [ 1, 2 ]
```

### Recursive function with multiple args
```elm
testValue =
    let
        f a b =
            if True then
                b
            else
                f b a
    in
    f 1 2
```

### Recursive function with list accumulator
```elm
testValue =
    let
        collect n acc =
            if True then
                acc
            else
                collect 0 [ n ]
    in
    collect 5 []
```

### Two mutually recursive functions
```elm
testValue =
    let
        isEven n =
            if True then
                True
            else
                isOdd 0

        isOdd n =
            if True then
                False
            else
                isEven 0
    in
    isEven 4
```

### Nested mutually recursive
```elm
testValue =
    let
        outer n =
            let
                inner1 x =
                    if True then
                        0
                    else
                        inner2 x

                inner2 x =
                    inner1 x
            in
            inner1 n
    in
    outer 5
```

### Recursive with tuple pattern
```elm
testValue =
    let
        process ( a, b ) =
            if True then
                0
            else
                process ( b, a )
    in
    process ( 1, 2 )
```

### Recursive with cons pattern
```elm
testValue =
    let
        sum list =
            case list of
                [] ->
                    0

                h :: t ->
                    sum t
    in
    sum [ 1, 2, 3 ]
```

### Recursive with alias pattern
```elm
testValue =
    let
        process (x as whole) =
            if True then
                ( x, whole )
            else
                process x
    in
    process 5
```

### Two recursive functions with fixed values
```elm
testValue =
    let
        f n =
            if True then
                1
            else
                f 0

        g n =
            if True then
                2
            else
                g 0
    in
    ( f 1, g 2 )
```

---

## LetDestructCases

### Destruct 2-tuple
```elm
testValue =
    let
        ( a, b ) = ( 1, 2 )
    in
    a
```

### Destruct 3-tuple
```elm
testValue =
    let
        ( a, b, c ) = ( 1, 2, 3 )
    in
    b
```

### Destruct tuple with wildcard
```elm
testValue =
    let
        ( x, _ ) = ( 1, 2 )
    in
    x
```

### Multiple tuple destructs
```elm
testValue =
    let
        ( a, b ) = ( 1, 2 )
        ( c, d ) = ( 3, 4 )
    in
    [ a, b, c, d ]
```

### Destruct single field record
```elm
testValue =
    let
        { x } = { x = 42 }
    in
    x
```

### Destruct multi-field record
```elm
testValue =
    let
        { x, y } = { x = 1, y = 2 }
    in
    ( x, y )
```

### Destruct partial record
```elm
testValue =
    let
        { a, c } = { a = 1, b = 2, c = 3 }
    in
    ( a, c )
```

### Multiple record destructs
```elm
testValue =
    let
        { x } = { x = 1 }
        { y } = { y = 2 }
    in
    ( x, y )
```

### Destruct cons pattern
```elm
testValue =
    let
        head :: tail = [ 1, 2, 3 ]
    in
    head
```

### Destruct fixed list pattern
```elm
testValue =
    let
        [ a, b ] = [ 1, 2 ]
    in
    ( a, b )
```

### Destruct nested cons
```elm
testValue =
    let
        a :: b :: rest = [ 1, 2, 3 ]
    in
    ( a, b )
```

### Destruct tuple of tuples
```elm
testValue =
    let
        ( ( a, b ), ( c, d ) ) = ( ( 1, 2 ), ( 3, 4 ) )
    in
    [ a, b, c, d ]
```

### Destruct tuple with record
```elm
testValue =
    let
        ( { x }, y ) = ( { x = 1 }, 2 )
    in
    ( x, y )
```

### Deeply nested destruct
```elm
testValue =
    let
        ( ( a, ( b, c ) ), d ) = ( ( 1, ( 2, 3 ) ), 4 )
    in
    [ a, b, c, d ]
```

### Triple nested destruct
```elm
testValue =
    let
        ( ( a, b ), ( c, d ), ( e, f ) ) = ( ( 1, 2 ), ( 3, 4 ), ( 5, 6 ) )
    in
    [ a, b, c, d, e, f ]
```

### Destruct with simple alias
```elm
testValue =
    let
        (( a, b ) as whole) = ( 1, 2 )
    in
    ( whole, a )
```

### Destruct with nested alias
```elm
testValue =
    let
        ( (( a, b ) as inner), c ) = ( ( 1, 2 ), 3 )
    in
    ( inner, a )
```

### Mixed destruct and define
```elm
testValue =
    let
        x = 1
        ( a, b ) = ( 2, 3 )
        y = 4
    in
    [ x, a, b, y ]
```

### Destruct in nested let
```elm
testValue =
    let
        pair = ( 1, 2 )
    in
    let
        ( a, b ) = pair
    in
    ( b, a )
```

### Chain of destructs
```elm
testValue =
    let
        ( a, rest1 ) = ( 1, ( 2, 3 ) )
        ( b, c ) = rest1
    in
    [ a, b, c ]
```

### Destruct with function call result
```elm
testValue =
    let
        makePair = ( 1, 2 )
        ( a, b ) = makePair
    in
    ( a, b )
```

---

## LetDestructFnCases

### Destruct tuple of lambdas from case
```elm
type Loc
    = Doc
    | Div


processGesture : Loc -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
processGesture loc rec =
    let
        ( get, set ) =
            case loc of
                Doc ->
                    ( .a, \x m -> { m | a = x } )

                Div ->
                    ( .b, \x m -> { m | b = x } )
    in
    ( get rec, set 99 rec )


testValue : ( Int, { a : Int, b : Int } )
testValue =
    processGesture Doc { a = 1, b = 2 }
```

### Destruct tuple of accessors from case
```elm
type Loc
    = Doc
    | Div


choose : Loc -> { a : Int, b : Int } -> ( Int, Int )
choose loc rec =
    let
        ( fst, snd ) =
            case loc of
                Doc ->
                    ( .a, .b )

                Div ->
                    ( .b, .a )
    in
    ( fst rec, snd rec )


testValue : ( Int, Int )
testValue =
    choose Doc { a = 10, b = 20 }
```

### Destruct tuple of lambdas direct
```elm
applyBoth : { a : Int, b : Int } -> ( Int, Int )
applyBoth rec =
    let
        ( get, transform ) =
            ( .a, \x -> x )
    in
    ( get rec, transform (get rec) )


testValue : ( Int, Int )
testValue =
    applyBoth { a = 5, b = 10 }
```

### Destruct tuple of accessor and lambda from case
```elm
getSet : Bool -> { x : Int } -> ( Int, { x : Int } )
getSet flag rec =
    let
        ( getter, setter ) =
            if flag then
                ( .x, \v r -> { r | x = v } )
            else
                ( .x, \v r -> { r | x = v + 1 } )
    in
    ( getter rec, setter 42 rec )


testValue : ( Int, { x : Int } )
testValue =
    getSet True { x = 7 }
```

### Destruct pair of lambdas used in body
```elm
type Dir
    = Left
    | Right


transform : Dir -> Int -> Int -> ( Int, Int )
transform dir a b =
    let
        ( f, g ) =
            case dir of
                Left ->
                    ( \x -> x + 1, \x -> x * 2 )

                Right ->
                    ( \x -> x * 3, \x -> x + 4 )
    in
    ( f a, g b )


testValue : ( Int, Int )
testValue =
    transform Left 10 20
```

---

## AsPatternCases

### Alias on variable
```elm
dup (x as y) =
    ( x, y )


testValue =
    dup 1
```

### Alias on wildcard
```elm
capture (_ as x) =
    x


testValue =
    capture 1
```

### Multiple aliases
```elm
both (a as x) (b as y) =
    ( x, y )


testValue =
    both 1 "a"
```

### Alias in lambda
```elm
testValue =
    (\(x as whole) -> ( x, whole )) 1
```

### Alias on 2-tuple
```elm
withPair (( a, b ) as pair) =
    ( pair, a )


testValue =
    withPair ( 1, "a" )
```

### Alias on 3-tuple
```elm
withTriple (( a, b, c ) as triple) =
    triple


testValue =
    withTriple ( 1, "a", 2 )
```

### Nested alias in tuple
```elm
parts ( (x as first), (y as second) ) =
    [ first, second ]


testValue =
    parts ( 1, 2 )
```

### Alias on nested tuple
```elm
deep (( ( a, b ), c ) as whole) =
    whole


testValue =
    deep ( ( 1, "a" ), 2 )
```

### Alias on record pattern
```elm
withRecord ({ x, y } as point) =
    ( point, x )


testValue =
    withRecord { x = 1, y = "a" }
```

### Multiple record aliases
```elm
combine ({ a } as r1) ({ b } as r2) =
    ( r1, r2 )


testValue =
    combine { a = 1 } { b = "a" }
```

### Alias on record with many fields
```elm
allFields ({ a, b, c, d } as rec) =
    rec


testValue =
    allFields { a = 1, b = "a", c = 2, d = "b" }
```

### Alias on cons pattern
```elm
withList ((h :: t) as list) =
    ( list, h )


testValue =
    withList [ 1, 2 ]
```

### Alias on fixed list pattern
```elm
pairList ([ a, b ] as both) =
    both


testValue =
    pairList [ 1, 2 ]
```

### Nested alias in list
```elm
parts ((h as head) :: (t as tail)) =
    ( head, tail )


testValue =
    parts [ 1, 2 ]
```

### Alias on nested cons
```elm
twoOrMore ((a :: b :: rest) as list) =
    list


testValue =
    twoOrMore [ 1, 2, 3 ]
```

### Multiple levels of alias
```elm
levels ((x as inner) as outer) =
    [ x, inner, outer ]


testValue =
    levels 1
```

### Alias in deeply nested structure
```elm
deep ( (( a, b ) as inner), c ) =
    ( inner, a )


testValue =
    deep ( ( 1, "a" ), 2 )
```

### Mixed nested aliases
```elm
mixed (( { x }, (h :: _) as list ) as all) =
    all


testValue =
    mixed ( { x = 1 }, [ 1, 2 ] )
```

### Alias in let destruct
```elm
testValue =
    let
        (( a, b ) as pair) = ( 1, 2 )
    in
    pair
```

### Alias used in function body
```elm
testValue =
    let
        process (x as original) =
            ( original, x )
    in
    process 42
```

### Alias with value
```elm
testValue =
    case 42 of
        (x as val) ->
            ( x, val )
```

---

## PatternMatchingCases

### Simple char pattern
```elm
charName : Char -> String
charName c =
    case c of
        'a' ->
            "letter a"

        'b' ->
            "letter b"

        _ ->
            "other"


testValue : String
testValue =
    charName 'a'
```

### Multiple char patterns
```elm
charType : Char -> Int
charType c =
    case c of
        '0' ->
            0

        '1' ->
            1

        '2' ->
            2

        '3' ->
            3

        _ ->
            -1


testValue : Int
testValue =
    charType '2'
```

### Char pattern with fallback
```elm
isSpecial : Char -> Bool
isSpecial c =
    case c of
        '@' ->
            True

        '#' ->
            True

        '$' ->
            True

        _ ->
            False


testValue : Bool
testValue =
    isSpecial '@'
```

### Vowel detection
```elm
isVowel : Char -> Bool
isVowel c =
    case c of
        'a' ->
            True

        'e' ->
            True

        'i' ->
            True

        'o' ->
            True

        'u' ->
            True

        _ ->
            False


testValue : Bool
testValue =
    isVowel 'e'
```

### Digit char pattern
```elm
digitToInt : Char -> Int
digitToInt c =
    case c of
        '0' ->
            0

        '1' ->
            1

        '2' ->
            2

        '3' ->
            3

        '4' ->
            4

        '5' ->
            5

        '6' ->
            6

        '7' ->
            7

        '8' ->
            8

        '9' ->
            9

        _ ->
            -1


testValue : Int
testValue =
    digitToInt '7'
```

### Simple string pattern
```elm
greet : String -> String
greet name =
    case name of
        "Alice" ->
            "Hello Alice!"

        "Bob" ->
            "Hi Bob!"

        _ ->
            "Hello stranger"


testValue : String
testValue =
    greet "Alice"
```

### Multiple string patterns
```elm
dayNumber : String -> Int
dayNumber day =
    case day of
        "Monday" ->
            1

        "Tuesday" ->
            2

        "Wednesday" ->
            3

        "Thursday" ->
            4

        "Friday" ->
            5

        "Saturday" ->
            6

        "Sunday" ->
            7

        _ ->
            0


testValue : Int
testValue =
    dayNumber "Wednesday"
```

### Greeting pattern
```elm
respond : String -> String
respond greeting =
    case greeting of
        "hello" ->
            "Hello to you too!"

        "hi" ->
            "Hi there!"

        "hey" ->
            "Hey!"

        "goodbye" ->
            "Goodbye!"

        _ ->
            "I don't understand"


testValue : String
testValue =
    respond "hello"
```

### Command pattern
```elm
executeCommand : String -> Int
executeCommand cmd =
    case cmd of
        "start" ->
            1

        "stop" ->
            2

        "restart" ->
            3

        "status" ->
            4

        _ ->
            0


testValue : Int
testValue =
    executeCommand "restart"
```

### Nested constructor pattern
```elm
type Tree
    = Leaf Int
    | Node Tree Tree


sumTree : Tree -> Int
sumTree tree =
    case tree of
        Leaf n ->
            n

        Node left right ->
            sumTree left + sumTree right


testValue : Int
testValue =
    sumTree (Node (Leaf 1) (Leaf 2))
```

### Tree depth with nested patterns
```elm
type Tree
    = Leaf Int
    | Node Tree Tree


depth : Tree -> Int
depth tree =
    case tree of
        Leaf _ ->
            1

        Node left right ->
            1 + max (depth left) (depth right)


testValue : Int
testValue =
    depth (Node (Node (Leaf 1) (Leaf 2)) (Leaf 3))
```

### Double nested pattern
```elm
type Wrapper
    = Wrap Int


type Container
    = Container Wrapper


extract : Container -> Int
extract container =
    case container of
        Container (Wrap n) ->
            n


testValue : Int
testValue =
    extract (Container (Wrap 42))
```

### Pattern in pattern
```elm
type Pair
    = Pair Int Int


type Box
    = Box Pair


sumBox : Box -> Int
sumBox box =
    case box of
        Box (Pair a b) ->
            a + b


testValue : Int
testValue =
    sumBox (Box (Pair 10 20))
```

### Wildcard fallback
```elm
type Status
    = Success
    | Error
    | Pending
    | Unknown


isSuccess : Status -> Bool
isSuccess status =
    case status of
        Success ->
            True

        _ ->
            False


testValue : Bool
testValue =
    isSuccess Success
```

### Variable capture fallback
```elm
classify : Int -> String
classify n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"

        x ->
            if x > 0 then
                "positive"
            else
                "negative"


testValue : String
testValue =
    classify 5
```

### Multiple specific then fallback
```elm
fibBase : Int -> Int
fibBase n =
    case n of
        0 ->
            0

        1 ->
            1

        2 ->
            1

        3 ->
            2

        4 ->
            3

        5 ->
            5

        _ ->
            -1


testValue : Int
testValue =
    fibBase 4
```

### Conditional in fallback
```elm
clampedValue : Int -> Int
clampedValue n =
    case n of
        0 ->
            0

        x ->
            if x < 0 then
                0
            else if x > 100 then
                100
            else
                x


testValue : Int
testValue =
    clampedValue 150
```

### Simple tuple pattern
```elm
sumPair : ( Int, Int ) -> Int
sumPair pair =
    case pair of
        ( a, b ) ->
            a + b


testValue : Int
testValue =
    sumPair ( 3, 4 )
```

### Tuple with wildcard
```elm
getFirst : ( Int, Int ) -> Int
getFirst pair =
    case pair of
        ( a, _ ) ->
            a


testValue : Int
testValue =
    getFirst ( 10, 20 )
```

### Nested tuple pattern
```elm
sumNested : ( ( Int, Int ), Int ) -> Int
sumNested nested =
    case nested of
        ( ( a, b ), c ) ->
            a + b + c


testValue : Int
testValue =
    sumNested ( ( 1, 2 ), 3 )
```

### Triple pattern
```elm
sumTriple : Int -> Int -> Int -> Int
sumTriple a b c =
    a + b + c


testValue : Int
testValue =
    sumTriple 1 2 3
```

### Empty list pattern
```elm
isEmpty : List Int -> Bool
isEmpty xs =
    case xs of
        [] ->
            True

        _ ->
            False


testValue : Bool
testValue =
    isEmpty []
```

### Single element pattern
```elm
isSingleton : List Int -> Bool
isSingleton xs =
    case xs of
        _ :: [] ->
            True

        _ ->
            False


testValue : Bool
testValue =
    isSingleton [ 1 ]
```

### Two element pattern
```elm
sumTwo : List Int -> Int
sumTwo xs =
    case xs of
        a :: b :: [] ->
            a + b

        _ ->
            0


testValue : Int
testValue =
    sumTwo [ 3, 4 ]
```

### Head tail pattern
```elm
listLength : List Int -> Int
listLength xs =
    case xs of
        [] ->
            0

        _ :: rest ->
            1 + listLength rest


testValue : Int
testValue =
    listLength [ 1, 2, 3 ]
```

### Nested list pattern
```elm
flattenFirst : List (List Int) -> List Int
flattenFirst xss =
    case xss of
        [] ->
            []

        first :: _ ->
            first


testValue : List Int
testValue =
    flattenFirst [ [ 1, 2 ], [ 3, 4 ] ]
```

---

## PatternArgCases

### Single variable pattern
```elm
identity x =
    x


testValue =
    identity 1
```

### Two variable patterns
```elm
first x y =
    x


testValue =
    first 1 "hello"
```

### Three variable patterns
```elm
second a b c =
    b


testValue =
    second 1 "hello" 3.14
```

### Variable pattern returning tuple
```elm
swap x y =
    ( y, x )


testValue =
    swap 1 "hello"
```

### Variable pattern returning list
```elm
toList x =
    [ x ]


testValue =
    toList 1
```

### Single wildcard pattern
```elm
const _ =
    42


testValue =
    const 1
```

### Wildcard with variable
```elm
const x _ =
    x


testValue =
    const 1 "hello"
```

### Multiple wildcards
```elm
zero _ _ _ =
    0


testValue =
    zero 1 "hello" 3.14
```

### Wildcard in lambda
```elm
testValue =
    \_ -> 0
```

### 2-tuple pattern
```elm
fst ( x, y ) =
    x


testValue =
    fst ( 1, "hello" )
```

### 3-tuple pattern
```elm
snd3 ( a, b, c ) =
    b


testValue =
    snd3 ( 1, "hello", 3.14 )
```

### Tuple pattern with wildcard
```elm
snd ( _, y ) =
    y


testValue =
    snd ( 1, "hello" )
```

### Nested tuple pattern
```elm
deep ( ( a, b ), c ) =
    a


testValue =
    deep ( ( 1, "hello" ), 3.14 )
```

### Tuple pattern in lambda
```elm
testValue =
    \( x, y ) -> x
```

### Multiple tuple pattern args
```elm
addPairs ( a, b ) ( c, d ) =
    ( a, c )


testValue =
    addPairs ( 1, "hello" ) ( 3.14, 2 )
```

### Single field record pattern
```elm
getX { x } =
    x


testValue =
    getX { x = 1 }
```

### Multi-field record pattern
```elm
getXY { x, y } =
    ( x, y )


testValue =
    getXY { x = 1, y = "hello" }
```

### Record pattern in lambda
```elm
testValue =
    \{ name } -> name
```

### Record pattern with many fields
```elm
getAll { a, b, c, d, e } =
    a


testValue =
    getAll { a = 1, b = 2, c = 3, d = 4, e = 5 }
```

### Multiple record pattern args
```elm
combine { x } { y } =
    ( x, y )


testValue =
    combine { x = 1 } { y = "hello" }
```

### Record pattern with variable
```elm
extract { value } default =
    value


testValue =
    extract { value = 1 } "default"
```

### Cons pattern
```elm
head (h :: t) =
    h


testValue =
    head [ 1, 2 ]
```

### Fixed list pattern
```elm
firstTwo [ a, b ] =
    ( a, b )


testValue =
    firstTwo [ 1, 2 ]
```

### Nested cons pattern
```elm
secondElem (_ :: x :: _) =
    x


testValue =
    secondElem [ 1, 2, 3 ]
```

### List pattern in lambda
```elm
testValue =
    \(x :: _) -> x
```

### Int literal pattern
```elm
isZero 0 =
    "zero"


testValue =
    isZero 0
```

### String literal pattern
```elm
greet "hello" =
    "hi"


testValue =
    greet "hello"
```

### Unit pattern
```elm
unit () =
    0


testValue =
    unit ()
```

### Multiple literal patterns
```elm
match 0 "" =
    0


testValue =
    match 0 ""
```

### Deeply nested tuple
```elm
extract ( ( a, b ), ( c, d ) ) =
    a


testValue =
    extract ( ( 1, "hello" ), ( 3.14, 2 ) )
```

### Mixed nested patterns
```elm
mixed ( { x }, h :: _ ) =
    ( x, h )


testValue =
    mixed ( { x = 1 }, [ "hello", "world" ] )
```

### Triple nested patterns
```elm
complex ( ( a, b ), { x, y }, h :: t ) =
    a


testValue =
    complex ( ( 1, "hello" ), { x = 3.14, y = 2 }, [ 3, 4 ] )
```

### Nested with wildcards
```elm
corners ( ( x, _ ), ( _, y ) ) =
    ( x, y )


testValue =
    corners ( ( 1, "hello" ), ( 3.14, 2 ) )
```

### Five args with mixed patterns
```elm
fiveArgs a ( b, c ) { d } _ e =
    a


testValue =
    fiveArgs 1 ( "hello", 3.14 ) { d = 2 } 3 "world"
```

### All same pattern type
```elm
allTuples ( a, b ) ( c, d ) ( e, f ) =
    a


testValue =
    allTuples ( 1, "hello" ) ( 3.14, 2 ) ( "world", 3 )
```

### Alternating patterns
```elm
alternate a _ b _ c =
    [ a, b, c ]


testValue =
    alternate 1 "hello" 2 3.14 3
```

### Custom type pattern in function argument
```elm
type Person
    = Person Int Int


getId : Person -> Int
getId (Person id _) =
    id


getAge : Person -> Int
getAge (Person _ age) =
    age


testValue : ( Int, Int )
testValue =
    ( getId (Person 30 25), getAge (Person 30 25) )
```

### Custom type pattern with multiple extractors
```elm
type Box
    = Box Int


unbox : Box -> Int
unbox (Box x) =
    x


testValue : Int
testValue =
    unbox (Box 42)
```

---

## ListCases

### Empty list
```elm
testValue = []
```

### Single int list
```elm
testValue = [42]
```

### Three-element int list
```elm
testValue = [1, 2, 3]
```

### List of lists
```elm
testValue = [[1, 2], [3, 4]]
```

### Deeply nested list
```elm
testValue = [[[1]]]
```

### List of tuples
```elm
testValue = [(1, "a"), (2, "b")]
```

### List of records
```elm
testValue = [{ x = 1 }, { x = 2 }]
```

### List of int tuples
```elm
testValue = [(1, 2), (3, 4)]
```

### List of records with multiple fields
```elm
testValue = [{ x = 1, y = "a" }, { x = 2, y = "b" }]
```

### concatMap
```elm
concat : List (List a) -> List a
concat xs = []

map : (a -> b) -> List a -> List b
map f xs = []

concatMap : (a -> List b) -> List a -> List b
concatMap f list = concat (map f list)

testValue : List Int
testValue = concatMap (\x -> [x]) [1, 2]
```

### indexedMap
```elm
map2 : (a -> b -> c) -> List a -> List b -> List c
map2 f xs ys = []

range : Int -> Int -> List Int
range lo hi = []

length : List a -> Int
length xs = 0

indexedMap : (Int -> a -> b) -> List a -> List b
indexedMap f xs = map2 f (range 0 (length xs - 1)) xs

testValue : List Int
testValue = indexedMap (\i x -> i) [1, 2]
```

### filter
```elm
foldr : (a -> b -> b) -> b -> List a -> b
foldr f init xs = init

cons : a -> List a -> List a
cons x xs = xs

filter : (a -> Bool) -> List a -> List a
filter isGood list = foldr (\x xs -> if isGood x then cons x xs else xs) [] list

testValue : List Int
testValue = filter (\x -> True) [1, 2]
```

### filterMap
```elm
foldr : (a -> b -> b) -> b -> List a -> b
foldr f init xs = init

cons : a -> List a -> List a
cons x xs = xs

maybeCons : (a -> Maybe b) -> a -> List b -> List b
maybeCons f mx xs =
    case f mx of
        Nothing -> xs
        Just x -> cons x xs

filterMap : (a -> Maybe b) -> List a -> List b
filterMap f xs = foldr (maybeCons f) [] xs

testValue : List Int
testValue = filterMap (\x -> Just x) [1, 2]
```

## TupleCases

### Pair of ints
```elm
testValue = (1, 2)
```

### Triple of ints
```elm
testValue = (1, 2, 3)
```

### Triple of mixed types
```elm
testValue = (42, "hello", 100)
```

### Tuple containing tuple
```elm
testValue = ((1, 2), 3)
```

### Deeply nested tuple
```elm
testValue = (0, ((1, 2), 3))
```

### 2-tuple containing 3-tuples
```elm
testValue = ((1, 2, 3), (4, 5, 6))
```

### Tuple with list
```elm
testValue = ([1, 2], "hello")
```

### Tuple with record
```elm
testValue = ({ x = 10 }, 20)
```

### Triple with list and record
```elm
testValue = ([1], { y = "test" }, 5)
```

## RecordCases

### Empty record
```elm
testValue = {}
```

### Record with int field
```elm
testValue = { value = 42 }
```

### Record with list field
```elm
testValue = { items = [1, 2] }
```

### Record with tuple field
```elm
testValue = { pair = (1, "a") }
```

### Two-field record
```elm
testValue = { id = 1, name = "a" }
```

### Five-field record
```elm
testValue = { a = 1, b = 2, c = 3, d = 4, e = 5 }
```

### Record with mixed types
```elm
testValue = { count = 42, name = "test", value = 3.14, enabled = True }
```

### Record containing record
```elm
testValue = { nested = { x = 10 } }
```

### Deeply nested record
```elm
testValue = { outer = { inner = { value = 42 } }, name = "test" }
```

### Record containing list of records
```elm
testValue = { items = [{ id = 1 }, { id = 2 }] }
```

### Access single field
```elm
testValue =
    let
        r = { x = 10 }
    in
    r.x
```

### Chained access
```elm
testValue =
    let
        r = { nested = { value = 42 } }
    in
    r.nested.value
```

### Accessor function
```elm
testFn = .x

testValue = testFn { x = 1 }
```

### Multiple accessor functions
```elm
testValue = (.x, .y)
```

### Update single field
```elm
testValue =
    let
        r = { x = 10, y = 20 }
    in
    { r | x = 100 }
```

### Update multiple fields
```elm
testValue =
    let
        r = { x = 10, y = 20, z = 30 }
    in
    { r | x = 100, z = 300 }
```

### Chained updates
```elm
testValue =
    let
        r = { x = 1, y = 2 }
        r2 = { r | x = 10 }
    in
    { r2 | y = 20 }
```

## ArrayCases

### repeat function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

initialize : Int -> (Int -> a) -> Array a
initialize n f = Array_elm_builtin 0 0 JsArray.empty JsArray.empty

unsafeReplaceTail : JsArray a -> Array a -> Array a
unsafeReplaceTail newTail array = array

translateIndex : Int -> Array a -> Int
translateIndex idx array = idx

sliceRight : Int -> Array a -> Array a
sliceRight end array = array

sliceLeft : Int -> Array a -> Array a
sliceLeft start array = array

empty : Array a
empty = Array_elm_builtin 0 0 JsArray.empty JsArray.empty

builderToArray : Bool -> Builder a -> Array a
builderToArray reverseNodeList builder = Array_elm_builtin 0 0 JsArray.empty JsArray.empty

builderFromArray : Array a -> Builder a
builderFromArray array = { tail = JsArray.empty, nodeList = [], nodeListSize = 0 }

appendHelpTree : JsArray a -> Array a -> Array a
appendHelpTree toAppend array = array

appendHelpBuilder : JsArray a -> Builder a -> Builder a
appendHelpBuilder toAppend builder = builder

tailIndex : Int -> Int
tailIndex len = len

shiftStep : Int
shiftStep = 5

branchFactor : Int
branchFactor = 32

fromListHelp : List a -> List (Node a) -> Int -> Array a
fromListHelp list nodeList nodeListSize = Array_elm_builtin 0 0 JsArray.empty JsArray.empty

repeat : Int -> a -> Array a
repeat n e = initialize n (\_ -> e)

testValue : Array Int
testValue = repeat 3 42
```

### push function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

-- (same helper stubs as repeat)

push : a -> Array a -> Array a
push a (Array_elm_builtin _ _ _ tail as array) =
    unsafeReplaceTail (JsArray.push a tail) array

testValue : Array Int
testValue = push 42 empty
```

### slice function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

-- (same helper stubs as repeat)

slice : Int -> Int -> Array a -> Array a
slice from to array =
    let
        correctFrom = translateIndex from array
        correctTo = translateIndex to array
    in
    if correctFrom > correctTo then
        empty
    else
        array
            |> sliceRight correctTo
            |> sliceLeft correctFrom

testValue : Array Int
testValue = slice 0 1 empty
```

### fromListHelp function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

-- (same helper stubs as repeat, except fromListHelp is the real one below)

fromListHelp : List a -> List (Node a) -> Int -> Array a
fromListHelp list nodeList nodeListSize =
    let
        ( jsArray, remainingItems ) =
            JsArray.initializeFromList branchFactor list
    in
    if JsArray.length jsArray < branchFactor then
        builderToArray True
            { tail = jsArray
            , nodeList = nodeList
            , nodeListSize = nodeListSize
            }
    else
        fromListHelp
            remainingItems
            (Leaf jsArray :: nodeList)
            (nodeListSize + 1)

testValue : Array Int
testValue = fromListHelp [] [] 0
```

### append function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

-- (same helper stubs as repeat)

append : Array a -> Array a -> Array a
append (Array_elm_builtin _ _ _ aTail as a) (Array_elm_builtin bLen _ bTree bTail) =
    if bLen <= branchFactor * 4 then
        let
            foldHelper node array =
                case node of
                    SubTree tree ->
                        JsArray.foldl foldHelper array tree
                    Leaf leaf ->
                        appendHelpTree leaf array
        in
        JsArray.foldl foldHelper a bTree
            |> appendHelpTree bTail
    else
        let
            foldHelper node builder =
                case node of
                    SubTree tree ->
                        JsArray.foldl foldHelper builder tree
                    Leaf leaf ->
                        appendHelpBuilder leaf builder
        in
        JsArray.foldl foldHelper (builderFromArray a) bTree
            |> appendHelpBuilder bTail
            |> builderToArray True

testValue : Array Int
testValue = append empty empty
```

### sliceLeft function
```elm
type Array a = Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)
type Node a = SubTree (JsArray (Node a)) | Leaf (JsArray a)
type alias Tree a = JsArray (Node a)
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }

-- (same helper stubs as repeat, except sliceLeft is the real one below)

sliceLeft : Int -> Array a -> Array a
sliceLeft from (Array_elm_builtin len _ tree tail as array) =
    if from == 0 then
        array
    else if from >= tailIndex len then
        Array_elm_builtin (len - from) shiftStep JsArray.empty <|
            JsArray.slice (from - tailIndex len) (JsArray.length tail) tail
    else
        let
            helper node acc =
                case node of
                    SubTree subTree ->
                        JsArray.foldr helper acc subTree
                    Leaf leaf ->
                        leaf :: acc

            leafNodes = JsArray.foldr helper [tail] tree
            skipNodes = from // branchFactor
            nodesToInsert = List.drop skipNodes leafNodes
        in
        case nodesToInsert of
            [] -> empty
            head :: rest ->
                let
                    firstSlice = from - (skipNodes * branchFactor)
                    initialBuilder =
                        { tail = JsArray.slice firstSlice (JsArray.length head) head
                        , nodeList = []
                        , nodeListSize = 0
                        }
                in
                List.foldl appendHelpBuilder initialBuilder rest
                    |> builderToArray True

testValue : Array Int
testValue = sliceLeft 0 empty
```

## FloatMathCases

### Basics.pi
```elm
testValue : Float
testValue = Basics.pi
```

### Basics.e
```elm
testValue : Float
testValue = Basics.e
```

### pi in expression
```elm
circleArea : Float -> Float
circleArea r = Basics.pi * r * r

testValue : Float
testValue = circleArea 2.0
```

### sin
```elm
testValue : Float
testValue = Basics.sin 0.0
```

### cos
```elm
testValue : Float
testValue = Basics.cos 0.0
```

### tan
```elm
testValue : Float
testValue = Basics.tan 0.0
```

### asin
```elm
testValue : Float
testValue = Basics.asin 0.0
```

### acos
```elm
testValue : Float
testValue = Basics.acos 1.0
```

### atan
```elm
testValue : Float
testValue = Basics.atan 0.0
```

### atan2
```elm
testValue : Float
testValue = Basics.atan2 1.0 1.0
```

### sqrt
```elm
testValue : Float
testValue = Basics.sqrt 16.0
```

### logBase
```elm
testValue : Float
testValue = logBase 2.0 8.0
```

### sqrt in expression
```elm
distance : Float -> Float -> Float -> Float -> Float
distance x1 y1 x2 y2 = Basics.sqrt ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))

testValue : Float
testValue = distance 0.0 0.0 3.0 4.0
```

### round
```elm
testValue : Int
testValue = Basics.round 2.7
```

### floor
```elm
testValue : Int
testValue = Basics.floor 2.7
```

### ceiling
```elm
testValue : Int
testValue = Basics.ceiling 2.3
```

### truncate
```elm
testValue : Int
testValue = Basics.truncate 2.9
```

### toFloat
```elm
testValue : Float
testValue = Basics.toFloat 42
```

### Float less than
```elm
testValue : Bool
testValue = 1.5 < 2.5
```

### Float less than or equal
```elm
testValue : Bool
testValue = 2.0 <= 2.0
```

### Float greater than
```elm
testValue : Bool
testValue = 3.0 > 2.0
```

### Float greater than or equal
```elm
testValue : Bool
testValue = 2.0 >= 2.0
```

### Float min
```elm
testValue : Float
testValue = Basics.min 1.5 2.5
```

### Float max
```elm
testValue : Float
testValue = Basics.max 1.5 2.5
```

### isNaN
```elm
testValue : Bool
testValue = Basics.isNaN (0.0 / 0.0)
```

### isInfinite
```elm
testValue : Bool
testValue = Basics.isInfinite (1.0 / 0.0)
```

### sin^2 + cos^2 = 1
```elm
pythagorean : Float -> Float
pythagorean x = Basics.sin x * Basics.sin x + Basics.cos x * Basics.cos x

testValue : Float
testValue = pythagorean 1.0
```

### Quadratic formula
```elm
discriminant : Float -> Float -> Float -> Float
discriminant a b c = b * b - 4.0 * a * c

quadraticRoot : Float -> Float -> Float -> Float
quadraticRoot a b c = (negate b + Basics.sqrt (discriminant a b c)) / 2.0 * a

testValue : Float
testValue = quadraticRoot 1.0 -3.0 2.0
```

### Clamp function
```elm
clamp : Float -> Float -> Float -> Float
clamp lo hi x = Basics.min hi (Basics.max lo x)

testValue : Float
testValue = Basics.clamp 0.0 1.0 1.5
```

---

# Part 5: Kernel Test Cases

## KernelCases

Note: These tests use the Canonical AST builder with `varKernelExpr`, which creates
`VarKernel` nodes that cannot be expressed in plain Elm source. The translations below
show the closest Elm-like representation using `{- kernel -}` annotations.

### VarKernel List.batch
```elm
testValue = {- Elm.Kernel.List.batch -}
```

### VarKernel Platform.batch
```elm
testValue = {- Elm.Kernel.Platform.batch -}
```

### VarKernel Scheduler.succeed
```elm
testValue = {- Elm.Kernel.Scheduler.succeed -}
```

### VarKernel Process.spawn
```elm
testValue = {- Elm.Kernel.Process.spawn -}
```

### VarKernel JsArray.empty
```elm
testValue = {- Elm.Kernel.JsArray.empty -}
```

### VarKernel Utils.Tuple2
```elm
testValue = {- Elm.Kernel.Utils.Tuple2 -}
```

### VarKernel Basics.pi (ConstantFloat intrinsic)
```elm
testValue = {- Elm.Kernel.Basics.pi -}
```

### VarKernel Basics.add (intrinsic function arity>0)
```elm
testValue = {- Elm.Kernel.Basics.add -}
```

### Calling kernel function with int arg
```elm
testValue = {- Elm.Kernel.List.singleton -} 42
```

### Calling kernel function with multiple args
```elm
testValue = {- Elm.Kernel.List.cons -} 1 []
```

### Nested kernel calls
```elm
testValue = {- Elm.Kernel.List.head -} ({- Elm.Kernel.List.singleton -} 1)
```

### Multiple kernel calls in tuple
```elm
testValue = ( {- Elm.Kernel.List.head -} [], {- Elm.Kernel.List.tail -} [] )
```

### Kernel function as higher-order argument
```elm
testValue =
    let
        apply f x = f x
    in
    apply {- Elm.Kernel.List.singleton -} 42
```

### Kernel function in list
```elm
testValue = [ {- Elm.Kernel.List.head -}, {- Elm.Kernel.List.tail -}, {- Elm.Kernel.List.length -} ]
```

### Kernel function in lambda body
```elm
testValue = \x -> {- Elm.Kernel.List.singleton -} x
```

### Kernel function in let binding
```elm
testValue =
    let
        result = {- Elm.Kernel.List.singleton -} 1
    in
    result
```

### Multiple kernel functions from same module
```elm
testValue = [ {- Elm.Kernel.List.cons -}, {- Elm.Kernel.List.singleton -}, {- Elm.Kernel.List.append -} ]
```

### Kernel functions from different modules
```elm
testValue = [ {- Elm.Kernel.List.cons -}, {- Elm.Kernel.Platform.batch -}, {- Elm.Kernel.Scheduler.succeed -} ]
```

### Kernel function with complex args
```elm
testValue = {- Elm.Kernel.Utils.pair -} (1, 2) [3, 4]
```

### Chained kernel calls
```elm
testValue = {- Elm.Kernel.List.head -} ({- Elm.Kernel.List.tail -} ({- Elm.Kernel.List.singleton -} 1))
```

### Kernel alias direct call
```elm
testValue =
    let
        f = {- Elm.Kernel.List.singleton -}
    in
    f 42
```

### Kernel alias transitive call
```elm
testValue =
    let
        f = {- Elm.Kernel.List.singleton -}
    in
    let
        g = f
    in
    g 42
```

## KernelIntrinsicCases

### K Basics.add Int
```elm
testValue = Basics.add 3 4
```

### K Basics.sub Int
```elm
testValue = Basics.sub 10 3
```

### K Basics.mul Int
```elm
testValue = Basics.mul 6 7
```

### K Basics.idiv
```elm
testValue = Basics.idiv 10 3
```

### K Basics.remainderBy
```elm
testValue = Basics.remainderBy 3 10
```

### K Basics.negate Int
```elm
testValue = Basics.negate 42
```

### K Basics.abs Int
```elm
testValue = Basics.abs -5
```

### K Basics.pow Int
```elm
testValue = Basics.pow 2 10
```

### K Basics.min Int
```elm
testValue = Basics.min 3 7
```

### K Basics.max Int
```elm
testValue = Basics.max 3 7
```

### K Basics.fadd
```elm
testValue = Basics.fadd 1.5 2.5
```

### K Basics.fsub
```elm
testValue = Basics.fsub 10.0 3.0
```

### K Basics.fmul
```elm
testValue = Basics.fmul 3.0 4.0
```

### K Basics.fdiv
```elm
testValue = Basics.fdiv 10.0 3.0
```

### K Basics.fpow
```elm
testValue = Basics.fpow 2.0 8.0
```

### K Basics.negate Float
```elm
testValue = Basics.negate 3.14
```

### K Basics.abs Float
```elm
testValue = Basics.abs -3.14
```

### K Basics.sqrt
```elm
testValue = Basics.sqrt 25.0
```

### K Basics.log
```elm
testValue = Basics.log 100.0
```

### K Basics.logBase
```elm
testValue = Basics.logBase 10.0 100.0
```

### K Basics.min Float
```elm
testValue = Basics.min 1.5 2.5
```

### K Basics.max Float
```elm
testValue = Basics.max 1.5 2.5
```

### K Basics.pow Float
```elm
testValue = Basics.pow 2.0 10.0
```

### K Basics.eq Int
```elm
testValue = Basics.eq 1 1
```

### K Basics.neq Int
```elm
testValue = Basics.neq 1 2
```

### K Basics.lt Int
```elm
testValue = Basics.lt 1 2
```

### K Basics.le Int
```elm
testValue = Basics.le 1 2
```

### K Basics.gt Int
```elm
testValue = Basics.gt 2 1
```

### K Basics.ge Int
```elm
testValue = Basics.ge 2 1
```

### K Basics.eq Float
```elm
testValue = Basics.eq 1.5 2.5
```

### K Basics.neq Float
```elm
testValue = Basics.neq 1.5 2.5
```

### K Basics.lt Float
```elm
testValue = Basics.lt 1.0 2.0
```

### K Basics.le Float
```elm
testValue = Basics.le 1.0 2.0
```

### K Basics.gt Float
```elm
testValue = Basics.gt 2.0 1.0
```

### K Basics.ge Float
```elm
testValue = Basics.ge 2.0 1.0
```

### K Basics.not
```elm
testValue = Basics.not True
```

### K Basics.and
```elm
testValue = Basics.and True False
```

### K Basics.or
```elm
testValue = Basics.or True False
```

### K Basics.xor
```elm
testValue = Basics.xor True False
```

### K Basics.sin
```elm
testValue = Basics.sin 0.0
```

### K Basics.cos
```elm
testValue = Basics.cos 0.0
```

### K Basics.tan
```elm
testValue = Basics.tan 0.0
```

### K Basics.asin
```elm
testValue = Basics.asin 0.5
```

### K Basics.acos
```elm
testValue = Basics.acos 0.5
```

### K Basics.atan
```elm
testValue = Basics.atan 1.0
```

### K Basics.atan2
```elm
testValue = Basics.atan2 1.0 0.0
```

### K Basics.toFloat
```elm
testValue = Basics.toFloat 42
```

### K Basics.round
```elm
testValue = Basics.round 3.7
```

### K Basics.floor
```elm
testValue = Basics.floor 3.7
```

### K Basics.ceiling
```elm
testValue = Basics.ceiling 3.2
```

### K Basics.truncate
```elm
testValue = Basics.truncate 3.9
```

### K Basics.pi
```elm
testValue = Basics.pi
```

### K Basics.e
```elm
testValue = Basics.e
```

### K Basics.identity
```elm
testValue = Basics.identity 99
```

### K Basics.always
```elm
testValue = Basics.always 1 "ignored"
```

### K Basics.isNaN
```elm
testValue = Basics.isNaN 0.0
```

### K Basics.isInfinite
```elm
testValue = Basics.isInfinite 1.0
```

### K Basics.clamp
```elm
testValue = Basics.clamp 0 10 15
```

### K Utils.equal Int
```elm
testValue = Basics.equal 1 2
```

### K Utils.notEqual Int
```elm
testValue = Basics.notEqual 1 2
```

### K Utils.compare Int
```elm
testValue = Basics.compare 1 2
```

### K Utils.lt Int
```elm
testValue = Basics.lt 1 2
```

### K Utils.le Int
```elm
testValue = Basics.le 1 2
```

### K Utils.gt Int
```elm
testValue = Basics.gt 2 1
```

### K Utils.ge Int
```elm
testValue = Basics.ge 2 1
```

### K Utils.append
```elm
testValue = Basics.append [1] [2]
```

### K Utils.equal Float
```elm
testValue = Basics.equal 1.5 2.5
```

### K Utils.notEqual Float
```elm
testValue = Basics.notEqual 1.5 2.5
```

### K Utils.compare Float
```elm
testValue = Basics.compare 1.5 2.5
```

### K Utils.lt Float
```elm
testValue = Basics.lt 1.0 2.0
```

### K Utils.le Float
```elm
testValue = Basics.le 1.0 2.0
```

### K Utils.gt Float
```elm
testValue = Basics.gt 2.0 1.0
```

### K Utils.ge Float
```elm
testValue = Basics.ge 2.0 1.0
```

### K Bitwise.and
```elm
testValue = Bitwise.and 255 15
```

### K Bitwise.or
```elm
testValue = Bitwise.or 240 15
```

### K Bitwise.xor
```elm
testValue = Bitwise.xor 255 15
```

### K Bitwise.complement
```elm
testValue = Bitwise.complement 255
```

### K Bitwise.shiftLeftBy
```elm
testValue = Bitwise.shiftLeftBy 4 1
```

### K Bitwise.shiftRightBy
```elm
testValue = Bitwise.shiftRightBy 2 255
```

### K Bitwise.shiftRightZfBy
```elm
testValue = Bitwise.shiftRightZfBy 2 255
```

### K JsArray.empty
```elm
testValue = Array.empty
```

### K JsArray.push
```elm
testValue = Array.push 42 Array.empty
```

### K JsArray.length
```elm
testValue = Array.length Array.empty
```

### K JsArray.unsafeGet
```elm
testValue = Array.unsafeGet 0 (Array.initializeFromList 3 [10, 20, 30])
```

### K JsArray.unsafeSet
```elm
testValue = Array.unsafeSet 0 99 Array.empty
```

### K JsArray.slice
```elm
testValue = Array.slice 0 2 Array.empty
```

### K JsArray.initializeFromList
```elm
testValue = Array.initializeFromList 3 [1, 2, 3]
```

### K JsArray.map
```elm
testValue = Array.map (\x -> Basics.add x 1) Array.empty
```

### K JsArray.foldl
```elm
testValue = Array.foldl (\x acc -> Basics.add x acc) 0 Array.empty
```

### K JsArray.foldr
```elm
testValue = Array.foldr (\x acc -> Basics.add x acc) 0 Array.empty
```

### K List.cons
```elm
testValue = List.cons 1 [2]
```

### K List.singleton
```elm
testValue = List.singleton 42
```

### K List.map
```elm
testValue = List.map (\x -> Basics.add x 1) [1, 2, 3]
```

### K List.map2
```elm
testValue = List.map2 (\a b -> Basics.add a b) [1, 2] [10, 20]
```

### K List.foldl
```elm
testValue = List.foldl Basics.add 0 [1, 2, 3]
```

### K List.foldr
```elm
testValue = List.foldr (\x acc -> Basics.add x acc) 0 [1, 2, 3]
```

### K List.reverse
```elm
testValue = List.reverse [3, 2, 1]
```

### K List.length
```elm
testValue = List.length [1, 2]
```

### K List.concat
```elm
testValue = List.concat [[1], [2]]
```

### K List.range
```elm
testValue = List.range 1 5
```

### K List.drop
```elm
testValue = List.drop 2 [1, 2, 3]
```

### K Tuple.pair
```elm
testValue = Tuple.pair 1 "hello"
```

### K Tuple.first
```elm
testValue = Tuple.first (1, "hi")
```

### K Tuple.second
```elm
testValue = Tuple.second (1, "hi")
```

### K Tuple.mapFirst
```elm
testValue = Tuple.mapFirst (\x -> Basics.add x 1) (5, "hi")
```

### K Tuple.mapSecond
```elm
testValue = Tuple.mapSecond (\x -> Basics.add x 1) ("hi", 5)
```

### K String.fromNumber
```elm
testValue = String.fromNumber 42
```

### K Bytes.encode
```elm
testValue = Bytes.encode 0
```

### K Bytes.decode
```elm
testValue = Bytes.decode 0 0
```

### K kernel with unit result
```elm
testValue = Basics.identity (1, 2)
```

### K kernel returning record
```elm
testValue = Basics.identity (Tuple.pair 1 "hi")
```

### K Debug.log kernel
```elm
testValue = Debug.log "tag" 42
```

### K Debug.todo kernel
```elm
testValue = Debug.todo "not implemented"
```

## KernelHigherOrderCases

### List.map with Basics.negate
```elm
testValue = List.map Basics.negate [1, 2, 3]
```

### List.foldl for sum
```elm
testValue = List.foldl (\x acc -> x + acc) 0 (List.range 1 10)
```

### List.map on tuples with Tuple.first
```elm
testValue = List.map Tuple.first [(1, "a"), (2, "b")]
```

### Nested List.map
```elm
testValue = List.map (\xs -> List.map (\x -> x + 1) xs) [[1, 2], [3, 4]]
```

### List.foldl with kernel add
```elm
testValue = List.foldl Basics.add 0 [1, 2, 3]
```

### List.map with user-defined function
```elm
testValue =
    let
        double x = x * 2
    in
    List.map double [1, 2, 3]
```

### List.map with anonymous lambda
```elm
testValue = List.map (\x -> x * 2) [1, 2, 3]
```

### List.map with partial application
```elm
testValue =
    let
        add a b = a + b
        addOne = add 1
    in
    List.map addOne [1, 2, 3]
```

### List.filter with user predicate
```elm
testValue =
    let
        isPositive x = x > 0
    in
    List.filter isPositive [1, 2, 3, 4, 5]
```

### List.foldl with operator as value
```elm
testValue = List.foldl (\a b -> a + b) 0 [1, 2, 3, 4]
```

### List.foldr with string append operator
```elm
testValue = List.foldr (\a b -> a ++ b) "" ["a", "b", "c"]
```

### List.map with Bool result
```elm
testValue = List.map Basics.not [True, False, True]
```

### List.reverse via kernel
```elm
testValue = List.reverse [1, 2, 3]
```

### List.length via kernel
```elm
testValue = List.length [1, 2, 3]
```

### Pipeline List.map
```elm
testValue =
    let
        double x = x * 2
    in
    (List.map double) [1, 2, 3]
```

### List.concat via append
```elm
testValue = [1, 2] ++ [3, 4]
```

### List.map with partial app of multi-stage fn
```elm
testValue =
    let
        curried x = \y -> x + y
    in
    List.map (curried 5) [1, 2, 3]
```

### List.foldl with partial app accumulator
```elm
testValue =
    let
        combine factor x acc = factor * x + acc
    in
    List.foldl (combine 2) 0 [1, 2, 3]
```

### List.filter with partially applied equality
```elm
testValue =
    let
        eq a b = a == b
    in
    List.filter (eq 5) [1, 2, 5, 3, 5]
```

## KernelCompositionCases

### Chained List.map and List.reverse
```elm
testValue = List.reverse (List.map (\x -> x * 2) [1, 2, 3])
```

## KernelOperatorCases

### Arithmetic operators
```elm
testValue =
    let
        a = 3 + 4
        b = 10 - 3
        c = 6 * 7
    in
    a + b + c
```

### Float division
```elm
testValue = 10.0 / 3.0
```

### Integer division
```elm
testValue = 10 // 3
```

### Power operator
```elm
testValue = 2 ^ 10
```

### Pipe operator
```elm
testValue = 5 |> Basics.abs
```

### :: cons operator
```elm
testValue = 0 :: [1, 2]
```

### ++ append operator
```elm
testValue = [1] ++ [2]
```

## KernelComparisonCases

### Int comparison operators
```elm
testValue =
    let
        lt = 1 < 2
        gt = 2 > 1
        le = 1 <= 1
        ge = 1 >= 1
        eq = 1 == 1
        ne = 1 /= 2
    in
    lt
```

### Float comparison op
```elm
testValue = 1.5 < 2.5
```

### String equality op
```elm
testValue = "hello" == "world"
```

### Bool logical ops
```elm
testValue =
    let
        a = True && False
        b = True || False
    in
    a
```

### Char equality op
```elm
testValue = 'a' == 'b'
```

## KernelContextCases

### Kernel in lambda
```elm
testValue = \x -> Basics.add x 1
```

### Kernel in let binding
```elm
testValue =
    let
        result = Basics.add 3 4
    in
    result
```

### Kernel nested calls
```elm
testValue = Basics.add (Basics.mul 2 3) (Basics.mul 4 5)
```

### Kernel chained arithmetic
```elm
testValue = Basics.add (Basics.add 1 2) (Basics.sub 10 5)
```

## KernelPapAbiCases

### Equality on Int with string case
```elm
testValue =
    let
        classify s =
            case s of
                "foo" -> "matched"
                _ -> "other"
        result = 1 == 2
    in
    classify "foo"
```

### Equality on multiple types
```elm
testValue =
    let
        intEq = 1 == 2
        strEq = "a" == "b"
    in
    intEq
```

### Equality lambda passed to map
```elm
testValue = List.map (\x -> x == 5) [1, 5, 3]
```

### Append on lists
```elm
testValue = [1] ++ [2, 3]
```

## KernelCtorArgCases

### Tuple with kernel result
```elm
testValue = (Basics.add 1 2, Basics.mul 3 4)
```

### List of kernel results
```elm
testValue = [Basics.add 1 2, Basics.sub 5 3, Basics.mul 2 2]
```

### Kernel result in let then ctor
```elm
type Wrapper a = Wrap a

testValue : Wrapper Int
testValue = Wrap (Basics.add 10 20)
```

### Custom ctor with kernel arg
```elm
type Pair a b = MkPair a b

testValue : Pair Int String
testValue = MkPair (Basics.add 1 2) (String.fromNumber 42)
```

### Nested kernel in tuple
```elm
testValue = ((Basics.add 1 2, 3), Basics.mul 4 5)
```

### Kernel identity on tuple
```elm
testValue = Basics.identity (1, "hello")
```

### Kernel identity on record-like tuple
```elm
testValue = Basics.identity [(1, 2), (3, 4)]
```

---

# Part 6: SourceIR Specialization Test Cases

## SpecializeExprCases

### Simple enum case expression
```elm
type Status
    = Pending
    | Active
    | Completed

statusCode : Status -> Int
statusCode s =
    case s of
        Pending ->
            0

        Active ->
            1

        Completed ->
            2

testValue : Int
testValue =
    statusCode Active
```

### Nested enum case
```elm
type Color
    = Red
    | Green
    | Blue

mixColors : Color -> Color -> Int
mixColors c1 c2 =
    case c1 of
        Red ->
            case c2 of
                Red ->
                    16711680

                Green ->
                    16776960

                Blue ->
                    16711935

        Green ->
            65280

        Blue ->
            255

testValue : Int
testValue =
    mixColors Red Green
```

### Enum with fallback pattern
```elm
type Day
    = Monday
    | Tuesday
    | Wednesday
    | Thursday
    | Friday
    | Saturday
    | Sunday

isWeekend : Day -> Bool
isWeekend day =
    case day of
        Saturday ->
            True

        Sunday ->
            True

        _ ->
            False

testValue : Bool
testValue =
    isWeekend Saturday
```

### Identity function (placeholder for Debug tests)
```elm
identity : a -> a
identity x =
    x

testValue : Int
testValue =
    identity 42
```

### Tail recursive sum
```elm
sumHelper : Int -> Int -> Int
sumHelper acc n =
    if n <= 0 then
        acc
    else
        sumHelper (acc + n) (n - 1)

sum : Int -> Int
sum n =
    sumHelper 0 n

testValue : Int
testValue =
    sum 100
```

### Tail recursive with accumulator
```elm
countdownHelper : Int -> Int -> Int
countdownHelper acc n =
    if n <= 0 then
        acc
    else
        countdownHelper (acc + n) (n - 1)

countdown : Int -> Int
countdown n =
    countdownHelper 0 n

testValue : Int
testValue =
    countdown 10
```

### Non-tail recursive for comparison
```elm
factorial : Int -> Int
factorial n =
    if n <= 1 then
        1
    else
        n * factorial (n - 1)

testValue : Int
testValue =
    factorial 5
```

### Int literal patterns
```elm
digitName : Int -> String
digitName n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"

        2 ->
            "two"

        _ ->
            "other"

testValue : String
testValue =
    digitName 1
```

### String literal patterns
```elm
greet : String -> String
greet name =
    case name of
        n ->
            if n == "" then
                "Hello, stranger!"
            else
                "Hello!"

testValue : String
testValue =
    greet "Alice"
```

## SpecializeAccessorCases

### List.map .name records
```elm
type alias Person =
    { name : String, age : Int }

getNames : List Person -> List String
getNames people =
    List.map .name people

testValue : List String
testValue =
    getNames
        [ { name = "Alice", age = 30 }
        , { name = "Bob", age = 25 }
        ]
```

### List.map .value on different field type
```elm
type alias Item =
    { id : Int, value : Int }

getValues : List Item -> List Int
getValues items =
    List.map .value items

testValue : List Int
testValue =
    getValues
        [ { id = 1, value = 100 }
        , { id = 2, value = 200 }
        ]
```

### Multiple map with different accessors
```elm
type alias Person =
    { name : String, age : Int }

testValue : Int
testValue =
    let
        people =
            [ { name = "Alice", age = 30 }
            , { name = "Bob", age = 25 }
            ]

        names =
            List.map .name people

        ages =
            List.map .age people
    in
    List.length ages
```

### Accessor assigned to variable
```elm
type alias Item =
    { value : Int, label : String }

getValue : Item -> Int
getValue item =
    let
        accessor =
            .value
    in
    accessor item

testValue : Int
testValue =
    getValue { value = 42, label = "test" }
```

### Accessor in nested let
```elm
type alias Item =
    { x : Int, y : Int }

sumXY : Item -> Int
sumXY item =
    let
        getX =
            .x

        getY =
            .y
    in
    getX item + getY item

testValue : Int
testValue =
    sumXY { x = 10, y = 20 }
```

### Accessor in foldl accumulator
```elm
type alias Item =
    { amount : Int }

sumAmounts : List Item -> Int
sumAmounts items =
    List.foldl (\item acc -> item.amount + acc) 0 items

testValue : Int
testValue =
    sumAmounts
        [ { amount = 10 }
        , { amount = 20 }
        , { amount = 30 }
        ]
```

### Accessor on record with extra fields
```elm
type alias BigRecord =
    { name : String
    , age : Int
    , email : String
    , active : Bool
    }

getName : BigRecord -> String
getName rec =
    rec.name

getNames : List BigRecord -> List String
getNames recs =
    List.map .name recs

testValue : List String
testValue =
    getNames
        [ { name = "Alice"
          , age = 30
          , email = "alice@example.com"
          , active = True
          }
        ]
```

### Same accessor on different record types
```elm
type alias Person =
    { name : String, age : Int }

type alias Company =
    { name : String, employees : Int }

getPersonNames : List Person -> List String
getPersonNames people =
    List.map .name people

getCompanyNames : List Company -> List String
getCompanyNames companies =
    List.map .name companies

testValue : Int
testValue =
    let
        personNames =
            getPersonNames [ { name = "Alice", age = 30 } ]

        companyNames =
            getCompanyNames [ { name = "ACME", employees = 100 } ]
    in
    List.length personNames + List.length companyNames
```

### Generic function using accessor
```elm
type alias Item =
    { id : Int, label : String }

countIds : List Item -> Int
countIds items =
    List.length (List.map .id items)

testValue : Int
testValue =
    countIds
        [ { id = 1, label = "A" }
        , { id = 2, label = "B" }
        ]
```

## SpecializeConstructorCases

### Custom enum type
```elm
type Color
    = Red
    | Green
    | Blue

toRgb : Color -> Int
toRgb color =
    case color of
        Red ->
            16711680

        Green ->
            65280

        Blue ->
            255

testValue : Int
testValue =
    toRgb Red
```

### Multiple enum constructors in case
```elm
type Direction
    = North
    | South
    | East
    | West

isVertical : Direction -> Bool
isVertical dir =
    case dir of
        North ->
            True

        South ->
            True

        East ->
            False

        West ->
            False

testValue : Bool
testValue =
    isVertical North
```

### Single-field wrapper type
```elm
type Wrapper
    = Wrap Int

unwrap : Wrapper -> Int
unwrap w =
    case w of
        Wrap n ->
            n

testValue : Int
testValue =
    unwrap (Wrap 42)
```

### Bool wrapper type
```elm
type BoolWrapper
    = WrapBool Bool

unwrapBool : BoolWrapper -> Bool
unwrapBool w =
    case w of
        WrapBool b ->
            b

boolToInt : Bool -> Int
boolToInt b =
    case b of
        True ->
            1

        False ->
            0

testValue : Int
testValue =
    boolToInt (unwrapBool (WrapBool True))
```

### Unary constructor with pattern matching
```elm
type Box
    = Empty
    | Full Int

getOrDefault : Box -> Int -> Int
getOrDefault box default =
    case box of
        Empty ->
            default

        Full x ->
            x

testValue : Int
testValue =
    getOrDefault (Full 10) 0
```

### Constructor with two fields
```elm
type Point
    = Point Int Int

getX : Point -> Int
getX p =
    case p of
        Point x y ->
            x

getY : Point -> Int
getY p =
    case p of
        Point x y ->
            y

testValue : Int
testValue =
    getX (Point 3 4) + getY (Point 3 4)
```

### Constructor with three fields
```elm
type Vector3
    = Vec3 Int Int Int

magnitude : Vector3 -> Int
magnitude v =
    case v of
        Vec3 x y z ->
            x + y + z

testValue : Int
testValue =
    magnitude (Vec3 1 2 3)
```

### Polymorphic wrapper type
```elm
type Identity a
    = Identity a

runIdentity : Identity a -> a
runIdentity id =
    case id of
        Identity x ->
            x

testValue : Int
testValue =
    runIdentity (Identity 99)
```

### Either-like polymorphic type
```elm
type Either a b
    = Left a
    | Right b

fromLeft : Either a b -> a -> a
fromLeft e default =
    case e of
        Left x ->
            x

        Right _ ->
            default

testValue : Int
testValue =
    fromLeft (Left 42) 0
```

## SpecializeRecordCtorCases

### Constructor with record field
```elm
type Wrapper
    = Wrap { value : Int }

getValue : Wrapper -> Int
getValue w =
    case w of
        Wrap r ->
            r.value

testValue : Int
testValue =
    getValue (Wrap { value = 42 })
```

### Wrapper over record alias with union field (access)
```elm
type alias Props =
    { tag : Kind, count : Int }

type Error
    = Error Props

type Kind
    = A
    | B Int

getTag : Error -> Int
getTag e =
    case e of
        Error props ->
            case props.tag of
                A ->
                    0

                B n ->
                    n

testValue : Int
testValue =
    getTag (Error { tag = B 7, count = 1 })
```

### Wrapper over record alias with union field (record destruct)
```elm
type alias Props =
    { tag : Kind, count : Int }

type Error
    = Error Props

type Kind
    = A
    | B Int

getTag : Error -> Int
getTag e =
    case e of
        Error { tag, count } ->
            case tag of
                A ->
                    0

                B n ->
                    n

testValue : Int
testValue =
    getTag (Error { tag = B 7, count = 1 })
```

### Multi-constructor union with record field
```elm
type Result
    = Ok { value : Int }
    | Err Int

extract : Result -> Int
extract r =
    case r of
        Ok rec ->
            rec.value

        Err code ->
            code

testValue : Int
testValue =
    extract (Ok { value = 99 })
```

### Nested record-through-union (access)
```elm
type alias Inner =
    { x : Int }

type Outer
    = Leaf
    | Node Inner

type alias Container =
    { item : Outer }

type Box
    = Box Container

unbox : Box -> Int
unbox box =
    case box of
        Box c ->
            case c.item of
                Node inner ->
                    inner.x

                Leaf ->
                    0

testValue : Int
testValue =
    unbox (Box { item = Node { x = 55 } })
```

### Nested record-through-union (destruct)
```elm
type alias Inner =
    { x : Int }

type Outer
    = Leaf
    | Node Inner

type alias Container =
    { item : Outer }

type Box
    = Box Container

unbox : Box -> Int
unbox box =
    case box of
        Box { item } ->
            case item of
                Node { x } ->
                    x

                Leaf ->
                    0

testValue : Int
testValue =
    unbox (Box { item = Node { x = 55 } })
```

### Poly wrapper over record alias with union field (access)
```elm
type alias Pair a =
    { first : a, second : Int }

type Kind
    = A
    | B

type Wrap a
    = Wrap (Pair a)

unwrap : Wrap Kind -> Int
unwrap w =
    case w of
        Wrap p ->
            case p.first of
                A ->
                    p.second

                B ->
                    0

testValue : Int
testValue =
    unwrap (Wrap { first = A, second = 42 })
```

### Poly wrapper over record alias with union field (destruct)
```elm
type alias Pair a =
    { first : a, second : Int }

type Kind
    = A
    | B

type Wrap a
    = Wrap (Pair a)

unwrap : Wrap Kind -> Int
unwrap w =
    case w of
        Wrap { first, second } ->
            case first of
                A ->
                    second

                B ->
                    0

testValue : Int
testValue =
    unwrap (Wrap { first = A, second = 42 })
```

## SpecializeCycleCases

### Two mutually recursive functions (isEven/isOdd)
```elm
testValue =
    let
        isEven n =
            if n == 0 then
                True
            else
                isOdd (n - 1)

        isOdd n =
            if n == 0 then
                False
            else
                isEven (n - 1)
    in
    isEven 10
```

### Three mutually recursive functions
```elm
testValue =
    let
        funcA n =
            if n <= 0 then
                0
            else
                funcB (n - 1)

        funcB n =
            if n <= 0 then
                1
            else
                funcC (n - 1)

        funcC n =
            if n <= 0 then
                2
            else
                funcA (n - 1)
    in
    funcA 10
```

### Mutually recursive with different arities
```elm
testValue =
    let
        singleArg n =
            if n <= 0 then
                0
            else
                doubleArg n 1

        doubleArg a b =
            if a <= 0 then
                b
            else
                singleArg (a - b)
    in
    singleArg 5
```

### Value depending on recursive function
```elm
testValue =
    let
        factorial n =
            if n <= 1 then
                1
            else
                n * factorial (n - 1)

        result =
            factorial 5
    in
    result
```

### Multiple values in recursive binding group
```elm
testValue =
    let
        countdown n =
            if n <= 0 then
                []
            else
                n :: countdown (n - 1)

        numbers =
            countdown 5

        sumVal =
            countdown 3
    in
    numbers
```

### Cycle with polymorphic functions
```elm
testValue =
    let
        process xs =
            case xs of
                [] ->
                    []

                nonEmpty ->
                    transform nonEmpty

        transform xs =
            process xs
    in
    process [ 1, 2 ]
```

### Nested cycles
```elm
testValue =
    let
        outer n =
            let
                inner m =
                    if m <= 0 then
                        0
                    else
                        inner (m - 1)
            in
            inner n
    in
    outer 5
```

### Recursive list function with unconstrained element type
```elm
testValue =
    let
        process xs =
            case xs of
                [] ->
                    []

                _ :: rest ->
                    process rest
    in
    process []
```

### Mutually recursive functions over phantom custom type
```elm
type Box a
    = Box

f : Box a -> Box a
f x =
    g x

g : Box a -> Box a
g x =
    f x

testValue : Box a
testValue =
    f Box
```

## SpecializePolyLetCases

### identity at Int and String
```elm
testValue =
    let
        identity x =
            x
    in
    ( identity 1, identity "hello" )
```

### const at two type combos
```elm
testValue =
    let
        const a b =
            a
    in
    ( const 1 "hi", const "hi" 1 )
```

### apply higher-order at two types
```elm
testValue =
    let
        apply f x =
            f x
    in
    ( apply (\n -> n + 1) 1
    , apply (\s -> s) "hi"
    )
```

### compose at two type combos
```elm
testValue =
    let
        compose f g x =
            f (g x)

        addOne n =
            n + 1
    in
    ( compose addOne addOne 1
    , compose addOne addOne 2
    )
```

### recursive length at two list types
```elm
testValue =
    let
        length xs =
            case xs of
                [] ->
                    0

                _ :: rest ->
                    1 + length rest
    in
    ( length [ 1, 2 ], length [ "a", "b" ] )
```

### tail-recursive foldl at two types
```elm
testValue =
    let
        foldl f acc xs =
            case xs of
                [] ->
                    acc

                x :: rest ->
                    foldl f (f x acc) rest
    in
    ( foldl (\x acc -> x + acc) 0 [ 1, 2, 3 ]
    , foldl (\x acc -> acc + 1) 0 [ "a", "b" ]
    )
```

### recursive map at two types
```elm
testValue =
    let
        map f xs =
            case xs of
                [] ->
                    []

                x :: rest ->
                    f x :: map f rest
    in
    ( map (\n -> n + 1) [ 1, 2 ]
    , map (\s -> s) [ "a", "b" ]
    )
```

### partial application of map
```elm
testValue =
    let
        map f xs =
            case xs of
                [] ->
                    []

                x :: rest ->
                    f x :: map f rest

        mapAddOne =
            map (\n -> n + 1)

        mapId =
            map (\s -> s)
    in
    ( mapAddOne [ 1, 2 ], mapId [ "a", "b" ] )
```

### pair constructor at two type combos
```elm
testValue =
    let
        pair a b =
            ( a, b )
    in
    ( pair 1 "hi", pair "hi" 1 )
```

### tail-recursive reverse at two types
```elm
testValue =
    let
        reverseHelper acc xs =
            case xs of
                [] ->
                    acc

                x :: rest ->
                    reverseHelper (x :: acc) rest

        reverse xs =
            reverseHelper [] xs
    in
    ( reverse [ 1, 2 ], reverse [ "a", "b" ] )
```

### twice higher-order at two types
```elm
testValue =
    let
        twice f x =
            f (f x)
    in
    ( twice (\n -> n + 1) 0
    , twice (\s -> s) "hi"
    )
```

### singleton at two types
```elm
testValue =
    let
        singleton x =
            [ x ]
    in
    ( singleton 42, singleton "hi" )
```

### named local as higher-order arg
```elm
testValue =
    let
        identity x =
            x

        apply f x =
            f x
    in
    apply identity 42
```

### named local as higher-order arg at two types
```elm
testValue =
    let
        identity x =
            x

        apply f x =
            f x
    in
    ( apply identity 42
    , apply identity "hello"
    )
```

## SpecializePolyTopCases

### identity at Int and String
```elm
identity : a -> a
identity x =
    x

testValue : ( Int, String )
testValue =
    ( identity 1, identity "hello" )
```

### const at two type combos
```elm
const : a -> b -> a
const a b =
    a

testValue : ( Int, String )
testValue =
    ( const 1 "hi", const "hi" 1 )
```

### apply higher-order at two types
```elm
apply : (a -> b) -> a -> b
apply f x =
    f x

addOne : Int -> Int
addOne n =
    n + 1

testValue : ( Int, String )
testValue =
    ( apply addOne 1
    , apply (\s -> s) "hi"
    )
```

### compose at two type combos
```elm
compose : (b -> c) -> (a -> b) -> a -> c
compose f g x =
    f (g x)

addOne : Int -> Int
addOne n =
    n + 1

testValue : ( Int, Int )
testValue =
    ( compose addOne addOne 1
    , compose addOne addOne 2
    )
```

### recursive length at two list types
```elm
length : List a -> Int
length xs =
    case xs of
        [] ->
            0

        _ :: rest ->
            1 + length rest

testValue : ( Int, Int )
testValue =
    ( length [ 1, 2 ], length [ "a", "b" ] )
```

### tail-recursive foldl at two types
```elm
foldl : (a -> b -> b) -> b -> List a -> b
foldl f acc xs =
    case xs of
        [] ->
            acc

        x :: rest ->
            foldl f (f x acc) rest

testValue : ( Int, Int )
testValue =
    ( foldl (\x acc -> x + acc) 0 [ 1, 2, 3 ]
    , foldl (\x acc -> acc + 1) 0 [ "a", "b" ]
    )
```

### recursive map at two types
```elm
map : (a -> b) -> List a -> List b
map f xs =
    case xs of
        [] ->
            []

        x :: rest ->
            f x :: map f rest

addOne : Int -> Int
addOne n =
    n + 1

testValue : ( List Int, List String )
testValue =
    ( map addOne [ 1, 2 ]
    , map (\s -> s) [ "a", "b" ]
    )
```

### partial application of map
```elm
map : (a -> b) -> List a -> List b
map f xs =
    case xs of
        [] ->
            []

        x :: rest ->
            f x :: map f rest

addOne : Int -> Int
addOne n =
    n + 1

testValue : ( List Int, List String )
testValue =
    let
        mapAddOne =
            map addOne

        mapId =
            map (\s -> s)
    in
    ( mapAddOne [ 1, 2 ], mapId [ "a", "b" ] )
```

### pair constructor at two type combos
```elm
pair : a -> b -> ( a, b )
pair a b =
    ( a, b )

testValue : ( ( Int, String ), ( String, Int ) )
testValue =
    ( pair 1 "hi", pair "hi" 1 )
```

### tail-recursive reverse at two types
```elm
reverseHelper : List a -> List a -> List a
reverseHelper acc xs =
    case xs of
        [] ->
            acc

        x :: rest ->
            reverseHelper (x :: acc) rest

reverse : List a -> List a
reverse xs =
    reverseHelper [] xs

testValue : ( List Int, List String )
testValue =
    ( reverse [ 1, 2 ], reverse [ "a", "b" ] )
```

### twice higher-order at two types
```elm
twice : (a -> a) -> a -> a
twice f x =
    f (f x)

addOne : Int -> Int
addOne n =
    n + 1

testValue : ( Int, String )
testValue =
    ( twice addOne 0
    , twice (\s -> s) "hi"
    )
```

### singleton at two types
```elm
singleton : a -> List a
singleton x =
    [ x ]

testValue : ( List Int, List String )
testValue =
    ( singleton 42, singleton "hi" )
```

## PolyChainCases

### Custom type wrapping: insertTree called twice from polymorphic caller
```elm
type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)

insertTree : a -> Tree a -> Tree a
insertTree val tree =
    Node tree val Leaf

buildTree : a -> a -> Tree a
buildTree x y =
    let
        t1 =
            insertTree x Leaf

        t2 =
            insertTree y t1
    in
    t2

sizeTree : Tree a -> Int
sizeTree t =
    case t of
        leaf ->
            0

        node ->
            1

testValue : Int
testValue =
    sizeTree (buildTree 1 2)
```

### Tuple wrapping: poly helper returns (a, Int), called from poly caller
```elm
tag : a -> ( a, Int )
tag x =
    ( x, 0 )

tagBoth : a -> a -> ( a, Int )
tagBoth x y =
    let
        r1 =
            tag x

        r2 =
            tag y
    in
    r2

testValue : ( String, Int )
testValue =
    tagBoth "hello" "world"
```

### Two type vars: both collide, called from poly caller with same names
```elm
type Pair a b
    = MkPair a b

combine : a -> b -> Pair a b
combine x y =
    MkPair x y

process : a -> b -> Pair a b
process x y =
    let
        r1 =
            combine x y

        r2 =
            combine x y
    in
    r2

testValue : Pair Int String
testValue =
    process 42 "hello"
```

### Dict-like insert from polymorphic caller (3 type var collision)
```elm
type MyDict k v
    = Empty
    | Entry k v (MyDict k v)

insert : k -> v -> MyDict k v -> MyDict k v
insert key val dict =
    Entry key val dict

buildDict : k -> v -> v -> MyDict k v
buildDict key v1 v2 =
    let
        d0 =
            Empty

        d1 =
            insert key v1 d0

        d2 =
            insert key v2 d1
    in
    d2

size : MyDict k v -> Int
size d =
    case d of
        empty ->
            0

        entry ->
            1

testValue : Int
testValue =
    size (buildDict "key" 1 2)
```

### Chained calls: result feeds through 4 calls in poly context
```elm
type Box a
    = Box a

wrap : a -> Box a -> Box a
wrap x b =
    Box x

chain4 : a -> Box a -> Box a
chain4 x b =
    let
        r1 =
            wrap x b

        r2 =
            wrap x r1

        r3 =
            wrap x r2

        r4 =
            wrap x r3
    in
    r4

testValue : Box Int
testValue =
    chain4 42 (Box 0)
```

### Nested wrapper: a inside (List a, Int) from poly caller
```elm
type Entry a
    = MkEntry ( List a, Int ) a

addEntry : a -> Entry a -> Entry a
addEntry x e =
    MkEntry ( [], 0 ) x

collect : a -> a -> Entry a
collect x y =
    let
        e1 =
            addEntry x (MkEntry ( [], 0 ) x)

        e2 =
            addEntry y e1
    in
    e2

testValue : Entry String
testValue =
    collect "a" "b"
```

### Dict-like insert chained 5 times with tuple keys (concrete caller)
```elm
type MyDict k v
    = Empty
    | Entry k v (MyDict k v)

insert : k -> v -> MyDict k v -> MyDict k v
insert key val dict =
    Entry key val dict

size : MyDict k v -> Int
size d =
    case d of
        empty ->
            0

        entry ->
            1

testValue : Int
testValue =
    let
        d0 =
            Empty

        d1 =
            insert ( "k0", 0 ) 0 d0

        d2 =
            insert ( "k1", 1 ) 10 d1

        d3 =
            insert ( "k2", 2 ) 20 d2

        d4 =
            insert ( "k3", 3 ) 30 d3

        d5 =
            insert ( "k4", 4 ) 40 d4
    in
    size d5
```

### Dict-like insert chained 10 times with tuple keys (concrete caller)
```elm
type MyDict k v
    = Empty
    | Entry k v (MyDict k v)

insert : k -> v -> MyDict k v -> MyDict k v
insert key val dict =
    Entry key val dict

size : MyDict k v -> Int
size d =
    case d of
        empty ->
            0

        entry ->
            1

testValue : Int
testValue =
    let
        d0 =
            Empty

        d1 =
            insert ( "k0", 0 ) 0 d0

        d2 =
            insert ( "k1", 1 ) 10 d1

        d3 =
            insert ( "k2", 2 ) 20 d2

        d4 =
            insert ( "k3", 3 ) 30 d3

        d5 =
            insert ( "k4", 4 ) 40 d4

        d6 =
            insert ( "k5", 5 ) 50 d5

        d7 =
            insert ( "k6", 6 ) 60 d6

        d8 =
            insert ( "k7", 7 ) 70 d7

        d9 =
            insert ( "k8", 8 ) 80 d8

        d10 =
            insert ( "k9", 9 ) 90 d9
    in
    size d10
```

### Dict-like insert chained 5 times with (List String) keys (concrete caller)
```elm
type MyDict k v
    = Empty
    | Entry k v (MyDict k v)

insert : k -> v -> MyDict k v -> MyDict k v
insert key val dict =
    Entry key val dict

size : MyDict k v -> Int
size d =
    case d of
        empty ->
            0

        entry ->
            1

testValue : Int
testValue =
    let
        d0 =
            Empty

        d1 =
            insert ( "k0", 0 ) 0 d0

        d2 =
            insert ( "k1", 1 ) 10 d1

        d3 =
            insert ( "k2", 2 ) 20 d2

        d4 =
            insert ( "k3", 3 ) 30 d3

        d5 =
            insert ( "k4", 4 ) 40 d4
    in
    size d5
```

### Nested container: Set of (module, name) pairs with multiple ops
```elm
type MySet a
    = MySet (List a)

type Global
    = Global

singleton : a -> MySet a
singleton x =
    MySet [ x ]

union : MySet a -> MySet a -> MySet a
union s1 s2 =
    s1

count : MySet a -> Int
count s =
    0

testValue : Int
testValue =
    let
        s1 =
            singleton ( [ "0" ], Global )

        s2 =
            singleton ( [ "1" ], Global )

        s3 =
            singleton ( [ "2" ], Global )

        s4 =
            singleton ( [ "3" ], Global )

        s5 =
            singleton ( [ "4" ], Global )

        s6 =
            singleton ( [ "5" ], Global )

        s7 =
            singleton ( [ "6" ], Global )

        s8 =
            singleton ( [ "7" ], Global )
    in
    count (union s1 (union s2 (union s3 (union s4 (union s5 (union s6 (union s7 s8)))))))
```

### Nested container: Graph node with complex key, multiple lookups
```elm
type Global
    = Global

lookup : k -> List ( k, v ) -> v -> v
lookup key pairs default =
    default

testValue : Int
testValue =
    let
        r1 =
            lookup ( [ "mod0" ], Global ) [] 0

        r2 =
            lookup ( [ "mod1" ], Global ) [] 0

        r3 =
            lookup ( [ "mod2" ], Global ) [] 0

        r4 =
            lookup ( [ "mod3" ], Global ) [] 0

        r5 =
            lookup ( [ "mod4" ], Global ) [] 0

        r6 =
            lookup ( [ "mod5" ], Global ) [] 0
    in
    r1
```

### foldl-like called 8 times over tuple-keyed structure
```elm
type Global
    = Global

myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl f init xs =
    init

step : ( List String, Global ) -> Int -> Int
step entry acc =
    acc

testValue : Int
testValue =
    let
        entries =
            []

        r1 =
            myFoldl step 0 entries

        r2 =
            myFoldl step r1 entries

        r3 =
            myFoldl step r2 entries

        r4 =
            myFoldl step r3 entries

        r5 =
            myFoldl step r4 entries

        r6 =
            myFoldl step r5 entries

        r7 =
            myFoldl step r6 entries

        r8 =
            myFoldl step r7 entries
    in
    r8
```

### map-then-fold chain over nested type params
```elm
type Global
    = Global

myFilter : (a -> Bool) -> List a -> List a
myFilter myPred xs =
    xs

myLength : List a -> Int
myLength xs =
    0

isGood : ( List String, Global ) -> Bool
isGood x =
    True

testValue : Int
testValue =
    let
        entries =
            []

        r1 =
            myFilter isGood entries

        r2 =
            myFilter isGood r1

        r3 =
            myFilter isGood r2

        r4 =
            myFilter isGood r3

        r5 =
            myFilter isGood r4

        r6 =
            myFilter isGood r5
    in
    myLength r6
```

### foldl from polymorphic caller (triggers __callee collision)
```elm
myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl f init xs =
    init

summarize : a -> List a -> Int
summarize x xs =
    let
        r1 =
            myFoldl (\elem acc1 -> acc1) 0 xs

        r2 =
            myFoldl (\elem2 acc2 -> acc2) r1 xs

        r3 =
            myFoldl (\elem3 acc3 -> acc3) r2 xs
    in
    r3

testValue : Int
testValue =
    summarize "hello" []
```

## PolyEscapeCases

### Polymorphic identity in record field
```elm
testValue =
    let
        r =
            { fn = \x -> x }
    in
    r.fn 42
```

### Polymorphic lambda in local Maybe.map
```elm
type Maybe a
    = Just a
    | Nothing

maybeMap : (a -> b) -> Maybe a -> Maybe b
maybeMap f m =
    case m of
        Just x ->
            Just (f x)

        Nothing ->
            Nothing

testValue : Int
testValue =
    case maybeMap (\x -> x) (Just 1) of
        Just n ->
            n

        Nothing ->
            0
```

### Nested polymorphic closures with different types
```elm
testValue =
    let
        f x =
            let
                g y =
                    ( x, y )
            in
            g
    in
    (f 1) "a"
```

### Polymorphic flip with mixed types
```elm
testValue =
    let
        flip f a b =
            f b a
    in
    flip (\x y -> x) 1 "a"
```

### Record update narrowing polymorphic field
```elm
testValue =
    let
        r =
            { f = \x -> x, g = 0 }

        r2 =
            { r | f = \y -> y + 1 }
    in
    r2.f 5
```

### Polymorphic function extracted from tuple
```elm
testValue =
    let
        id x =
            x

        first t =
            case t of
                ( fst, _ ) ->
                    fst
    in
    (first ( id, 0 )) 42
```

---

# Part 7: TailRecCase, TailRecLetRecClosure, LocalTailRec, DecisionTreeAdvanced, RecursiveType, MonoCompound

## TailRecCaseCases

### Tail-rec foldl with case on list
```elm
testValue =
    let
        myFoldl f acc list =
            case list of
                [] ->
                    acc

                x :: xs ->
                    myFoldl f (f x acc) xs
    in
    myFoldl (\a b -> a + b) 0 [1, 2, 3]
```

### Tail-rec contains with if in case branch
```elm
testValue =
    let
        contains target list =
            case list of
                [] ->
                    False

                x :: rest ->
                    if x == target then
                        True
                    else
                        contains target rest
    in
    contains 3 [1, 2, 3]
```

### Tail-rec sum with custom type
```elm
type MyList a
    = Empty
    | Node a (MyList a)

sumMyList : Int -> MyList Int -> Int
sumMyList acc list =
    case list of
        Empty ->
            acc

        Node x rest ->
            sumMyList (acc + x) rest

testValue : Int
testValue =
    sumMyList 0 (Node 1 (Node 2 Empty))
```

### Tail-rec with nested case
```elm
testValue =
    let
        myLast default list =
            case list of
                [] ->
                    default

                x :: rest ->
                    case rest of
                        [] ->
                            x

                        _ ->
                            myLast default rest
    in
    myLast 0 [1, 2, 3]
```

### Tail-rec with wildcard destruct
```elm
testValue =
    let
        count acc list =
            case list of
                [] ->
                    acc

                _ :: rest ->
                    count (acc + 1) rest
    in
    count 0 [10, 20, 30]
```

## TailRecLetRecClosureCases

### Local recursive closure in tail-rec case branch
```elm
type Item
    = Num Int
    | Blank

processItems : Int -> List Item -> List Int
processItems threshold items =
    case items of
        [] ->
            []

        (Num n) :: rest ->
            let
                takeMore xs =
                    case xs of
                        (Num m) :: ys ->
                            m :: takeMore ys

                        _ ->
                            []

                collected =
                    takeMore rest
            in
            n :: collected

        (Blank) :: rest ->
            processItems threshold rest

testValue : List Int
testValue =
    processItems 0 [Num 1, Num 2, Blank]
```

### Local recursive closure capturing outer param
```elm
process : Int -> List Int -> List Int
process threshold items =
    case items of
        [] ->
            []

        x :: rest ->
            let
                helper ys =
                    case ys of
                        y :: zs ->
                            y :: helper zs

                        _ ->
                            []
            in
            x :: helper rest

        _ ->
            process threshold []

testValue : List Int
testValue =
    process 0 [1, 2, 3]
```

## LocalTailRecCases

### Simple local tail-rec sumUpTo
```elm
testValue =
    let
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)
    in
    sumUpTo 10 0
```

### Outer tail-rec with local tail-rec def
```elm
outerLoop : Int -> Int -> Int
outerLoop n acc =
    let
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)

        localResult =
            sumUpTo n 0
    in
    case localResult of
        0 ->
            acc

        _ ->
            outerLoop (n - 1) (acc + localResult)

testValue : Int
testValue =
    outerLoop 10 0
```

### Local tail-rec with captured outer variable
```elm
process : Int -> Int
process x =
    let
        loop i acc =
            if i <= 0 then
                acc
            else
                loop (i - 1) (acc + x)
    in
    loop x 0

testValue : Int
testValue =
    process 5
```

### Multiple local tail-rec defs in same let
```elm
testValue =
    let
        countDown i =
            if i <= 0 then
                0
            else
                countDown (i - 1)

        sumUp i acc =
            if i <= 0 then
                acc
            else
                sumUp (i - 1) (acc + i)
    in
    countDown 5 + sumUp 5 0
```

### Nested local tail-rec (tail-rec inside tail-rec body)
```elm
testValue =
    let
        outer n =
            let
                inner i acc =
                    if i <= 0 then
                        acc
                    else
                        inner (i - 1) (acc + 1)
            in
            if n <= 0 then
                0
            else
                inner n 0 + outer (n - 1)
    in
    outer 5
```

## DecisionTreeAdvancedCases

### Single constructor
```elm
type MyUnit
    = MyUnit

f : MyUnit -> Int
f u =
    case u of
        MyUnit ->
            42

testValue : Int
testValue =
    f MyUnit
```

### Two constructors
```elm
type Bool2
    = True2
    | False2

toBool : Bool2 -> Bool
toBool b =
    case b of
        True2 ->
            True

        False2 ->
            False

testValue : Bool
testValue =
    toBool True2
```

### Three constructors
```elm
type Color
    = Red
    | Green
    | Blue

toInt : Color -> Int
toInt c =
    case c of
        Red ->
            0

        Green ->
            1

        Blue ->
            2

testValue : Int
testValue =
    toInt Green
```

### Constructor with one arg
```elm
type Box
    = Box Int

unbox : Box -> Int
unbox b =
    case b of
        Box x ->
            x

testValue : Int
testValue =
    unbox (Box 99)
```

### Constructor with multiple args
```elm
type Pair
    = Pair Int Int

sum : Pair -> Int
sum p =
    case p of
        Pair a b ->
            a + b

testValue : Int
testValue =
    sum (Pair 3 4)
```

### Nested constructor
```elm
type Box
    = Box Int

type Wrap
    = Wrap Box

unwrap : Wrap -> Int
unwrap w =
    case w of
        Wrap (Box x) ->
            x

testValue : Int
testValue =
    unwrap (Wrap (Box 42))
```

### Maybe Just pattern
```elm
withDefault : Int -> Maybe Int -> Int
withDefault default m =
    case m of
        Just x ->
            x

        Nothing ->
            default

testValue : Int
testValue =
    withDefault 0 (Just 5)
```

### Maybe Nothing pattern
```elm
isNothing : Maybe Int -> Bool
isNothing m =
    case m of
        Nothing ->
            True

        Just _ ->
            False

testValue : Bool
testValue =
    isNothing Nothing
```

### Singleton list pattern
```elm
isSingleton : List Int -> Bool
isSingleton xs =
    case xs of
        [_] ->
            True

        _ ->
            False

testValue : Bool
testValue =
    isSingleton [1]
```

### Two element list pattern
```elm
sumTwo : List Int -> Int
sumTwo xs =
    case xs of
        [a, b] ->
            a + b

        _ ->
            0

testValue : Int
testValue =
    sumTwo [3, 4]
```

### Multiple cons pattern
```elm
sumFirstTwo : List Int -> Int
sumFirstTwo xs =
    case xs of
        a :: b :: _ ->
            a + b

        _ ->
            0

testValue : Int
testValue =
    sumFirstTwo [5, 6, 7]
```

### List pattern with fallback
```elm
classify : List Int -> String
classify xs =
    case xs of
        [] ->
            "empty"

        [_] ->
            "one"

        [_, _] ->
            "two"

        _ ->
            "many"

testValue : String
testValue =
    classify [1, 2, 3, 4]
```

### Int literal pattern
```elm
isZero : Int -> Bool
isZero n =
    case n of
        0 ->
            True

        _ ->
            False

testValue : Bool
testValue =
    isZero 0
```

### Multiple int patterns
```elm
describe : Int -> String
describe n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"

        2 ->
            "two"

        3 ->
            "three"

        _ ->
            "other"

testValue : String
testValue =
    describe 2
```

### Multiple char patterns
```elm
charType : Char -> Int
charType c =
    case c of
        '0' ->
            0

        '1' ->
            1

        '2' ->
            2

        '3' ->
            3

        '4' ->
            4

        '5' ->
            5

        _ ->
            -1

testValue : Int
testValue =
    charType '3'
```

### Unit pattern
```elm
testValue =
    let
        result () =
            42
    in
    result ()
```

### Tuple3 pattern
```elm
testValue =
    let
        sumTriple t =
            case t of
                (a, b, c) ->
                    a + b + c
    in
    sumTriple (1, 2, 3)
```

### Tuple with literals
```elm
checkPair : ( Int, Int ) -> String
checkPair t =
    case t of
        ( 0, 0 ) ->
            "origin"

        ( 0, _ ) ->
            "y-axis"

        ( _, 0 ) ->
            "x-axis"

        _ ->
            "other"

testValue : String
testValue =
    checkPair ( 0, 5 )
```

### Simple record pattern
```elm
testValue =
    let
        getX { x } =
            x
    in
    getX { x = 10 }
```

### Multi-field record pattern
```elm
testValue =
    let
        sumXY { x, y } =
            x + y
    in
    sumXY { x = 3, y = 4 }
```

### Partial record pattern
```elm
testValue =
    let
        getA { a } =
            a
    in
    getA { a = 1, b = 2 }
```

### Nested record pattern
```elm
testValue =
    let
        extract { outer } =
            outer
    in
    extract { outer = 99 }
```

### Wildcard pattern
```elm
always : Int -> Int -> Int
always x _ =
    x

testValue : Int
testValue =
    always 42 0
```

### Variable pattern
```elm
id : Int -> Int
id x =
    x

testValue : Int
testValue =
    id 123
```

### Mixed wildcard and var
```elm
first : ( Int, Int ) -> Int
first ( a, _ ) =
    a

testValue : Int
testValue =
    first ( 1, 2 )
```

### All wildcards
```elm
ignore : Int -> Int -> Int
ignore _ _ =
    0

testValue : Int
testValue =
    ignore 1 2
```

### Simple alias pattern
```elm
useAlias : Int -> Int
useAlias (x as whole) =
    x + whole

testValue : Int
testValue =
    useAlias 5
```

### Alias with constructor
```elm
extractWithAlias : Maybe Int -> Int
extractWithAlias m =
    case m of
        (Just x) as whole ->
            x

        Nothing ->
            0

testValue : Int
testValue =
    extractWithAlias (Just 42)
```

### Alias with tuple
```elm
sumWithAlias : ( Int, Int ) -> Int
sumWithAlias (( a, b ) as pair) =
    a + b

testValue : Int
testValue =
    sumWithAlias ( 3, 7 )
```

### Deeply nested constructor
```elm
type Nest
    = Leaf Int
    | Node Nest Nest

extractLeft : Nest -> Int
extractLeft n =
    case n of
        Leaf x ->
            x

        Node (Leaf x) _ ->
            x

        _ ->
            0

testValue : Int
testValue =
    extractLeft (Leaf 99)
```

### List of tuples pattern
```elm
firstPairSum : List ( Int, Int ) -> Int
firstPairSum xs =
    case xs of
        ( a, b ) :: _ ->
            a + b

        [] ->
            0

testValue : Int
testValue =
    firstPairSum [( 2, 3 )]
```

### Tuple of lists pattern
```elm
bothHeads : ( List Int, List Int ) -> Int
bothHeads t =
    case t of
        ( a :: _, b :: _ ) ->
            a + b

        _ ->
            0

testValue : Int
testValue =
    bothHeads ( [1], [2] )
```

### Constructor with list
```elm
type Container
    = Container (List Int)

headOfContainer : Container -> Int
headOfContainer c =
    case c of
        Container (x :: _) ->
            x

        Container [] ->
            0

testValue : Int
testValue =
    headOfContainer (Container [42])
```

### Multiple fallbacks
```elm
classify : ( Int, Int ) -> String
classify t =
    case t of
        ( 0, 0 ) ->
            "origin"

        ( 0, _ ) ->
            "y-axis"

        ( _, 0 ) ->
            "x-axis"

        ( 1, 1 ) ->
            "unit"

        _ ->
            "general"

testValue : String
testValue =
    classify ( 5, 5 )
```

### Overlapping patterns
```elm
match : ( Maybe Int, Maybe Int ) -> Int
match t =
    case t of
        ( Just a, Just b ) ->
            a + b

        ( Just a, Nothing ) ->
            a

        ( Nothing, Just b ) ->
            b

        ( Nothing, Nothing ) ->
            0

testValue : Int
testValue =
    match ( Just 3, Just 4 )
```

### Many branches
```elm
type Day
    = Mon
    | Tue
    | Wed
    | Thu
    | Fri
    | Sat
    | Sun

isWeekend : Day -> Bool
isWeekend d =
    case d of
        Mon ->
            False

        Tue ->
            False

        Wed ->
            False

        Thu ->
            False

        Fri ->
            False

        Sat ->
            True

        Sun ->
            True

testValue : Bool
testValue =
    isWeekend Sat
```

### Deep nesting with fallback
```elm
extract : ( ( Int, Int ), ( Int, Int ) ) -> Int
extract t =
    case t of
        ( ( 0, 0 ), ( 0, 0 ) ) ->
            0

        ( ( a, _ ), ( _, d ) ) ->
            a + d

testValue : Int
testValue =
    extract ( ( 1, 2 ), ( 3, 4 ) )
```

### Empty union case
```elm
type Void
    = Void

absurd : Void -> Int
absurd v =
    case v of
        Void ->
            0

testValue : Int
testValue =
    absurd Void
```

### Single branch case
```elm
testValue =
    case 42 of
        _ ->
            0
```

### Redundant wildcard
```elm
testValue =
    case 5 of
        1 ->
            10

        2 ->
            20

        n ->
            n
```

## RecursiveTypeCases

### Direct recursive type: binary tree
```elm
type Tree a
    = Leaf a
    | Branch (Tree a) (Tree a)

depth : Tree a -> Int
depth t =
    case t of
        leaf ->
            0

        branch ->
            1

testValue : Int
testValue =
    depth (Leaf 42)
```

### Direct recursive type: linked list custom type
```elm
type LinkedList a
    = Empty
    | Cons a (LinkedList a)

len : LinkedList a -> Int
len xs =
    case xs of
        nil ->
            0

        cons ->
            1

testValue : Int
testValue =
    len (Empty)
```

### Mutually recursive types: Forest/Tree
```elm
type Forest a
    = Forest (List (RoseTree a))

type RoseTree a
    = RoseNode a (Forest a)

countNodes : Forest a -> Int
countNodes f =
    0

testValue : Int
testValue =
    countNodes (Forest [])
```

### Recursive type nested in tuple
```elm
type Crumb a
    = Crumb a (List (Pair a))

type Pair a
    = MkPair (Crumb a) Int

size : Crumb a -> Int
size c =
    0

testValue : Int
testValue =
    size (Crumb 1 [])
```

### Recursive type nested in record
```elm
type Expr a
    = Lit a
    | Compound { tag : Int, children : List (Expr a) }

eval : Expr a -> Int
eval e =
    case e of
        lit ->
            0

        compound ->
            1

testValue : Int
testValue =
    eval (Lit 42)
```

### Recursive type nested in type alias
```elm
type Container a
    = Box { value : a, next : Maybe (Container a) }

type Maybe a
    = Just a
    | Nothing

depth : Container a -> Int
depth c =
    0

testValue : Int
testValue =
    depth (Box { value = 1, next = Nothing })
```

## MonoCompoundCases

### poly record builder
```elm
makeRec : a -> b -> { first : a, second : b }
makeRec x y =
    { first = x, second = y }

testValue : { first : Int, second : String }
testValue =
    makeRec 1 "hello"
```

### poly tuple builder
```elm
swap : ( a, b ) -> ( b, a )
swap ( x, y ) =
    ( y, x )

testValue : ( String, Int )
testValue =
    swap ( 42, "answer" )
```

### record update in let
```elm
increment : { x : Int, y : Int } -> { x : Int, y : Int }
increment r =
    { r | x = r.x + 1 }

testValue : { x : Int, y : Int }
testValue =
    let
        p =
            { x = 0, y = 10 }
    in
    increment p
```

### unused poly function (prune)
```elm
unusedId : a -> a
unusedId x =
    x

used : Int -> Int
used n =
    n + 1

testValue : Int
testValue =
    used 5
```

### list of records
```elm
testValue : List { x : Int }
testValue =
    [{ x = 1 }, { x = 2 }, { x = 3 }]
```

### nested maybe pattern
```elm
type MyMaybe a
    = MyJust a
    | MyNothing

fromMyMaybe : a -> MyMaybe a -> a
fromMyMaybe default m =
    case m of
        MyJust val ->
            val

        MyNothing ->
            default

testValue : Int
testValue =
    fromMyMaybe 0 (MyJust 42)
```

### poly function with record arg
```elm
getFirst : { first : a, second : b } -> a
getFirst r =
    r.first

testValue : Int
testValue =
    getFirst { first = 99, second = "ignore" }
```

### multi-field record specialization
```elm
wrap3 : a -> b -> c -> { x : a, y : b, z : c }
wrap3 a b c =
    { x = a, y = b, z = c }

testValue : { x : Int, y : String, z : Int }
testValue =
    wrap3 1 "mid" 3
```

### tuple in list specialization
```elm
testValue : List ( Int, String )
testValue =
    [( 1, "one" ), ( 2, "two" )]
```

### poly function three specializations
```elm
wrap : a -> List a
wrap x =
    [x]

testValue : List Int
testValue =
    let
        ints =
            wrap 1

        strs =
            wrap "hi"

        bools =
            wrap True
    in
    ints
```

### custom type with poly field
```elm
type Pair a b
    = MkPair a b

fstPair : Pair a b -> a
fstPair p =
    case p of
        MkPair x _ ->
            x

testValue : Int
testValue =
    fstPair (MkPair 10 "world")
```

### nested let with shadowing
```elm
testValue : Int
testValue =
    let
        x =
            1
    in
    let
        y =
            x + 2
    in
    let
        z =
            y * 3
    in
    z
```

---

# SourceIR Test Cases - Elm Source Translations

## AnnotatedCases

### Identity with annotation
```elm
identity : a -> a
identity x = x

testValue : Int
testValue = identity 1
```

### Const with annotation
```elm
const : a -> b -> a
const x y = x

testValue : Int
testValue = const 42 "hello"
```

### Bool identity
```elm
boolIdentity : Bool -> Bool
boolIdentity x = x

testValue : Bool
testValue = boolIdentity True
```

### Apply with usage
```elm
apply : (a -> b) -> a -> b
apply f x = f x

test : Bool
test = apply (\n -> n) True

testValue : String
testValue = apply (\n -> n) "hello"
```

### Flip function
```elm
flip : (a -> b -> c) -> b -> a -> c
flip f y x = f x y

testValue : Float
testValue = flip (\a b -> 3.14) "world" 7
```

### Compose with usage
```elm
compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

test : Bool
test = compose (\x -> x) (\y -> y) True

testValue : String
testValue = compose (\x -> "result") (\y -> 1) 42
```

### On function
```elm
on : (b -> b -> c) -> (a -> b) -> a -> a -> c
on f g x y = f (g x) (g y)

testValue : Float
testValue = on (\a b -> 1.0) (\a -> "x") 1 2
```

### Pair function
```elm
pair : a -> b -> ( a, b )
pair x y = ( x, y )

testValue : ( Int, String )
testValue = pair 1 "hello"
```

### Wrap in tuple
```elm
wrapInTuple : a -> ( a, a )
wrapInTuple x = ( x, x )

testValue : ( Float, Float )
testValue = wrapInTuple 2.5
```

### Const tuple
```elm
constTuple : a -> b -> ( a, a )
constTuple x y = ( x, x )

testValue : ( Int, Int )
testValue = constTuple 5 "ignored"
```

### Make record
```elm
makeXY : a -> b -> { x : a, y : b }
makeXY x y = { x = x, y = y }

testValue : { x : Int, y : String }
testValue = makeXY 10 "world"
```

### Make record with same type
```elm
makeSame : a -> { x : a, y : a }
makeSame val = { x = val, y = val }

testValue : { x : Float, y : Float }
testValue = makeSame 9.9
```

### Nest tuple
```elm
nest : a -> b -> ( ( a, b ), ( b, a ) )
nest x y = ( ( x, y ), ( y, x ) )

testValue : ( ( Int, String ), ( String, Int ) )
testValue = nest 3 "abc"
```

---

## BitwiseCases

### Bitwise.and
```elm
testValue : Int
testValue = Bitwise.and 65280 3855
```

### Bitwise.or
```elm
testValue : Int
testValue = Bitwise.or 240 15
```

### Bitwise.xor
```elm
testValue : Int
testValue = Bitwise.xor 255 15
```

### Bitwise.complement
```elm
testValue : Int
testValue = Bitwise.complement 0
```

### Bitwise.shiftLeftBy
```elm
testValue : Int
testValue = Bitwise.shiftLeftBy 4 1
```

### Bitwise.shiftRightBy
```elm
testValue : Int
testValue = Bitwise.shiftRightBy 2 16
```

### Bitwise.shiftRightZfBy
```elm
testValue : Int
testValue = Bitwise.shiftRightZfBy 2 (-8)
```

### Multiple shifts
```elm
testValue : Int
testValue = Bitwise.shiftRightBy 2 (Bitwise.shiftLeftBy 4 1)
```

### And with Or
```elm
testValue : Int
testValue = Bitwise.and (Bitwise.or 240 15) 255
```

### Xor with complement
```elm
testValue : Int
testValue = Bitwise.xor 255 (Bitwise.complement 0)
```

### Complex bitwise expression
```elm
testValue : Int
testValue = Bitwise.and (Bitwise.or 240 15) (Bitwise.complement 0)
```

### Mask extraction pattern
```elm
testValue : Int
testValue = Bitwise.and (Bitwise.shiftRightBy 4 43981) 15
```

### setBit function
```elm
setBit : Int -> Int -> Int
setBit bit n = Bitwise.or n (Bitwise.shiftLeftBy bit 1)

testValue : Int
testValue = setBit 3 0
```

### clearBit function
```elm
clearBit : Int -> Int -> Int
clearBit bit n = Bitwise.and n (Bitwise.complement (Bitwise.shiftLeftBy bit 1))

testValue : Int
testValue = clearBit 3 255
```

### toggleBit function
```elm
toggleBit : Int -> Int -> Int
toggleBit bit n = Bitwise.xor n (Bitwise.shiftLeftBy bit 1)

testValue : Int
testValue = toggleBit 3 255
```

### testBit function
```elm
testBit : Int -> Int -> Int
testBit bit n = Bitwise.and (Bitwise.shiftRightBy bit n) 1

testValue : Int
testValue = testBit 3 255
```

### Bitwise with conditional
```elm
conditionalBit : Int -> Int -> Int
conditionalBit flag n = if flag > 0 then Bitwise.or n 1 else Bitwise.and n (Bitwise.complement 1)

testValue : Int
testValue = conditionalBit 1 254
```

### Rotate left pattern
```elm
rotateLeft8 : Int -> Int -> Int
rotateLeft8 n amount =
    Bitwise.or
        (Bitwise.and (Bitwise.shiftLeftBy amount n) 255)
        (Bitwise.shiftRightZfBy (8 - amount) (Bitwise.and n 255))

testValue : Int
testValue = rotateLeft8 129 1
```

### Extract byte pattern
```elm
extractByte : Int -> Int -> Int
extractByte byteIndex n = Bitwise.and (Bitwise.shiftRightBy (byteIndex * 8) n) 255

testValue : Int
testValue = extractByte 1 43981
```

### Pack bytes pattern
```elm
packBytes : Int -> Int -> Int
packBytes high low =
    Bitwise.or
        (Bitwise.shiftLeftBy 8 (Bitwise.and high 255))
        (Bitwise.and low 255)

testValue : Int
testValue = packBytes 171 205
```

---

## EdgeCaseCases

### Parens around literal
```elm
testValue = (42)
```

### Parens around binop
```elm
testValue = (1 + 2) * 3
```

### Nested parens
```elm
testValue = (((1)))
```

### Parens around lambda
```elm
testFn = (\x -> x)
testValue = testFn 1
```

### Nested record updates
```elm
testValue =
    let
        r = { x = 1, y = 2 }
        r2 = { r | x = 10 }
    in
    { r2 | y = 20 }
```

### Lambda in record update
```elm
testValue =
    let
        r = { fn = \x -> 0 }
    in
    { r | fn = \x -> x }
```

### Case in if
```elm
testValue =
    if True then
        case 1 of
            n -> n
    else
        0
```

### If in case
```elm
testValue =
    case 1 of
        n -> if True then n else 0
```

### Multiple accessors in list
```elm
testValue = [ .a, .b, .c, .d ]
```

### Empty record
```elm
testValue = {}
```

### Empty list
```elm
testValue = []
```

### Unit expression
```elm
testValue = ()
```

### Deeply nested lists
```elm
testValue = [[[[ 1 ]]]]
```

### Deeply nested tuples
```elm
testValue = ((((1, 2), 3), 4), 5)
```

### Deeply nested lets
```elm
testValue =
    let a = 1
    in let b = 2
    in let c = 3
    in let d = 4
    in d
```

### Deeply nested records
```elm
testValue = { nested = { nested = { nested = { value = 1 } } } }
```

### Multiple pattern types in one function
```elm
testValue =
    let
        complex a (b, c) { d, e } (f :: _) (g as h) =
            [ a, b, d, f, g ]
    in
    complex
```

### All destruct patterns
```elm
testValue =
    let
        (a, b) = (1, 2)
        { x } = { x = 3 }
        (h :: t) = [4, 5]
        (v as w) = 6
    in
    [a, x, h, v]
```

### Multiple definitions with various patterns
```elm
f1 x = x
f2 (a, b) = a
f3 { name } = name
f4 _ = 0
f5 a b c = b
testValue =
    ( ( f1 1, f1 "hi" )
    , ( ( f2 (2, 3), f3 { name = "hello" } )
      , ( f4 99, f5 10 "mid" 30 )
      )
    )
```

### Complex expression with fixed values
```elm
testValue = ({ values = [1, 2, 3] }, (1, 2, 3))
```

### Mixed types with fixed values
```elm
testValue =
    let
        r = { name = "hello", count = 42 }
    in
    (r.name, r.count)
```

---

## ForeignCases

Note: ForeignCases uses the *Canonical* AST builder (not Source), constructing pre-canonicalized AST nodes with VarForeign references. The equivalent Elm source is shown below.

### VarForeign identity
```elm
testValue = Basics.identity
```

### VarForeign const
```elm
testValue = Basics.always
```

### Call identity on int
```elm
testValue = Basics.identity 42
```

### Call const on int and int
```elm
testValue = Basics.always 1 2
```

### Typed def using foreign identity
```elm
apply : (a -> b) -> a -> b
apply f x = Basics.identity (f x)
```

### Nested foreign calls
```elm
testValue = Basics.identity (Basics.identity 42)
```

---

## MultiDefCases

### Two identical structure definitions
```elm
a = 1 + 2
b = 1 + 2
testValue = (a, b)
```

### Three simple value definitions
```elm
a = 1
b = 2
c = 3
testValue = (a, b, c)
```

### Multiple function definitions with same arity
```elm
f x = x + 1
g y = y * 2
testValue = (f 1, g 2)
```

### Multiple function definitions with different arities
```elm
a = 42
f x = x
g x y = x + y
h x y z = x + y + z
testValue = ((a, f 1), (g 1 2, h 1 2 3))
```

### Functions that call each other
```elm
f x = g x
g y = y + 1
testValue = f 1
```

### Multiple definitions with let expressions
```elm
a = let x = 1 in x
b = let y = 2 in y
testValue = (a, b)
```

### Multiple definitions with case expressions
```elm
f x = case x of
    0 -> 1
    _ -> 2
g y = case y of
    0 -> 3
    _ -> 4
testValue = (f 1, g 2)
```

### Multiple definitions with if expressions
```elm
a = if True then 1 else 2
b = if True then 3 else 4
c = if True then 5 else 6
testValue = (a, b, c)
```

### Multiple definitions with lambdas
```elm
f = \x -> x
g = \y -> y + 1
h = \a b -> a + b
testValue = (f 1, g 2, h 3 4)
```

### Multiple definitions with records
```elm
a = { x = 1 }
b = { y = 2, z = 3 }
c = { p = 4, q = 5, r = 6 }
testValue = (a, b, c)
```

### Multiple definitions with binary operators
```elm
a = 1 + 2
b = 3 * 4
c = 5 - 6
d = 7 / 8
testValue = ((a, b), (c, d))
```

### Large module with many definitions
```elm
def1 = 1
def2 = 2
def3 = 3
def4 = 1 + 2
def5 = 3 * 4
def6 x = x
def7 x = x + 1
def8 = let a = 1 in a
def9 = if True then 1 else 2
def10 = { x = 1 }
def11 = (1, 2)
def12 = [1, 2, 3]
def13 = \n -> n
def14 a b = a + b
def15 = "hello"
testValue =
    ( ( (def1, def2, def3), (def4, def5, def6 1) )
    , ( (def7 1, def8, def9)
      , ( (def10, def11, def12)
        , (def13 1, def14 1 2, def15)
        , 0
        )
      )
    )
```

### Definitions with nested lets
```elm
a = let x = (let y = 1 in y) in x
b = let p = (let q = 2 in q) in p
testValue = (a, b)
```

### Definitions with tuple patterns
```elm
f (a, b) = a + b
g (x, y) = x * y
testValue = (f (1, 2), g (3, 4))
```

### Definitions with list patterns
```elm
f [a] = a
g [x, y] = x + y
testValue = (f [1], g [2, 3])
```

### Definitions with record patterns
```elm
f { x } = x
g { a, b } = a + b
testValue = (f { x = 1 }, g { a = 2, b = 3 })
```

### Mixed expressions and patterns across definitions
```elm
value = 42
func x = x + 1
withLet = let a = 1 in a
withCase n = case n of
    0 -> 0
    _ -> 1
withIf b = if b then 1 else 2
withLambda = \x y -> x + y
withRecord = { x = 1, y = 2 }
withTuple (a, b) = (a, b)
testValue =
    ( ( (value, func 1), (withLet, withCase 0) )
    , ( (withIf True, withLambda 1 2), (withRecord, withTuple (1, 2)) )
    )
```

---

## ParamArityCases

### HO param: apply f a b
```elm
testValue =
    let
        applyTwo f a b = f a b
    in
    applyTwo (\x y -> x) 1 2
```

### HO param: flip f b a
```elm
testValue =
    let
        flip f b a = f a b
    in
    flip (\x y -> x) 10 3
```

### HO param: single-arg apply
```elm
testValue =
    let
        applyOne f x = f x
    in
    applyOne (\y -> y) 42
```

### Captured param: inner closure calls captured f
```elm
testValue =
    let
        withF f x =
            let g y = f y
            in g x
    in
    withF (\z -> z) 7
```

### Captured param: two-arg captured function
```elm
testValue =
    let
        mapPair f k v = (k, f k v)
    in
    mapPair (\a b -> a) 1 2
```

### Local PAP: let p1 = f x in p1 y
```elm
testValue =
    let
        makeP1 f x y =
            let p1 = f x
            in p1 y
    in
    makeP1 (\a b -> a) 5 10
```

### Local PAP: let p1 = add 5 in p1 10
```elm
testValue =
    let
        add x y = x
    in
    let
        add5 = add 5
    in
    add5 10
```

---

## JoinpointABICases

### 1.1 identicalFlat2
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b -> a + b
    _ -> \a b -> a - b

testValue : Int
testValue = caseFunc 0 5 3
```

### 1.2 identicalCurried11
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a -> \b -> a + b
    _ -> \a -> \b -> a - b

testValue : Int
testValue = (caseFunc 0 5) 3
```

### 1.3 identicalFlat3
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b c -> a + b + c
    _ -> \a b c -> a - b - c

testValue : Int
testValue = caseFunc 0 5 3 2
```

### 1.4 identicalCurried111
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a -> \b -> \c -> a + b + c
    _ -> \a -> \b -> \c -> a - b - c

testValue : Int
testValue = ((caseFunc 0 5) 3) 2
```

### 1.5 identicalMixed21
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b -> \c -> a + b + c
    _ -> \a b -> \c -> a - b - c

testValue : Int
testValue = (caseFunc 0 5 3) 2
```

### 1.6 nonFunctionBranches
```elm
caseFunc : Int -> Int
caseFunc x = case x of
    0 -> 1
    1 -> 2
    _ -> 3

testValue : Int
testValue = caseFunc 0
```

### 2.1 majority2Flat
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b -> a + b
    1 -> \a b -> a - b
    _ -> \a -> \b -> a * b

testValue : Int
testValue = caseFunc 0 5 3
```

### 2.2 majority2Curried
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b -> a + b
    1 -> \a -> \b -> a - b
    _ -> \a -> \b -> a * b

testValue : Int
testValue = (caseFunc 0 5) 3
```

### 2.3 majority3Flat
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b c -> a + b + c
    1 -> \a b c -> a - b - c
    2 -> \a b c -> a * b * c
    _ -> \a -> \b -> \c -> a + b - c

testValue : Int
testValue = caseFunc 0 5 3 2
```

### 2.4 majorityMixed
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b -> \c -> a + b + c
    1 -> \a b -> \c -> a - b - c
    2 -> \a -> \b c -> a * b * c
    _ -> \a b c -> a + b - c

testValue : Int
testValue = (caseFunc 0 5 3) 2
```

### 3.1 tieBreakBinary
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc n = case n of
    0 -> \a x -> a + x
    _ -> \a -> \x -> a - x

testValue : Int
testValue = caseFunc 0 5 3
```

### 3.2 tieBreakTernary
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b c -> a + b + c
    1 -> \a b -> \c -> a - b - c
    _ -> \a -> \b -> \c -> a * b * c

testValue : Int
testValue = caseFunc 0 5 3 2
```

### 3.3 tieBreakQuaternary
```elm
caseFunc : Int -> Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b c d -> a + b + c + d
    1 -> \a b -> \c d -> a - b - c - d
    _ -> \a -> \b -> \c -> \d -> a * b * c * d

testValue : Int
testValue = caseFunc 0 5 3 2 1
```

### 3.4 tieEqualDepth
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc n = case n of
    0 -> \a b -> \c -> a + b + c
    _ -> \a -> \b c -> a - b - c

testValue : Int
testValue = (caseFunc 0 5 3) 2
```

### 4.1 nestedCaseInBranch
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x y = case x of
    0 -> case y of
        0 -> \a -> a + 1
        _ -> \a -> a - 1
    _ -> \a -> a * 2

testValue : Int
testValue = caseFunc 0 0 5
```

### 4.2 ifInCaseBranch
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc n m = case n of
    0 -> case m of
        0 -> \a -> a + 1
        _ -> \a -> a - 1
    _ -> \a -> a * 2

testValue : Int
testValue = caseFunc 0 0 5
```

### 4.3 letFunctionInBranch
```elm
caseFunc : Int -> Int -> Int
caseFunc n = case n of
    0 -> let f = \a -> a + 1 in f
    _ -> \a -> a * 2

testValue : Int
testValue = caseFunc 0 5
```

### 4.4 letSeparatedStaging
```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc n k = case n of
    0 -> \a -> let y = a + k in \z -> y + z
    _ -> \a z -> a + z

testValue : Int
testValue = (caseFunc 0 10 5) 3
```

### 4.5 deeplyNestedControl
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x m = case x of
    0 -> case m of
        0 -> let k = 10 in \a -> a + k
        _ -> \a -> a - 5
    _ -> \a -> a * 2

testValue : Int
testValue = caseFunc 0 0 5
```

### 4.6 caseInBothBranches
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc x y = case x of
    0 -> case y of
        0 -> \a -> a + 1
        _ -> \a -> a + 2
    _ -> case y of
        0 -> \a -> a - 1
        _ -> \a -> a - 2

testValue : Int
testValue = caseFunc 0 1 5
```

### 5.2 wildcardOnlyCase
```elm
caseFunc : Int -> Int -> Int
caseFunc x = case x of
    _ -> \a -> a + 1

testValue : Int
testValue = caseFunc 42 5
```

### 5.3 highArityFunction
```elm
caseFunc : Int -> Int -> Int -> Int -> Int -> Int -> Int
caseFunc x = case x of
    0 -> \a b c d e -> a + b + c + d + e
    1 -> \a b c -> \d e -> a - b - c - d - e
    2 -> \a b -> \c d -> \e -> a * b * c * d * e
    _ -> \a -> \b -> \c -> \d -> \e -> a + b - c * d + e

testValue : Int
testValue = caseFunc 0 1 2 3 4 5
```

### 5.4 recordPatternBranches
```elm
caseFunc : Int -> Int -> Int -> Int
caseFunc n = case n of
    0 -> \x y -> x + y
    _ -> \x -> \y -> x - y

testValue : Int
testValue = caseFunc 0 5 3
```

### 5.5 customTypeBranches
```elm
type MaybeInt = JustInt Int | NothingInt

caseFunc : MaybeInt -> Int -> Int
caseFunc mx = case mx of
    JustInt n -> \a -> a + n
    NothingInt -> \a -> a * 0

testValue : Int
testValue = caseFunc (JustInt 10) 5
```

### 5.6 listPatternBranches
```elm
caseFunc : List Int -> Int -> Int
caseFunc xs = case xs of
    [] -> \a -> a
    h :: t -> \a -> a + h

testValue : Int
testValue = caseFunc [10, 20] 5
```

---

## PostSolveExprCases

### String literal type
```elm
testValue = "hello world"
```

### Char literal type
```elm
testValue = 'x'
```

### Float literal type
```elm
testValue = 3.14159
```

### Unit literal type
```elm
testValue = ()
```

### Int literal type
```elm
testValue = 42
```

### Bool literal type
```elm
testValue = True
```

### Empty list type
```elm
testValue : List Int
testValue = []
```

### Singleton list type
```elm
testValue = [1]
```

### Multiple element list type
```elm
testValue = [1, 2, 3]
```

### Tuple2 type
```elm
testValue = (1, "hello")
```

### Tuple3 type
```elm
testValue = (1, "hello", True)
```

### Simple record type
```elm
testValue = { x = 10 }
```

### Nested record type
```elm
testValue = { outer = { inner = 42 } }
```

### Multi-field record type
```elm
testValue = { a = 1, b = "two", c = True }
```

### Simple lambda type
```elm
increment : Int -> Int
increment x = x + 1

testValue : Int
testValue = increment 5
```

### Multi-arg lambda type
```elm
add : Int -> Int -> Int
add a b = a + b

testValue : Int
testValue = add 3 4
```

### Lambda returning lambda type
```elm
makeAdder : Int -> Int -> Int
makeAdder n = \x -> x + n

testValue : Int
testValue = (makeAdder 10) 5
```

### Identity lambda type
```elm
identity : a -> a
identity x = x

testValue : Int
testValue = identity 42
```

### Lambda with record arg type
```elm
getX : { x : Int } -> Int
getX r = r.x

testValue : Int
testValue = getX { x = 10 }
```

### Lambda with tuple result type
```elm
pair : Int -> ( Int, Int )
pair x = (x, x)

testValue : ( Int, Int )
testValue = pair 7
```

### Simple accessor type
```elm
testValue = { name = "Alice" }.name
```

### Accessor on nested record type
```elm
testValue = { person = { age = 30 } }.person.age
```

### Accessor function type
```elm
getField : { field : Int } -> Int
getField = .field

testValue : Int
testValue = getField { field = 99 }
```

### Multiple accessor chain type
```elm
testValue = { level1 = { level2 = { value = 123 } } }.level1.level2.value
```

### Simple let type
```elm
testValue = let x = 42 in x
```

### Nested let type
```elm
testValue = let x = 10 in let y = x + 5 in y
```

### Let with function type
```elm
testValue = let double n = n * 2 in double 21
```

### Let destruct tuple type
```elm
testValue = let (a, b) = (1, 2) in a + b
```

### Let destruct record type
```elm
testValue = let { x, y } = { x = 3, y = 4 } in x + y
```

### Multiple let bindings type
```elm
testValue =
    let
        a = 1
        b = 2
        c = 3
    in
    a + b + c
```

### Simple if type
```elm
testValue = if True then 1 else 0
```

### Nested if type
```elm
testValue = if True then (if False then 1 else 2) else 3
```

### If with different result types
```elm
testValue = if True then { value = 1 } else { value = 2 }
```

### Simple case type
```elm
testValue = case 1 of
    0 -> "zero"
    1 -> "one"
    _ -> "other"
```

### Multi-branch case type
```elm
testValue = case 5 of
    0 -> 100
    1 -> 101
    2 -> 102
    3 -> 103
    4 -> 104
    _ -> 999
```

### Case with nested patterns type
```elm
testValue = case (1, 2) of
    (0, y) -> y
    (x, 0) -> x
    (x, y) -> x + y
```

### Simple record update type
```elm
testValue =
    let r = { x = 1, y = 2 }
    in { r | x = 10 }
```

### Multi-field record update type
```elm
testValue =
    let r = { a = 1, b = 2, c = 3 }
    in { r | a = 100, c = 300 }
```

### Record update with expression type
```elm
testValue =
    let r = { count = 5 }
    in { r | count = r.count + 1 }
```

### Nested record update type
```elm
testValue =
    let outer = { inner = { value = 1 } }
    in { outer | inner = { value = 99 } }
```

### Simple call type
```elm
negate : Int -> Int
negate x = 0 - x

testValue : Int
testValue = negate 42
```

### Nested call type
```elm
double : Int -> Int
double x = x * 2

testValue : Int
testValue = double (double 5)
```

### Higher-order call type
```elm
apply : (Int -> Int) -> Int -> Int
apply f x = f x

inc : Int -> Int
inc n = n + 1

testValue : Int
testValue = apply inc 10
```

### Partial application type
```elm
add : Int -> Int -> Int
add a b = a + b

add5 : Int -> Int
add5 = add 5

testValue : Int
testValue = add5 10
```

### Call with complex arg type
```elm
sumRecord : { x : Int, y : Int } -> Int
sumRecord r = r.x + r.y

testValue : Int
testValue = sumRecord { x = 3, y = 4 }
```

### Addition binop type
```elm
testValue = 1 + 2
```

### Comparison binop type
```elm
testValue = 5 > 3
```

### Logical binop type
```elm
testValue = True && False
```

### Chained binop type
```elm
testValue = 1 + 2 + 3 + 4
```

### Mixed binop type
```elm
testValue = 2 * 3 + 4
```

### Negate int type
```elm
testValue = -42
```

### Negate float type
```elm
testValue = -3.14
```

### Double negate type
```elm
testValue = -(-10)
```

### Unit in type annotation
```elm
f : () -> Int
f _ = 42

testValue : Int
testValue = f ()
```

### Type alias annotation
```elm
type alias Point = { x : Int, y : Int }

getX : Point -> Int
getX p = p.x

testValue : Int
testValue = getX { x = 10, y = 20 }
```

### Extensible record annotation
```elm
getX : { a | x : Int } -> Int
getX r = r.x

testValue : Int
testValue = getX { x = 5, y = 10 }
```

---

## BytesFusionCases

### Bytes.Encode.unsignedInt8
```elm
testValue = Bytes.Encode.unsignedInt8 42
```

### Bytes.Encode.signedInt8
```elm
testValue = Bytes.Encode.signedInt8 (-1)
```

### Bytes.Encode.unsignedInt16 BE
```elm
testValue = Bytes.Encode.unsignedInt16 BE 1000
```

### Bytes.Encode.unsignedInt32 LE
```elm
testValue = Bytes.Encode.unsignedInt32 LE 100000
```

### Bytes.Encode.float32 BE
```elm
testValue = Bytes.Encode.float32 BE 3.14
```

### Bytes.Encode.float64 LE
```elm
testValue = Bytes.Encode.float64 LE 2.718281828
```

### Bytes.Encode.string
```elm
testValue = Bytes.Encode.string "hello"
```

### Bytes.Encode.sequence of u8s
```elm
testValue =
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 1
        , Bytes.Encode.unsignedInt8 2
        , Bytes.Encode.unsignedInt8 3
        ]
```

### Bytes.Encode.encode with u8
```elm
testValue = Bytes.Encode.encode (Bytes.Encode.unsignedInt8 255)
```

### Bytes.Encode.encode with sequence
```elm
testValue =
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt8 0
            , Bytes.Encode.unsignedInt16 BE 256
            , Bytes.Encode.float64 LE 1.0
            ]
        )
```

### Bytes.Decode.unsignedInt8
```elm
testValue = Bytes.Decode.unsignedInt8
```

### Bytes.Decode.signedInt8
```elm
testValue = Bytes.Decode.signedInt8
```

### Bytes.Decode.unsignedInt16 BE
```elm
testValue = Bytes.Decode.unsignedInt16 BE
```

### Bytes.Decode.unsignedInt32 LE
```elm
testValue = Bytes.Decode.unsignedInt32 LE
```

### Bytes.Decode.float32 BE
```elm
testValue = Bytes.Decode.float32 BE
```

### Bytes.Decode.float64 LE
```elm
testValue = Bytes.Decode.float64 LE
```

### Bytes.Decode.string
```elm
testValue = Bytes.Decode.string 5
```

### Bytes.Decode.succeed
```elm
testValue = Bytes.Decode.succeed 42
```

### Bytes.Decode.map
```elm
testValue = Bytes.Decode.map (\x -> x) Bytes.Decode.unsignedInt8
```

### Bytes.Decode.map2
```elm
testValue = Bytes.Decode.map2 (\a b -> a) Bytes.Decode.unsignedInt8 Bytes.Decode.unsignedInt8
```

### Bytes.Decode.andThen
```elm
testValue =
    Bytes.Decode.andThen (\n -> Bytes.Decode.succeed n) Bytes.Decode.unsignedInt8
```

### Kernel Bytes.encode with u8
```elm
testValue = Bytes.encode (Bytes.Encode.unsignedInt8 42)
```

### Kernel Bytes.encode with sequence
```elm
testValue =
    Bytes.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt8 1
            , Bytes.Encode.unsignedInt8 2
            ]
        )
```

### Kernel Bytes.decode with u8 decoder
```elm
testValue =
    Bytes.decode Bytes.Decode.unsignedInt8
        (Bytes.encode (Bytes.Encode.unsignedInt8 99))
```

---

## PortEncodingCases

### Encode Int
```elm
port out : Int -> Cmd msg
```

### Encode Float
```elm
port out : Float -> Cmd msg
```

### Encode Bool
```elm
port out : Bool -> Cmd msg
```

### Encode String
```elm
port out : String -> Cmd msg
```

### Encode Maybe Int
```elm
port out : Maybe Int -> Cmd msg
```

### Encode Maybe String
```elm
port out : Maybe String -> Cmd msg
```

### Encode List Int
```elm
port out : List Int -> Cmd msg
```

### Encode List String
```elm
port out : List String -> Cmd msg
```

### Encode Tuple2
```elm
port out : (Int, String) -> Cmd msg
```

### Encode Tuple3
```elm
port out : (Int, (String, Bool)) -> Cmd msg
```

### Encode Simple Record
```elm
port out : { x : Int, y : Int } -> Cmd msg
```

### Encode Nested Record
```elm
port out : { pos : { x : Int, y : Int } } -> Cmd msg
```

### Encode Record With List
```elm
port out : { items : List Int } -> Cmd msg
```

### Encode List Of Records
```elm
port out : List { x : Int } -> Cmd msg
```

### Encode Maybe Record
```elm
port out : Maybe { x : Int } -> Cmd msg
```

### Decode Int
```elm
port inp : (Int -> msg) -> Sub msg
```

### Decode Float
```elm
port inp : (Float -> msg) -> Sub msg
```

### Decode Bool
```elm
port inp : (Bool -> msg) -> Sub msg
```

### Decode String
```elm
port inp : (String -> msg) -> Sub msg
```

### Decode Maybe Int
```elm
port inp : (Maybe Int -> msg) -> Sub msg
```

### Decode List Int
```elm
port inp : (List Int -> msg) -> Sub msg
```

### Decode Tuple2
```elm
port inp : ((Int, String) -> msg) -> Sub msg
```

### Decode Simple Record
```elm
port inp : ({ x : Int } -> msg) -> Sub msg
```

### Decode Nested Record
```elm
port inp : ({ pos : { x : Int } } -> msg) -> Sub msg
```

### Decode Record Multi Field
```elm
port inp : ({ a : Int, b : String, c : Bool } -> msg) -> Sub msg
```

### Decode List Of Records
```elm
port inp : (List { x : Int } -> msg) -> Sub msg
```

### Decode Maybe Record
```elm
port inp : (Maybe { x : Int } -> msg) -> Sub msg
```

### Decode Nested Maybe
```elm
port inp : (Maybe (Maybe Int) -> msg) -> Sub msg
```

### Multiple ports
```elm
port sendInt : Int -> Cmd msg
port sendString : String -> Cmd msg
port sendBool : Bool -> Cmd msg
```

### Port with Array
```elm
port out : Array Int -> Cmd msg
```

### Bidirectional ports
```elm
port sendData : Int -> Cmd msg
port receiveData : (Int -> msg) -> Sub msg
```

### Port with deep nesting
```elm
port out : List (Maybe (List { x : Int, y : List String })) -> Cmd msg
```

### Port with multiple records
```elm
port out : { user : { name : String, age : Int }, items : List { id : Int, name : String } } -> Cmd msg
```

---

## TypeCheckFailsCases

### Alias everywhere
```elm
allAliased ((a as first, b as second) as whole) =
    [whole, first, second]

testValue = allAliased (1, 2)
```

### Multiple aliases in recursive function
```elm
testValue =
    let
        go (n as count) (acc as result) =
            if True then result
            else go 0 count
    in
    go 5 []
```

### Case on unit
```elm
testValue = case (1, 1) of
    () -> 0
```

### Case on int
```elm
testValue = case 42 of
    0 -> "zero"
    x -> x
```

### All expression types in one module
```elm
testValue =
    [ [1, 2.0, "s", 'c']
    , ({ x = 1 }, (1, 2, 3))
    , (let f x = x in f 0)
    , (if True then (case 1 of n -> n) else 0)
    , (-1 + 2)
    , (let r = { x = 1 } in (r.x, .x))
    ]
```

### Fold-like function
```elm
testValue =
    let
        myFold f init list =
            case list of
                [] -> init
                h :: t -> f h init
    in
    myFold (\a b -> (a, b)) 0 [1]
```

### Multiple aliases in destruct
```elm
testValue =
    let
        (((a as first), (b as second)) as whole) = (1, 2)
    in
    [whole, first, second, a, b]
```

### Deeply recursive function
```elm
testValue =
    let
        countdown n = case n of
            0 -> []
            x -> [x, countdown 0]
    in
    countdown 3
```

### Mutually recursive different types
```elm
testValue =
    let
        toList n = if True then [] else [toInt 0]
        toInt xs = case xs of
            [] -> 0
            _ -> 1
    in
    toList 3
```

### Recursive with record pattern
```elm
testValue =
    let
        getValue { value, next } =
            if True then value
            else getValue next
    in
    getValue { value = 1, next = { value = 2, next = { value = 3, next = {} } } }
```

### Recursive higher order
```elm
testValue =
    let
        map f list = case list of
            [] -> []
            h :: t -> [f h, map f t]
    in
    map (\x -> x) [1, 2]
```

### Update with computed value
```elm
testValue =
    let r = { value = 10 }
    in { r | value = (1, 2) }
```

---

## PatternComplexityFuzzCases

These are fuzz tests that generate random inputs. Each test generates case expressions with specific pattern structures.

### Nested tuple patterns (fuzz)
Generates case expressions matching on `((int, int), (int, int))` with branches:
- `((a, b), (c, d))` - all variables
- `((0, x), (y, _))` - mix of literal, variable, wildcard
- `_` - catch-all

### Nested list patterns (fuzz)
Generates case expressions matching on `[[int], [int]]` with branches:
- `(h :: t) :: rest` - cons inside cons
- `[x] :: ys` - list pattern inside cons
- `[]` - empty list
- `_` - catch-all

### Mixed nested patterns (fuzz)
Generates case expressions matching on `([int, int], (int, int))` with branches:
- `(x :: xs, (a, b))`
- `([], (_, _))`
- `([y], t)`
- `_` - catch-all

### As-patterns with nested inner (fuzz)
Generates case expressions matching on `(int, int)` with branches:
- `(a, b) as pair`
- `(0, x) as zeroPair`
- `_ as whole` - catch-all with alias

### Overlapping int patterns (fuzz)
Generates case expressions matching on a random int with branches:
- `0 -> 100`
- `1 -> 101`
- `2 -> 102`
- `-1 -> 99`
- `n -> n` - catch-all binding variable

### Overlapping tuple patterns (fuzz)
Generates case expressions matching on `(int, int)` with branches:
- `(0, _) -> 1`
- `(_, 0) -> 2`
- `(1, 1) -> 3`
- `(x, y) -> x + y`

---

## AccessorFuzzCases

These are fuzz tests that generate random field names and records.

### Accessor with List.map (fuzz)
Generates: `List.map .fieldName [{ fieldName = value }, ...]` where field name and values are randomly chosen.

### Accessor in pipeline (fuzz)
Generates: `[records...] |> List.map .fieldName` with random field names and record values.

### Accessor passed to function (fuzz)
Generates:
```elm
let applyAccessor f r = f r
in applyAccessor .fieldName { fieldName = value }
```
with random field name and value.

### Two-level chained access (fuzz)
Generates: `{ outer = { inner = 42 } }.outer.inner` with random field names.

### Three-level chained access (fuzz)
Generates: `{ a = { b = { c = 42 } } }.a.b.c` with random field names.

### Access on record with many fields (fuzz)
Generates a record with 5-8 fields (`{ a = 0, b = 1, c = 2, ... }`) and accesses a random field.

### Multiple accessors on same record (fuzz)
Generates:
```elm
let r = { alpha = 1, beta = "hello", gamma = True }
in (r.alpha, r.beta, r.gamma)
```

---

## CombinatorCases

### K combinator (always)
```elm
testValue =
    let k a _ = a
    in k 42 99
```

### S combinator (feed same input)
```elm
testValue =
    let
        s bf uf x = bf x (uf x)
        double x = x * 2
        add a b = a + b
    in
    s add double 5
```

### I combinator (identity via S K K)
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        i = s k k
    in
    i 42
```

### B combinator (compose via S (K S) K)
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        square x = x * x
        inc x = x + 1
    in
    b square inc 4
```

### C combinator (flip via S (B B S) (K K))
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        c = s (b b s) (k k)
        sub x y = x - y
    in
    c sub 10 3
```

### SP combinator (combine two projections)
```elm
testValue =
    let
        sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)
        mul x y = x * y
        inc x = x + 1
        double x = x * 2
    in
    sp mul inc double 6
```

### T combinator (thrush / pipe-forward)
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        c = s (b b s) (k k)
        i = s k k
        t = c i
    in
    t 7 (\x -> x * 3)
```

### W combinator (duplicate argument)
```elm
testValue =
    let
        w bf x = bf x x
        mul x y = x * y
    in
    w mul 9
```

---

## CombinatorStdlibCases

### B combinator: compose foldl and map on list
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        mySum xs = List.foldl (\a acc -> a + acc) 0 xs
        mapInc xs = List.map (\x -> x + 1) xs
    in
    b mySum mapInc [1, 2, 3]
```

### T combinator: pipe list into composed ops
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        c = s (b b s) (k k)
        i = s k k
        t = c i
        mySum xs = List.foldl (\a acc -> a + acc) 0 xs
        mapDouble xs = List.map (\x -> x * 2) xs
        composed = b mySum mapDouble
    in
    t [1, 2, 3] composed
```

### P combinator: add lengths of two lists
```elm
testValue =
    let
        p bf uf x y = bf (uf x) (uf y)
        add a b = a + b
        len xs = List.length xs
    in
    p add len [1, 2, 3] [4, 5]
```

### W combinator: duplicate string via append
```elm
testValue =
    let
        w bf x = bf x x
        myAppend a b = a ++ b
    in
    w myAppend "hi"
```

### S combinator: palindrome via list reverse
```elm
testValue =
    let
        s bf uf x = bf x (uf x)
        myAppend a b = a ++ b
        rev xs = List.reverse xs
    in
    s myAppend rev [3, 2, 1]
```

### SP combinator: combine projections with operators
```elm
testValue =
    let
        sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)
        mul a b = a * b
        inc x = x + 1
        double x = x * 2
    in
    sp mul inc double 6
```

### C combinator: flip cons onto list
```elm
testValue =
    let
        k a _ = a
        s bf uf x = bf x (uf x)
        b = s (k s) k
        c = s (b b s) (k k)
        cons x xs = [x] ++ xs
    in
    c cons [2, 3] 1
```

---

