# All E2E Test Cases

This document contains every E2E test case from `test/elm/src/`,
each a standalone Elm program that compiles and runs through the full
Eco pipeline (Elm → MLIR → LLVM → native). Expected outputs are
verified against `Debug.log` output using `-- CHECK:` comments.

**Total: 231 test files**

---

## Table of Contents

| # | Category | Files |
|---|----------|-------|
| 1 | [Accessor / Add / Anonymous / Bitwise / Bool](#e2e-tests-accessor--add--anonymous--bitwise--bool) | 18 |
| 2 | [Captured / Case / Ceiling / Char](#e2e-tests-captured--case--ceiling--char) | 42 |
| 3 | [Closure / Combinator / Comparable / Compare / Composition / CustomType / DictMap / Equality](#e2e-tests-closure--combinator--comparable--compare--composition--customtype--dictmap--equality) | 41 |
| 4 | [Flip / Float / Floor / Function / Hello / HeteroClosure / HigherOrder / HOParam / IndirectCall / InlineVar / Int](#e2e-tests-flip--float--floor--function--hello--heteroclosure--higherorder--hoparam--indirectcall--inlinevar--int) | 41 |
| 5 | [Lambda / Let / List / LocalTailRec](#e2e-tests-lambda--let--list--localtailrec) | 26 |
| 6 | [Maybe / MutualRecursion / PapExtend / PapSaturate / PartialApp / Pipeline / Poly](#e2e-tests-maybe--mutualrecursion--papextend--papsaturate--partialapp--pipeline--poly) | 14 |
| 7 | [Record / Recursive / Result / Round / SingleCtorPair](#e2e-tests-record--recursive--result--round--singlyctorpair) | 23 |
| 8 | [String / TailRec / Timer / ToFloat / Truncate / Tuple](#e2e-tests-string--tailrec--timer--tofloat--truncate--tuple) | 26 |

---

## E2E Tests: Accessor / Add / Anonymous / Bitwise / Bool

### AccessorToLocalFunc

**Expected:** `result: 42`

```elm
{-| Test passing .field accessor to a local function.
-}

-- CHECK: result: 42


main =
    let
        applyAccessor f r = f r

        result = applyAccessor .x { x = 42 }
        _ = Debug.log "result" result
    in
    text "done"
```

### Add

**Expected:** `AddTest: 42`

```elm
{-| Simple test that verifies basic Elm operations compile and run.

    This test verifies:
    1. Elm to MLIR compilation works
    2. MLIR JIT execution works
    3. Debug.log works with integers

    Note: Arithmetic operations like (+) currently have a type mismatch
    between kernel signatures (expecting doubles) and JIT calling convention
    (passing boxed values). This will be fixed in a future update.
-}

-- CHECK: AddTest: 42


main =
    let
        result =
            42

        _ =
            Debug.log "AddTest" result
    in
    text "hello"
```

### AnonymousFunction

**Expected:** `lambda1: [2, 4, 6]`, `lambda2: 15`, `lambda3: [2, 4]`

```elm
{-| Test anonymous functions (lambdas).
-}

-- CHECK: lambda1: [2, 4, 6]
-- CHECK: lambda2: 15
-- CHECK: lambda3: [2, 4]


main =
    let
        _ = Debug.log "lambda1" (List.map (\x -> x * 2) [1, 2, 3])
        _ = Debug.log "lambda2" (List.foldl (\x acc -> x + acc) 0 [1, 2, 3, 4, 5])
        _ = Debug.log "lambda3" (List.filter (\x -> modBy 2 x == 0) [1, 2, 3, 4, 5])
    in
    text "done"
```

### BitwiseAnd

**Expected:** `and1: 8`, `and2: 0`, `and3: 15`

```elm
{-| Test Bitwise.and.
-}

-- CHECK: and1: 8
-- CHECK: and2: 0
-- CHECK: and3: 15


main =
    let
        _ = Debug.log "and1" (Bitwise.and 15 8)
        _ = Debug.log "and2" (Bitwise.and 15 16)
        _ = Debug.log "and3" (Bitwise.and 15 15)
    in
    text "done"
```

### BitwiseComplement

**Expected:** `comp1: -1`, `comp2: -16`

```elm
{-| Test Bitwise.complement.
-}

-- CHECK: comp1: -1
-- CHECK: comp2: -16


main =
    let
        _ = Debug.log "comp1" (Bitwise.complement 0)
        _ = Debug.log "comp2" (Bitwise.complement 15)
    in
    text "done"
```

### BitwiseIdentity

**Expected:** `identity1: 42`, `identity2: 42`, `identity3: 0`

```elm
{-| Test bitwise identity properties.
-}

-- CHECK: identity1: 42
-- CHECK: identity2: 42
-- CHECK: identity3: 0


main =
    let
        x = 42
        _ = Debug.log "identity1" (Bitwise.and x x)
        _ = Debug.log "identity2" (Bitwise.or x x)
        _ = Debug.log "identity3" (Bitwise.xor x x)
    in
    text "done"
```

### BitwiseLargeShift

**Expected:** `shift32: 4294967296`, `shift63: -9223372036854775808`

```elm
{-| Test large shift amounts.
-}

-- CHECK: shift32: 4294967296
-- CHECK: shift63: -9223372036854775808


main =
    let
        _ = Debug.log "shift32" (Bitwise.shiftLeftBy 32 1)
        _ = Debug.log "shift63" (Bitwise.shiftLeftBy 63 1)
    in
    text "done"
```

### BitwiseOr

**Expected:** `or1: 15`, `or2: 31`, `or3: 15`

```elm
{-| Test Bitwise.or.
-}

-- CHECK: or1: 15
-- CHECK: or2: 31
-- CHECK: or3: 15


main =
    let
        _ = Debug.log "or1" (Bitwise.or 15 8)
        _ = Debug.log "or2" (Bitwise.or 15 16)
        _ = Debug.log "or3" (Bitwise.or 15 15)
    in
    text "done"
```

### BitwiseShiftLeft

**Expected:** `shl1: 16`, `shl2: 32`, `shl3: 1024`

```elm
{-| Test Bitwise.shiftLeftBy.
-}

-- CHECK: shl1: 16
-- CHECK: shl2: 32
-- CHECK: shl3: 1024


main =
    let
        _ = Debug.log "shl1" (Bitwise.shiftLeftBy 4 1)
        _ = Debug.log "shl2" (Bitwise.shiftLeftBy 1 16)
        _ = Debug.log "shl3" (Bitwise.shiftLeftBy 10 1)
    in
    text "done"
```

### BitwiseShiftRight

**Expected:** `shr1: 1`, `shr2: 8`, `shr3: -1`

```elm
{-| Test Bitwise.shiftRightBy (arithmetic shift).
-}

-- CHECK: shr1: 1
-- CHECK: shr2: 8
-- CHECK: shr3: -1


main =
    let
        _ = Debug.log "shr1" (Bitwise.shiftRightBy 4 16)
        _ = Debug.log "shr2" (Bitwise.shiftRightBy 1 16)
        _ = Debug.log "shr3" (Bitwise.shiftRightBy 4 -1)
    in
    text "done"
```

### BitwiseShiftRightZf

**Expected:** `shrz1: 1`, `shrz2: 8`

```elm
{-| Test Bitwise.shiftRightZfBy (logical shift).
-}

-- CHECK: shrz1: 1
-- CHECK: shrz2: 8


main =
    let
        _ = Debug.log "shrz1" (Bitwise.shiftRightZfBy 4 16)
        _ = Debug.log "shrz2" (Bitwise.shiftRightZfBy 1 16)
    in
    text "done"
```

### BitwiseXor

**Expected:** `xor1: 7`, `xor2: 31`, `xor3: 0`

```elm
{-| Test Bitwise.xor.
-}

-- CHECK: xor1: 7
-- CHECK: xor2: 31
-- CHECK: xor3: 0


main =
    let
        _ = Debug.log "xor1" (Bitwise.xor 15 8)
        _ = Debug.log "xor2" (Bitwise.xor 15 16)
        _ = Debug.log "xor3" (Bitwise.xor 15 15)
    in
    text "done"
```

### BoolAnd

**Expected:** `and1: True`, `and2: False`, `and3: False`, `and4: False`

```elm
{-| Test && operator.
-}

-- CHECK: and1: True
-- CHECK: and2: False
-- CHECK: and3: False
-- CHECK: and4: False


main =
    let
        _ = Debug.log "and1" (True && True)
        _ = Debug.log "and2" (True && False)
        _ = Debug.log "and3" (False && True)
        _ = Debug.log "and4" (False && False)
    in
    text "done"
```

### BoolNot

**Expected:** `not1: False`, `not2: True`

```elm
{-| Test not function.
-}

-- CHECK: not1: False
-- CHECK: not2: True


main =
    let
        _ = Debug.log "not1" (not True)
        _ = Debug.log "not2" (not False)
    in
    text "done"
```

### BoolOr

**Expected:** `or1: True`, `or2: True`, `or3: True`, `or4: False`

```elm
{-| Test || operator.
-}

-- CHECK: or1: True
-- CHECK: or2: True
-- CHECK: or3: True
-- CHECK: or4: False


main =
    let
        _ = Debug.log "or1" (True || True)
        _ = Debug.log "or2" (True || False)
        _ = Debug.log "or3" (False || True)
        _ = Debug.log "or4" (False || False)
    in
    text "done"
```

### BoolShortCircuit

**Expected:** `shortAnd: False`, `shortOr: True`

```elm
{-| Test short-circuit evaluation.
-}

-- CHECK: shortAnd: False
-- CHECK: shortOr: True


crash _ = Debug.todo "should not be called"


main =
    let
        -- False && anything should not evaluate the second argument
        _ = Debug.log "shortAnd" (False && True)
        -- True || anything should not evaluate the second argument
        _ = Debug.log "shortOr" (True || False)
    in
    text "done"
```

### BoolTrueFalse

**Expected:** `true: True`, `false: False`

```elm
{-| Test True and False constants.
-}

-- CHECK: true: True
-- CHECK: false: False


main =
    let
        _ = Debug.log "true" True
        _ = Debug.log "false" False
    in
    text "done"
```

### BoolXor

**Expected:** `xor1: False`, `xor2: True`, `xor3: True`, `xor4: False`

```elm
{-| Test xor function.
-}

-- CHECK: xor1: False
-- CHECK: xor2: True
-- CHECK: xor3: True
-- CHECK: xor4: False


main =
    let
        _ = Debug.log "xor1" (xor True True)
        _ = Debug.log "xor2" (xor True False)
        _ = Debug.log "xor3" (xor False True)
        _ = Debug.log "xor4" (xor False False)
    in
    text "done"
```

---

## E2E Tests: Captured / Case / Ceiling / Char

### CapturedStagedFuncCall

**Expected:** `direct: 15`, `viaCapture: 15`

```elm
{-| Test: captured staged function applied to multiple args in a closure.

Reproduces a bug where annotateExprCalls doesn't add closure params to
varSourceArity, so a captured function parameter's arity falls back to
firstStageArityFromType, which returns only the first-stage arity.
When the function is staged (returns a function), only the first arg
is applied and subsequent args are silently dropped.
-}

-- CHECK: direct: 15
-- CHECK: viaCapture: 15


{-| Staged function: takes one arg, returns a function. -}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Apply a captured 2-arg function via a wrapper closure.
The inner lambda captures 'f' and applies it to both a and b.
-}
applyBoth : (String -> Int -> Int) -> String -> Int -> Int
applyBoth f a b =
    let
        go () =
            f a b
    in
    go ()


main =
    let
        _ =
            Debug.log "direct" (makeAdder "hello" 10)

        _ =
            Debug.log "viaCapture" (applyBoth makeAdder "hello" 10)
    in
    text "done"
```

### CaseAsPattern

**Expected:** `as1: 0`, `as2: 3`, `as3: 6`

```elm
{-| Test case expression with as-patterns.
-}

-- CHECK: as1: 0
-- CHECK: as2: 3
-- CHECK: as3: 6


sumWithLength list =
    case list of
        [] -> 0
        ((x :: _) as whole) -> x + List.length whole


main =
    let
        _ = Debug.log "as1" (sumWithLength [])
        _ = Debug.log "as2" (sumWithLength [1, 2])
        _ = Debug.log "as3" (sumWithLength [3, 4, 5])
    in
    text "done"
```

### CaseBool

**Expected:** `case1: "yes"`, `case2: "no"`

```elm
{-| Test case expression on Bool.
-}

-- CHECK: case1: "yes"
-- CHECK: case2: "no"


boolToStr b =
    case b of
        True -> "yes"
        False -> "no"


main =
    let
        _ = Debug.log "case1" (boolToStr True)
        _ = Debug.log "case2" (boolToStr False)
    in
    text "done"
```

### CaseChar

**Expected:** `char1: "vowel a"`, `char2: "vowel e"`, `char3: "other"`, `char4: "other"`

```elm
{-| Test case expression on Char with wildcard.
-}

-- CHECK: char1: "vowel a"
-- CHECK: char2: "vowel e"
-- CHECK: char3: "other"
-- CHECK: char4: "other"


describeChar c =
    case c of
        'a' -> "vowel a"
        'e' -> "vowel e"
        'i' -> "vowel i"
        'o' -> "vowel o"
        'u' -> "vowel u"
        _ -> "other"


main =
    let
        _ = Debug.log "char1" (describeChar 'a')
        _ = Debug.log "char2" (describeChar 'e')
        _ = Debug.log "char3" (describeChar 'x')
        _ = Debug.log "char4" (describeChar 'z')
    in
    text "done"
```

### CaseCustomType4

**Expected:** `dir1: "up"`, `dir2: "down"`, `dir3: "left"`, `dir4: "right"`

```elm
{-| Test case on custom type with 4 constructors.
-}

-- CHECK: dir1: "up"
-- CHECK: dir2: "down"
-- CHECK: dir3: "left"
-- CHECK: dir4: "right"


type Direction
    = Up
    | Down
    | Left
    | Right


dirToStr dir =
    case dir of
        Up -> "up"
        Down -> "down"
        Left -> "left"
        Right -> "right"


main =
    let
        _ = Debug.log "dir1" (dirToStr Up)
        _ = Debug.log "dir2" (dirToStr Down)
        _ = Debug.log "dir3" (dirToStr Left)
        _ = Debug.log "dir4" (dirToStr Right)
    in
    text "done"
```

### CaseCustomType4Wildcard

**Expected:** `card1: "hearts"`, `card2: "spades"`, `card3: "other"`, `card4: "other"`

```elm
{-| Test case on custom type with 4 constructors, 2 explicit cases and wildcard.
-}

-- CHECK: card1: "hearts"
-- CHECK: card2: "spades"
-- CHECK: card3: "other"
-- CHECK: card4: "other"


type Suit
    = Hearts
    | Diamonds
    | Clubs
    | Spades


suitToStr suit =
    case suit of
        Hearts -> "hearts"
        Spades -> "spades"
        _ -> "other"


main =
    let
        _ = Debug.log "card1" (suitToStr Hearts)
        _ = Debug.log "card2" (suitToStr Spades)
        _ = Debug.log "card3" (suitToStr Diamonds)
        _ = Debug.log "card4" (suitToStr Clubs)
    in
    text "done"
```

### CaseCustomType

**Expected:** `shape1: 100`, `shape2: 50`

```elm
{-| Test case on custom types.
-}

-- CHECK: shape1: 100
-- CHECK: shape2: 50


type Shape
    = Circle Int
    | Rectangle Int Int


area shape =
    case shape of
        Circle r -> r * r
        Rectangle w h -> w * h


main =
    let
        _ = Debug.log "shape1" (area (Circle 10))
        _ = Debug.log "shape2" (area (Rectangle 5 10))
    in
    text "done"
```

### CaseDeeplyNested

**Expected:** `deep1: "all"`, `deep2: "two"`

```elm
{-| Test deeply nested case expressions (3+ levels).
-}

-- CHECK: deep1: "all"
-- CHECK: deep2: "two"


describeThree a b c =
    case a of
        Just _ ->
            case b of
                Just _ ->
                    case c of
                        Just _ -> "all"
                        Nothing -> "two"
                Nothing -> "one"
        Nothing -> "none"


main =
    let
        _ = Debug.log "deep1" (describeThree (Just 1) (Just 2) (Just 3))
        _ = Debug.log "deep2" (describeThree (Just 1) (Just 2) Nothing)
    in
    text "done"
```

### CaseDefault

**Expected:** `default1: "special"`, `default2: "normal"`, `default3: "normal"`

```elm
{-| Test wildcard pattern in case.
-}

-- CHECK: default1: "special"
-- CHECK: default2: "normal"
-- CHECK: default3: "normal"


classify n =
    case n of
        42 -> "special"
        _ -> "normal"


main =
    let
        _ = Debug.log "default1" (classify 42)
        _ = Debug.log "default2" (classify 1)
        _ = Debug.log "default3" (classify 100)
    in
    text "done"
```

### CaseFanOutShadow

**Expected:** `r1: 5`, `r2: -1`, `r3: 0`

```elm
{-| Test nested case expressions with constructor destructuring.
Targets the SSA variable name collision bug where placeholder
variable names collide across case regions.
-}

-- CHECK: r1: 5
-- CHECK: r2: -1
-- CHECK: r3: 0


type Wrapper
    = Wrapper Int (List Int)


sumWrapper : Wrapper -> Int
sumWrapper (Wrapper head tail) =
    case tail of
        [] ->
            head

        first :: rest ->
            head + sumWrapper (Wrapper first rest)


safeDivide : Int -> Int -> Result String Int
safeDivide a b =
    if b == 0 then
        Err "division by zero"

    else
        Ok (a // b)


processWrapper : Wrapper -> Result String Int -> Int
processWrapper (Wrapper n _) result =
    case result of
        Ok value ->
            n + value

        Err _ ->
            -1


main =
    let
        w = Wrapper 3 [ 1, 2 ]
        _ = Debug.log "r1" (processWrapper w (safeDivide 4 2))
        _ = Debug.log "r2" (processWrapper w (Err "oops"))
        _ = Debug.log "r3" (processWrapper (Wrapper 0 []) (Ok 0))
    in
    text "done"
```

### CaseGuardLike

**Expected:** `grade1: "A"`, `grade2: "B"`, `grade3: "C"`, `grade4: "F"`

```elm
{-| Test case with guard-like conditions (case + if).
-}

-- CHECK: grade1: "A"
-- CHECK: grade2: "B"
-- CHECK: grade3: "C"
-- CHECK: grade4: "F"


letterGrade score =
    case score >= 90 of
        True -> "A"
        False ->
            case score >= 80 of
                True -> "B"
                False ->
                    case score >= 70 of
                        True -> "C"
                        False -> "F"


main =
    let
        _ = Debug.log "grade1" (letterGrade 95)
        _ = Debug.log "grade2" (letterGrade 85)
        _ = Debug.log "grade3" (letterGrade 75)
        _ = Debug.log "grade4" (letterGrade 50)
    in
    text "done"
```

### CaseInLambda

**Expected:** `lambda1: "yes"`, `lambda2: "no"`, `lambda3: "yes"`

```elm
{-| Test case expression inside a lambda.
-}

-- CHECK: lambda1: "yes"
-- CHECK: lambda2: "no"
-- CHECK: lambda3: "yes"


applyTo x f =
    f x


main =
    let
        boolToStr = \b -> case b of
            True -> "yes"
            False -> "no"

        _ = Debug.log "lambda1" (boolToStr True)
        _ = Debug.log "lambda2" (boolToStr False)
        _ = Debug.log "lambda3" (applyTo True (\b -> case b of
            True -> "yes"
            False -> "no"))
    in
    text "done"
```

### CaseInLet

**Expected:** `let1: "positive"`, `let2: "zero"`, `let3: "negative"`

```elm
{-| Test case expression in let binding.
-}

-- CHECK: let1: "positive"
-- CHECK: let2: "zero"
-- CHECK: let3: "negative"


classifyNumber n =
    let
        sign = case compare n 0 of
            GT -> "positive"
            EQ -> "zero"
            LT -> "negative"
    in
    sign


main =
    let
        _ = Debug.log "let1" (classifyNumber 5)
        _ = Debug.log "let2" (classifyNumber 0)
        _ = Debug.log "let3" (classifyNumber -3)
    in
    text "done"
```

### CaseInt

**Expected:** `case1: "one"`, `case2: "two"`, `case3: "other"`

```elm
{-| Test case expression on Int.
-}

-- CHECK: case1: "one"
-- CHECK: case2: "two"
-- CHECK: case3: "other"


describeNum n =
    case n of
        1 -> "one"
        2 -> "two"
        _ -> "other"


main =
    let
        _ = Debug.log "case1" (describeNum 1)
        _ = Debug.log "case2" (describeNum 2)
        _ = Debug.log "case3" (describeNum 99)
    in
    text "done"
```

### CaseListCons

**Expected:** `sum1: 0`, `sum2: 1`, `sum3: 6`

```elm
{-| Test case expression on List with [] and x::xs patterns.
-}

-- CHECK: sum1: 0
-- CHECK: sum2: 1
-- CHECK: sum3: 6


sumList list =
    case list of
        [] -> 0
        x :: xs -> x + sumList xs


main =
    let
        _ = Debug.log "sum1" (sumList [])
        _ = Debug.log "sum2" (sumList [1])
        _ = Debug.log "sum3" (sumList [1, 2, 3])
    in
    text "done"
```

### CaseList

**Expected:** `case1: "empty"`, `case2: "one"`, `case3: "many"`

```elm
{-| Test case expression on List.
-}

-- CHECK: case1: "empty"
-- CHECK: case2: "one"
-- CHECK: case3: "many"


describeList list =
    case list of
        [] -> "empty"
        [_] -> "one"
        _ -> "many"


main =
    let
        _ = Debug.log "case1" (describeList [])
        _ = Debug.log "case2" (describeList [1])
        _ = Debug.log "case3" (describeList [1, 2, 3])
    in
    text "done"
```

### CaseListThreeWay

**Expected:** `desc1: "empty"`, `desc2: "single: 42"`, `desc3: "multiple: 1"`

```elm
{-| Test case expression on List with [], [x], and x::xs patterns.
-}

-- CHECK: desc1: "empty"
-- CHECK: desc2: "single: 42"
-- CHECK: desc3: "multiple: 1"


describeList list =
    case list of
        [] -> "empty"
        [x] -> "single: " ++ String.fromInt x
        x :: xs -> "multiple: " ++ String.fromInt x


main =
    let
        _ = Debug.log "desc1" (describeList [])
        _ = Debug.log "desc2" (describeList [42])
        _ = Debug.log "desc3" (describeList [1, 2, 3])
    in
    text "done"
```

### CaseManyBranches

**Expected:** `day1: "Monday"`, `day5: "Friday"`, `day7: "Sunday"`

```elm
{-| Test case with many branches.
-}

-- CHECK: day1: "Monday"
-- CHECK: day5: "Friday"
-- CHECK: day7: "Sunday"


dayName n =
    case n of
        1 -> "Monday"
        2 -> "Tuesday"
        3 -> "Wednesday"
        4 -> "Thursday"
        5 -> "Friday"
        6 -> "Saturday"
        7 -> "Sunday"
        _ -> "Unknown"


main =
    let
        _ = Debug.log "day1" (dayName 1)
        _ = Debug.log "day5" (dayName 5)
        _ = Debug.log "day7" (dayName 7)
    in
    text "done"
```

### CaseMaybe

**Expected:** `case1: 42`, `case2: -1`

```elm
{-| Test case expression on Maybe.
-}

-- CHECK: case1: 42
-- CHECK: case2: -1


maybeToInt maybe =
    case maybe of
        Just x -> x
        Nothing -> -1


main =
    let
        _ = Debug.log "case1" (maybeToInt (Just 42))
        _ = Debug.log "case2" (maybeToInt Nothing)
    in
    text "done"
```

### CaseMultiFieldExtract

**Expected:** `point1: 3`, `point2: 6`, `rect1: 50`

```elm
{-| Test case extracting multiple fields from custom type constructors.
-}

-- CHECK: point1: 3
-- CHECK: point2: 6
-- CHECK: rect1: 50


type Shape
    = Point Int Int
    | Rectangle Int Int Int Int


sumCoords shape =
    case shape of
        Point x y -> x + y
        Rectangle x1 y1 x2 y2 -> (x2 - x1) * (y2 - y1)


main =
    let
        _ = Debug.log "point1" (sumCoords (Point 1 2))
        _ = Debug.log "point2" (sumCoords (Point 2 4))
        _ = Debug.log "rect1" (sumCoords (Rectangle 0 0 10 5))
    in
    text "done"
```

### CaseNestedRecordAccess

**Expected:** `test1: True`, `test2: False`, `test3: True`, `test4: True`

```elm
{-| Test case where function A calls function B, both have destructuring args
AND case expressions. After MonoInlineSimplify inlines B, the case root
variable names collide because both functions consumed the same number of
Names.generate calls before their case expressions.

This triggers the SSA redefinition bug when addPlaceholderMappings reuses
an existing varMapping entry instead of allocating a fresh var.
-}

-- CHECK: test1: True
-- CHECK: test2: False
-- CHECK: test3: True
-- CHECK: test4: True


type Shape
    = Circle
    | Square
    | Triangle
    | Diamond
    | Pentagon
    | Hexagon
    | Heptagon
    | Octagon
    | Star
    | Cross
    | Arrow


type alias Pos =
    { line : Int
    , col : Int
    }


type alias Info =
    { name : String
    , node : Shape
    , size : Int
    }


type Located a
    = At Pos a


type Branch
    = Branch Int (List ( String, Located Info ))


listLookup : a -> List ( a, b ) -> Maybe b
listLookup target list =
    case list of
        [] ->
            Nothing

        ( key, value ) :: rest ->
            if key == target then
                Just value

            else
                listLookup target rest


{-| Small function with a destructuring arg AND a case on a record field.
The destructuring arg (At _ info) consumes _v0 for the wrapper, making
the case root _v1, matching the pattern in the caller.
-}
needsCheck : Located Info -> Bool
needsCheck (At _ info) =
    case info.node of
        Circle ->
            True

        Square ->
            True

        Triangle ->
            True

        Diamond ->
            False

        Pentagon ->
            False

        Hexagon ->
            False

        Heptagon ->
            False

        Octagon ->
            False

        Star ->
            False

        Cross ->
            False

        Arrow ->
            False


{-| Function with a destructuring arg AND a case expression.
The destructuring arg (Branch _ pathPatterns) consumes _v0, making
the case root _v1 - same as needsCheck's case root after its destructuring.
After inlining needsCheck, both _v1 names exist in the same scope.
-}
isIrrelevantTo : String -> Branch -> Bool
isIrrelevantTo selectedPath (Branch _ pathPatterns) =
    case listLookup selectedPath pathPatterns of
        Nothing ->
            True

        Just val ->
            not (needsCheck val)


main =
    let
        pos =
            { line = 1, col = 1 }

        pairs =
            Branch 0
                [ ( "a", At pos { name = "alpha", node = Diamond, size = 10 } )
                , ( "b", At pos { name = "beta", node = Circle, size = 5 } )
                ]

        _ = Debug.log "test1" (isIrrelevantTo "missing" pairs)
        _ = Debug.log "test2" (isIrrelevantTo "b" pairs)
        _ = Debug.log "test3" (isIrrelevantTo "a" pairs)
        _ = Debug.log "test4" (isIrrelevantTo "nonexistent" pairs)
    in
    text "done"
```

### CaseNested

**Expected:** `nested1: "both"`, `nested2: "first"`, `nested3: "second"`, `nested4: "neither"`

```elm
{-| Test nested case expressions.
-}

-- CHECK: nested1: "both"
-- CHECK: nested2: "first"
-- CHECK: nested3: "second"
-- CHECK: nested4: "neither"


describe a b =
    case a of
        Just _ ->
            case b of
                Just _ -> "both"
                Nothing -> "first"
        Nothing ->
            case b of
                Just _ -> "second"
                Nothing -> "neither"


main =
    let
        _ = Debug.log "nested1" (describe (Just 1) (Just 2))
        _ = Debug.log "nested2" (describe (Just 1) Nothing)
        _ = Debug.log "nested3" (describe Nothing (Just 2))
        _ = Debug.log "nested4" (describe Nothing Nothing)
    in
    text "done"
```

### CaseOrder

**Expected:** `ord1: "less"`, `ord2: "equal"`, `ord3: "greater"`

```elm
{-| Test case expression on Order type (LT, EQ, GT).
-}

-- CHECK: ord1: "less"
-- CHECK: ord2: "equal"
-- CHECK: ord3: "greater"


orderToStr ord =
    case ord of
        LT -> "less"
        EQ -> "equal"
        GT -> "greater"


main =
    let
        _ = Debug.log "ord1" (orderToStr (compare 1 2))
        _ = Debug.log "ord2" (orderToStr (compare 5 5))
        _ = Debug.log "ord3" (orderToStr (compare 10 3))
    in
    text "done"
```

### CaseResult

**Expected:** `res1: 42`, `res2: -1`, `res3: 100`

```elm
{-| Test case expression on Result type.
-}

-- CHECK: res1: 42
-- CHECK: res2: -1
-- CHECK: res3: 100


resultToInt result =
    case result of
        Ok value -> value
        Err _ -> -1


main =
    let
        _ = Debug.log "res1" (resultToInt (Ok 42))
        _ = Debug.log "res2" (resultToInt (Err "error"))
        _ = Debug.log "res3" (resultToInt (Ok 100))
    in
    text "done"
```

### CaseReturnFunction

**Expected:** `op1: 7`, `op2: 3`, `op3: 10`

```elm
{-| Test case expression where branches return functions.
-}

-- CHECK: op1: 7
-- CHECK: op2: 3
-- CHECK: op3: 10


type Op
    = Add
    | Sub
    | Mul


getOp op =
    case op of
        Add -> \a b -> a + b
        Sub -> \a b -> a - b
        Mul -> \a b -> a * b


main =
    let
        _ = Debug.log "op1" ((getOp Add) 3 4)
        _ = Debug.log "op2" ((getOp Sub) 5 2)
        _ = Debug.log "op3" ((getOp Mul) 2 5)
    in
    text "done"
```

### CaseSingleCtorBoolMultiType

**Expected:** `nested_true: "split"`, `nested_false: "join"`, `extract_true: True`, `extract_false: False`, `wrap_int: 42`

```elm
{-| Test case expression on a single-constructor custom type wrapping Bool
when another single-constructor type wrapping Int exists in scope.

Reproduces a codegen bug where findSingleCtorUnboxedField searches all
single-constructor types and may find a type wrapping Int (unboxed) instead
of the actual ForceMultiline type wrapping Bool (boxed). This causes
eco.project.custom to emit i64 for a Bool field, but the subsequent
eco.case with case_kind="bool" expects i1.
-}

-- CHECK: nested_true: "split"
-- CHECK: nested_false: "join"
-- CHECK: extract_true: True
-- CHECK: extract_false: False
-- CHECK: wrap_int: 42


type ForceMultiline
    = ForceMultiline Bool


type Wrapper
    = Wrapper Int


nestedMatch : Bool -> String
nestedMatch b =
    let
        fm =
            ForceMultiline b
    in
    case fm of
        ForceMultiline True ->
            "split"

        ForceMultiline False ->
            "join"


extractBool : ForceMultiline -> Bool
extractBool fm =
    case fm of
        ForceMultiline b ->
            b


useWrapper : Wrapper -> Int
useWrapper w =
    case w of
        Wrapper n ->
            n


main =
    let
        _ = Debug.log "nested_true" (nestedMatch True)
        _ = Debug.log "nested_false" (nestedMatch False)
        _ = Debug.log "extract_true" (extractBool (ForceMultiline True))
        _ = Debug.log "extract_false" (extractBool (ForceMultiline False))
        _ = Debug.log "wrap_int" (useWrapper (Wrapper 42))
    in
    text "done"
```

### CaseSingleCtorBool

**Expected:** `nested_true: "split"`, `nested_false: "join"`, `extract_true: True`, `extract_false: False`

```elm
{-| Test case expression on a single-constructor custom type wrapping Bool.

Reproduces a codegen bug where eco.project.custom emits i64 (tag type) for a
Bool field inside a single-constructor wrapper, but the subsequent eco.case
with case_kind="bool" expects i1.
-}

-- CHECK: nested_true: "split"
-- CHECK: nested_false: "join"
-- CHECK: extract_true: True
-- CHECK: extract_false: False


type ForceMultiline
    = ForceMultiline Bool


nestedMatch : Bool -> String
nestedMatch b =
    let
        fm =
            ForceMultiline b
    in
    case fm of
        ForceMultiline True ->
            "split"

        ForceMultiline False ->
            "join"


extractBool : ForceMultiline -> Bool
extractBool fm =
    case fm of
        ForceMultiline b ->
            b


main =
    let
        _ = Debug.log "nested_true" (nestedMatch True)
        _ = Debug.log "nested_false" (nestedMatch False)
        _ = Debug.log "extract_true" (extractBool (ForceMultiline True))
        _ = Debug.log "extract_false" (extractBool (ForceMultiline False))
    in
    text "done"
```

### CaseStringEscape

**Expected:** `esc1: "newline"`, `esc2: "tab"`, `esc3: "quote"`, `esc4: "other"`

```elm
{-| Test case expression with string patterns containing escape characters.
-}

-- CHECK: esc1: "newline"
-- CHECK: esc2: "tab"
-- CHECK: esc3: "quote"
-- CHECK: esc4: "other"


describeEscape s =
    case s of
        "\n" -> "newline"
        "\t" -> "tab"
        "\"" -> "quote"
        _ -> "other"


main =
    let
        _ = Debug.log "esc1" (describeEscape "\n")
        _ = Debug.log "esc2" (describeEscape "\t")
        _ = Debug.log "esc3" (describeEscape "\"")
        _ = Debug.log "esc4" (describeEscape "hello")
    in
    text "done"
```

### CaseString

**Expected:** `case1: 1`, `case2: 2`, `case3: 0`

```elm
{-| Test case expression on String.
-}

-- CHECK: case1: 1
-- CHECK: case2: 2
-- CHECK: case3: 0


strToNum s =
    case s of
        "one" -> 1
        "two" -> 2
        _ -> 0


main =
    let
        _ = Debug.log "case1" (strToNum "one")
        _ = Debug.log "case2" (strToNum "two")
        _ = Debug.log "case3" (strToNum "other")
    in
    text "done"
```

### CaseTree

**Expected:** `tree1: 0`, `tree2: 1`, `tree3: 3`

```elm
{-| Test case expression on recursive tree type.
-}

-- CHECK: tree1: 0
-- CHECK: tree2: 1
-- CHECK: tree3: 3


type Tree
    = Leaf
    | Node Tree Int Tree


countNodes tree =
    case tree of
        Leaf -> 0
        Node left _ right -> 1 + countNodes left + countNodes right


main =
    let
        _ = Debug.log "tree1" (countNodes Leaf)
        _ = Debug.log "tree2" (countNodes (Node Leaf 1 Leaf))
        _ = Debug.log "tree3" (countNodes (Node (Node Leaf 2 Leaf) 1 (Node Leaf 3 Leaf)))
    in
    text "done"
```

### CaseTriple

**Expected:** `triple1: "all zero"`, `triple2: "x zero"`, `triple3: "z zero"`, `triple4: "none zero"`

```elm
{-| Test case expression on 3-tuples.
-}

-- CHECK: triple1: "all zero"
-- CHECK: triple2: "x zero"
-- CHECK: triple3: "z zero"
-- CHECK: triple4: "none zero"


describeTriple triple =
    case triple of
        (0, 0, 0) -> "all zero"
        (0, _, _) -> "x zero"
        (_, _, 0) -> "z zero"
        _ -> "none zero"


main =
    let
        _ = Debug.log "triple1" (describeTriple (0, 0, 0))
        _ = Debug.log "triple2" (describeTriple (0, 1, 2))
        _ = Debug.log "triple3" (describeTriple (1, 2, 0))
        _ = Debug.log "triple4" (describeTriple (1, 2, 3))
    in
    text "done"
```

### CaseTuple

**Expected:** `pair1: "both zero"`, `pair2: "x is zero"`, `pair3: "y is zero"`, `pair4: "neither zero"`

```elm
{-| Test case expression on tuples.
-}

-- CHECK: pair1: "both zero"
-- CHECK: pair2: "x is zero"
-- CHECK: pair3: "y is zero"
-- CHECK: pair4: "neither zero"


describePair pair =
    case pair of
        (0, 0) -> "both zero"
        (0, _) -> "x is zero"
        (_, 0) -> "y is zero"
        _ -> "neither zero"


main =
    let
        _ = Debug.log "pair1" (describePair (0, 0))
        _ = Debug.log "pair2" (describePair (0, 5))
        _ = Debug.log "pair3" (describePair (3, 0))
        _ = Debug.log "pair4" (describePair (1, 2))
    in
    text "done"
```

### CaseUnicodeChar

**Expected:** `char1: "greek alpha"`, `char2: "greek beta"`, `char3: "cjk"`, `char4: "other"`

```elm
{-| Test case expression with unicode character patterns.
-}

-- CHECK: char1: "greek alpha"
-- CHECK: char2: "greek beta"
-- CHECK: char3: "cjk"
-- CHECK: char4: "other"


describeUnicode c =
    case c of
        'α' -> "greek alpha"
        'β' -> "greek beta"
        '日' -> "cjk"
        _ -> "other"


main =
    let
        _ = Debug.log "char1" (describeUnicode 'α')
        _ = Debug.log "char2" (describeUnicode 'β')
        _ = Debug.log "char3" (describeUnicode '日')
        _ = Debug.log "char4" (describeUnicode 'x')
    in
    text "done"
```

### CeilingToInt

**Expected:** `ceil1: 3`, `ceil2: -2`

```elm
{-| Test ceiling for Float to Int conversion.
-}

-- CHECK: ceil1: 3
-- CHECK: ceil2: -2


main =
    let
        _ = Debug.log "ceil1" (ceiling 2.3)
        _ = Debug.log "ceil2" (ceiling -2.7)
    in
    text "done"
```

### CharCasePredicate

**Expected:** `result: "comma"`

```elm
{-| FAILING TEST: arith.cmpi missing predicate attribute for i16 (Char) comparisons.

Bug: When the pattern compiler generates equality tests for Char patterns (IsChr),
it calls Ops.ecoBinaryOp which only sets _operand_types but NOT the required
predicate attribute. The correct function to use is Ops.arithCmpI which sets both.

i32 comparisons (Int) work correctly because they use eco.int.eq (an eco dialect op).
i16 comparisons (Char) incorrectly use raw arith.cmpi without the predicate attribute.

NOTE: This bug only manifests in Stage 6 (eco-boot-native MLIR parsing/verification).
The JIT test infrastructure may not catch it because it handles the missing predicate
differently. The elm-test CmpiPredicateAttrTest catches it at the MLIR generation level.

See: compiler/src/Compiler/Generate/MLIR/Patterns.elm line 205
-}

-- CHECK: result: "comma"


classify : Char -> String
classify c =
    case c of
        ',' ->
            "comma"

        '{' ->
            "open brace"

        '\\' ->
            "backslash"

        _ ->
            "other"


main =
    let
        result = classify ','
        _ = Debug.log "result" result
    in
    text result
```

### CharFromCode

**Expected:** `char1: 'A'`, `char2: 'a'`, `char3: '0'`

```elm
{-| Test Char.fromCode.
-}

-- CHECK: char1: 'A'
-- CHECK: char2: 'a'
-- CHECK: char3: '0'


main =
    let
        _ = Debug.log "char1" (Char.fromCode 65)
        _ = Debug.log "char2" (Char.fromCode 97)
        _ = Debug.log "char3" (Char.fromCode 48)
    in
    text "done"
```

### CharIsAlpha

**Expected:** `alpha1: True`, `alpha2: True`, `alpha3: False`, `alpha4: False`

```elm
{-| Test Char.isAlpha.
-}

-- CHECK: alpha1: True
-- CHECK: alpha2: True
-- CHECK: alpha3: False
-- CHECK: alpha4: False


main =
    let
        _ = Debug.log "alpha1" (Char.isAlpha 'a')
        _ = Debug.log "alpha2" (Char.isAlpha 'Z')
        _ = Debug.log "alpha3" (Char.isAlpha '0')
        _ = Debug.log "alpha4" (Char.isAlpha ' ')
    in
    text "done"
```

### CharIsDigit

**Expected:** `digit1: True`, `digit2: True`, `digit3: False`, `digit4: False`

```elm
{-| Test Char.isDigit.
-}

-- CHECK: digit1: True
-- CHECK: digit2: True
-- CHECK: digit3: False
-- CHECK: digit4: False


main =
    let
        _ = Debug.log "digit1" (Char.isDigit '0')
        _ = Debug.log "digit2" (Char.isDigit '9')
        _ = Debug.log "digit3" (Char.isDigit 'a')
        _ = Debug.log "digit4" (Char.isDigit 'A')
    in
    text "done"
```

### CharToCode

**Expected:** `code1: 65`, `code2: 97`, `code3: 48`

```elm
{-| Test Char.toCode.
-}

-- CHECK: code1: 65
-- CHECK: code2: 97
-- CHECK: code3: 48


main =
    let
        _ = Debug.log "code1" (Char.toCode 'A')
        _ = Debug.log "code2" (Char.toCode 'a')
        _ = Debug.log "code3" (Char.toCode '0')
    in
    text "done"
```

### CharToLower

**Expected:** `lower1: 'a'`, `lower2: 'z'`, `lower3: '0'`

```elm
{-| Test Char.toLower.
-}

-- CHECK: lower1: 'a'
-- CHECK: lower2: 'z'
-- CHECK: lower3: '0'


main =
    let
        _ = Debug.log "lower1" (Char.toLower 'A')
        _ = Debug.log "lower2" (Char.toLower 'Z')
        _ = Debug.log "lower3" (Char.toLower '0')
    in
    text "done"
```

### CharToUpper

**Expected:** `upper1: 'A'`, `upper2: 'Z'`, `upper3: '0'`

```elm
{-| Test Char.toUpper.
-}

-- CHECK: upper1: 'A'
-- CHECK: upper2: 'Z'
-- CHECK: upper3: '0'


main =
    let
        _ = Debug.log "upper1" (Char.toUpper 'a')
        _ = Debug.log "upper2" (Char.toUpper 'z')
        _ = Debug.log "upper3" (Char.toUpper '0')
    in
    text "done"
```

### CharUnicode

**Expected:** `code1: 955`, `code2: 8364`

```elm
{-| Test Unicode characters.
-}

-- CHECK: code1: 955
-- CHECK: code2: 8364


main =
    let
        -- Greek lambda
        _ = Debug.log "code1" (Char.toCode '\u{03BB}')
        -- Euro sign
        _ = Debug.log "code2" (Char.toCode '\u{20AC}')
    in
    text "done"
```

---

# E2E Test Catalogue -- Part 3

## E2E Tests: Closure / Combinator / Comparable / Compare / Composition / CustomType / DictMap / Equality

### ClosureCapture01

**Expected:** `unwrap1: 42`, `unwrap2: 99`

```elm
{-| Test closure captures variable used only in single-ctor destruct.

Uses explicit lambda return (`f w = \dummy -> ...`) to force nested
Function nodes in the TypedOpt AST. The inner lambda captures `w`,
which appears only as the root of a destruct path (MonoRoot).
This triggers the collectVarTypes traversal asymmetry bug.
-}

-- CHECK: unwrap1: 42
-- CHECK: unwrap2: 99


type Wrapper a
    = Wrap a


unwrapLater : Wrapper Int -> (Int -> Int)
unwrapLater w =
    \dummy ->
        case w of
            Wrap x ->
                x


main =
    let
        _ = Debug.log "unwrap1" (unwrapLater (Wrap 42) 0)
        _ = Debug.log "unwrap2" (unwrapLater (Wrap 99) 0)
    in
    text "done"
```

### ClosureCapture02

**Expected:** `just: "hello"`, `nothing: "none"`

```elm
{-| Test closure captures Maybe variable used only in case destruct.

Uses explicit lambda return to force nested Function nodes.
The inner lambda captures `m`, which appears only as the root of
destruct paths (MonoRoot) in the case expression.
-}

-- CHECK: just: "hello"
-- CHECK: nothing: "none"


toLabel : Maybe String -> (Int -> String)
toLabel m =
    \dummy ->
        case m of
            Just s ->
                s

            Nothing ->
                "none"


main =
    let
        _ = Debug.log "just" (toLabel (Just "hello") 0)
        _ = Debug.log "nothing" (toLabel Nothing 0)
    in
    text "done"
```

### ClosureCapture03

**Expected:** `ok: 42`, `err: -1`

```elm
{-| Test closure captures Result variable used only in case destruct.

Uses explicit lambda return to force nested Function nodes.
The inner lambda captures `r`, which appears only as the root of
destruct paths. Tests a two-constructor type where both carry payloads.
-}

-- CHECK: ok: 42
-- CHECK: err: -1


type MyResult a b
    = Ok a
    | Err b


resultToInt : MyResult Int String -> (Int -> Int)
resultToInt r =
    \dummy ->
        case r of
            Ok n ->
                n

            Err _ ->
                -1


main =
    let
        _ = Debug.log "ok" (resultToInt (Ok 42) 0)
        _ = Debug.log "err" (resultToInt (Err "bad") 0)
    in
    text "done"
```

### ClosureCapture04

**Expected:** `both: 30`, `first: 10`, `neither: 0`

```elm
{-| Test closure captures two variables both used only in destructs.

Uses explicit lambda return to force nested Function nodes.
Both `mx` and `my` are captured by the inner lambda and appear only
as roots of destruct paths, never as standalone variable references.
-}

-- CHECK: both: 30
-- CHECK: first: 10
-- CHECK: neither: 0


addMaybes : Maybe Int -> Maybe Int -> (Int -> Int)
addMaybes mx my =
    \dummy ->
        let
            a =
                case mx of
                    Just x ->
                        x

                    Nothing ->
                        0

            b =
                case my of
                    Just y ->
                        y

                    Nothing ->
                        0
        in
        a + b


main =
    let
        _ = Debug.log "both" (addMaybes (Just 10) (Just 20) 0)
        _ = Debug.log "first" (addMaybes (Just 10) Nothing 0)
        _ = Debug.log "neither" (addMaybes Nothing Nothing 0)
    in
    text "done"
```

### ClosureCapture05

**Expected:** `both: "ab"`, `one: "a"`, `none: ""`

```elm
{-| Test closure captures variable used in nested case destruct.

Uses explicit lambda return to force nested Function nodes.
The captured variable `pair` is a custom type containing two Maybes.
The inner lambda destructs `pair` and then further destructs the
extracted Maybe values.
-}

-- CHECK: both: "ab"
-- CHECK: one: "a"
-- CHECK: none: ""


type Pair a b
    = Pair a b


extractStrings : Pair (Maybe String) (Maybe String) -> (Int -> String)
extractStrings pair =
    \dummy ->
        case pair of
            Pair ma mb ->
                let
                    a =
                        case ma of
                            Just s ->
                                s

                            Nothing ->
                                ""

                    b =
                        case mb of
                            Just s ->
                                s

                            Nothing ->
                                ""
                in
                a ++ b


main =
    let
        _ = Debug.log "both" (extractStrings (Pair (Just "a") (Just "b")) 0)
        _ = Debug.log "one" (extractStrings (Pair (Just "a") Nothing) 0)
        _ = Debug.log "none" (extractStrings (Pair Nothing Nothing) 0)
    in
    text "done"
```

### ClosureCapture06

**Expected:** `both: "ab"`, `one: "a"`, `none: ""`

```elm
{-| Test nested case destruct with flat multi-arg function.

This is the flat-form version of a nested destruct pattern (Pair containing
two Maybes). It compiles successfully but triggers a runtime error, which
should be investigated separately from the closure capture compilation bug.
-}

-- CHECK: both: "ab"
-- CHECK: one: "a"
-- CHECK: none: ""


type Pair a b
    = Pair a b


extractStrings : Pair (Maybe String) (Maybe String) -> Int -> String
extractStrings pair dummy =
    case pair of
        Pair ma mb ->
            let
                a =
                    case ma of
                        Just s ->
                            s

                        Nothing ->
                            ""

                b =
                    case mb of
                        Just s ->
                            s

                        Nothing ->
                            ""
            in
            a ++ b


main =
    let
        _ = Debug.log "both" (extractStrings (Pair (Just "a") (Just "b")) 0)
        _ = Debug.log "one" (extractStrings (Pair (Just "a") Nothing) 0)
        _ = Debug.log "none" (extractStrings (Pair Nothing Nothing) 0)
    in
    text "done"
```

### ClosureCaptureBool

**Expected:** `when_true: 1`, `when_false: 0`

```elm
{-| Test Bool captured in a closure via partial application.

A Bool value is captured in a closure (papCreate). Per REP_CLOSURE_001 and
FORBID_CLOSURE_001, Bool must be stored as !eco.value in closures, NOT as
bare i1. This test triggers the bug where the codegen produces an i1 capture
operand with unboxed_bitmap=0, creating a type mismatch (the runtime sees
the bit as "boxed pointer" but receives a bare i1 scalar).

The pattern: a function takes a Bool and an Int, partially applied with
just the Bool to create a closure, then the closure is called with the Int.
-}

-- CHECK: when_true: 1
-- CHECK: when_false: 0


boolToInt : Bool -> Int -> Int
boolToInt flag dummy =
    if flag then
        1
    else
        0


main =
    let
        trueF =
            boolToInt True

        falseF =
            boolToInt False

        _ = Debug.log "when_true" (trueF 0)
        _ = Debug.log "when_false" (falseF 0)
    in
    text "done"
```

### CombinatorBCompose

**Expected:** `result: 25`

```elm
{-| B combinator (compose): square << inc on 4 = 25
-}

-- CHECK: result: 25


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

inc x = x + 1
square x = x * x


main =
    let
        _ = Debug.log "result" (b square inc 4)
    in
    text "done"
```

### CombinatorBSumMap

**Expected:** `result: 9`

```elm
{-| B combinator with List.sum and List.map: sum (map ((+) 1) [1,2,3]) = 9
-}

-- CHECK: result: 9


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k


main =
    let
        _ = Debug.log "result" (b List.sum (List.map ((+) 1)) [ 1, 2, 3 ])
    in
    text "done"
```

### CombinatorCCons

**Expected:** `result: [1,2,3]`

```elm
{-| C combinator with cons: c (::) [2,3] 1 = [1,2,3]
-}

-- CHECK: result: [1,2,3]


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)


main =
    let
        _ = Debug.log "result" (c (::) [ 2, 3 ] 1)
    in
    text "done"
```

### CombinatorCFlip

**Expected:** `result: -7`

```elm
{-| C combinator (flip): flipped subtraction on 10 and 3 = -7
-}

-- CHECK: result: -7


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

sub x y = x - y


main =
    let
        _ = Debug.log "result" (c sub 10 3)
    in
    text "done"
```

### CombinatorIIdentity

**Expected:** `result: 42`

```elm
{-| I combinator (identity via S K K): i 42 = 42
-}

-- CHECK: result: 42


k a _ = a

s bf uf x = bf x (uf x)

i = s k k


main =
    let
        _ = Debug.log "result" (i 42)
    in
    text "done"
```

### CombinatorListString

**Expected:** `b_sum_map: 9`, `sp_mul: 84`, `w_concat: hihi`, `c_cons: [1,2,3]`, `s_palindrome: strawwarts`, `t_pipe: 12`, `p_lengths: 5`

```elm
{-| Test SKI-style combinators with lists, strings, and stdlib functions.
-}

-- CHECK: b_sum_map: 9
-- CHECK: sp_mul: 84
-- CHECK: w_concat: hihi
-- CHECK: c_cons: [1,2,3]
-- CHECK: s_palindrome: strawwarts
-- CHECK: t_pipe: 12
-- CHECK: p_lengths: 5


k a _ = a

s bf uf x = bf x (uf x)

i = s k k

b = s (k s) k

c = s (b b s) (k k)

sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

t = c i

w bf x = bf x x

p bf uf x y = bf (uf x) (uf y)


main =
    let
        _ = Debug.log "b_sum_map" (b List.sum (List.map ((+) 1)) [ 1, 2, 3 ])
        _ = Debug.log "sp_mul" (sp (*) ((+) 1) ((*) 2) 6)
        _ = Debug.log "w_concat" (w (++) "hi")
        _ = Debug.log "c_cons" (c (::) [ 2, 3 ] 1)
        _ = Debug.log "s_palindrome" (s (++) String.reverse "straw")
        _ = Debug.log "t_pipe" (t [ 1, 2, 3 ] (b List.sum (List.map ((*) 2))))
        _ = Debug.log "p_lengths" (p (+) List.length [ 1, 2, 3 ] [ 4, 5 ])
    in
    text "done"
```

### CombinatorPLengths

**Expected:** `result: 5`

```elm
{-| P combinator: add lengths of two lists = 5
-}

-- CHECK: result: 5


p bf uf x y = bf (uf x) (uf y)


main =
    let
        _ = Debug.log "result" (p (+) List.length [ 1, 2, 3 ] [ 4, 5 ])
    in
    text "done"
```

### CombinatorSFeed

**Expected:** `result: 15`

```elm
{-| S combinator: x + double x on 5 = 15
-}

-- CHECK: result: 15


s bf uf x = bf x (uf x)

double x = x * 2


main =
    let
        _ = Debug.log "result" (s (+) double 5)
    in
    text "done"
```

### CombinatorSPalindrome

**Expected:** `result: strawwarts`

```elm
{-| S combinator with String.reverse: "straw" ++ reverse "straw" = "strawwarts"
-}

-- CHECK: result: strawwarts


s bf uf x = bf x (uf x)


main =
    let
        _ = Debug.log "result" (s (++) String.reverse "straw")
    in
    text "done"
```

### CombinatorSpCombine

**Expected:** `result: 84`

```elm
{-| SP combinator: (inc x) * (double x) on 6 = 84
-}

-- CHECK: result: 84


sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

inc x = x + 1
double x = x * 2
mul x y = x * y


main =
    let
        _ = Debug.log "result" (sp mul inc double 6)
    in
    text "done"
```

### CombinatorSpMul

**Expected:** `result: 84`

```elm
{-| SP combinator with operator sections: ((+) 1 x) * ((*) 2 x) at x=6 = 84
-}

-- CHECK: result: 84


sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)


main =
    let
        _ = Debug.log "result" (sp (*) ((+) 1) ((*) 2) 6)
    in
    text "done"
```

### Combinator

**Expected:** `b_compose: 25`, `c_flip: -7`, `s_feed: 15`, `sp_combine: 84`, `w_dup: 81`, `t_thrush: 21`, `i_identity: 42`

```elm
{-| Test SKI-style combinators built from S and K.
-}

-- CHECK: b_compose: 25
-- CHECK: c_flip: -7
-- CHECK: s_feed: 15
-- CHECK: sp_combine: 84
-- CHECK: w_dup: 81
-- CHECK: t_thrush: 21
-- CHECK: i_identity: 42


-- Combinators

k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

t = c i

i = s k k

w bf x = bf x x


-- Helpers

inc x = x + 1
double x = x * 2
square x = x * x
sub x y = x - y
mul x y = x * y


main =
    let
        _ = Debug.log "b_compose" (b square inc 4)
        _ = Debug.log "c_flip" (c sub 10 3)
        _ = Debug.log "s_feed" (s (+) double 5)
        _ = Debug.log "sp_combine" (sp mul inc double 6)
        _ = Debug.log "w_dup" (w mul 9)
        _ = Debug.log "t_thrush" (t 7 (\x -> x * 3))
        _ = Debug.log "i_identity" (i 42)
    in
    text "done"
```

### CombinatorTPipe

**Expected:** `result: 12`

```elm
{-| T combinator: pipe [1,2,3] into (sum << map ((*) 2)) = 12
-}

-- CHECK: result: 12


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

i = s k k

t = c i


main =
    let
        _ = Debug.log "result" (t [ 1, 2, 3 ] (b List.sum (List.map ((*) 2))))
    in
    text "done"
```

### CombinatorTThrush

**Expected:** `result: 21`

```elm
{-| T combinator (thrush): pipe 7 into (\x -> x * 3) = 21
-}

-- CHECK: result: 21


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

i = s k k

t = c i


main =
    let
        _ = Debug.log "result" (t 7 (\x -> x * 3))
    in
    text "done"
```

### CombinatorWConcat

**Expected:** `result: hihi`

```elm
{-| W combinator with string append: w (++) "hi" = "hihi"
-}

-- CHECK: result: hihi


w bf x = bf x x


main =
    let
        _ = Debug.log "result" (w (++) "hi")
    in
    text "done"
```

### CombinatorWDup

**Expected:** `result: 81`

```elm
{-| W combinator: x * x on 9 = 81
-}

-- CHECK: result: 81


w bf x = bf x x

mul x y = x * y


main =
    let
        _ = Debug.log "result" (w mul 9)
    in
    text "done"
```

### ComparableMinMax

**Expected:** `minStr: "apple"`, `maxStr: "zebra"`, `minChar: 'a'`, `maxChar: 'z'`

```elm
{-| Test min and max on Comparable types.
-}

-- CHECK: minStr: "apple"
-- CHECK: maxStr: "zebra"
-- CHECK: minChar: 'a'
-- CHECK: maxChar: 'z'


main =
    let
        _ = Debug.log "minStr" (min "apple" "zebra")
        _ = Debug.log "maxStr" (max "apple" "zebra")
        _ = Debug.log "minChar" (min 'a' 'z')
        _ = Debug.log "maxChar" (max 'a' 'z')
    in
    text "done"
```

### CompareChar

**Expected:** `cmp1: LT`, `cmp2: GT`, `cmp3: EQ`

```elm
{-| Test compare on Char.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ


main =
    let
        _ = Debug.log "cmp1" (compare 'a' 'b')
        _ = Debug.log "cmp2" (compare 'z' 'a')
        _ = Debug.log "cmp3" (compare 'x' 'x')
    in
    text "done"
```

### CompareFloat

**Expected:** `cmp1: LT`, `cmp2: GT`, `cmp3: EQ`

```elm
{-| Test compare on Float.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ


main =
    let
        _ = Debug.log "cmp1" (compare 1.5 2.5)
        _ = Debug.log "cmp2" (compare 3.14 2.71)
        _ = Debug.log "cmp3" (compare 5.0 5.0)
    in
    text "done"
```

### CompareInt

**Expected:** `cmp1: LT`, `cmp2: GT`, `cmp3: EQ`

```elm
{-| Test compare on Int.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ


main =
    let
        _ = Debug.log "cmp1" (compare 1 2)
        _ = Debug.log "cmp2" (compare 3 2)
        _ = Debug.log "cmp3" (compare 5 5)
    in
    text "done"
```

### CompareString

**Expected:** `cmp1: LT`, `cmp2: GT`, `cmp3: EQ`

```elm
{-| Test compare on String.
-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ


main =
    let
        _ = Debug.log "cmp1" (compare "apple" "banana")
        _ = Debug.log "cmp2" (compare "zebra" "ant")
        _ = Debug.log "cmp3" (compare "hello" "hello")
    in
    text "done"
```

### Composition

**Expected:** `compose1: 20`, `compose2: 11`, `pipe1: 20`

```elm
{-| Test function composition.
-}

-- CHECK: compose1: 20
-- CHECK: compose2: 11
-- CHECK: pipe1: 20


double x = x * 2
addOne x = x + 1


main =
    let
        -- (>>) left-to-right composition: first addOne, then double
        addOneThenDouble = addOne >> double
        -- (<<) right-to-left composition: first double, then addOne
        doubleThenAddOne = addOne << double
        _ = Debug.log "compose1" (addOneThenDouble 9)
        _ = Debug.log "compose2" (doubleThenAddOne 5)
        -- Pipe operator
        _ = Debug.log "pipe1" (9 |> addOne |> double)
    in
    text "done"
```

### CustomTypeBasic

**Expected:** `color1: Red`, `color2: Green`, `color3: Blue`

```elm
{-| Test basic custom type creation.
-}

-- CHECK: color1: Red
-- CHECK: color2: Green
-- CHECK: color3: Blue


type Color
    = Red
    | Green
    | Blue


main =
    let
        _ = Debug.log "color1" Red
        _ = Debug.log "color2" Green
        _ = Debug.log "color3" Blue
    in
    text "done"
```

### CustomTypeMultiField

**Expected:** `person`

```elm
{-| Test custom types with multiple fields.
-}

-- CHECK: person


type Person
    = Person String Int Bool


main =
    let
        p = Person "Alice" 30 True
        _ = Debug.log "person" p
    in
    text "done"
```

### CustomTypeNested

**Expected:** `nested`

```elm
{-| Test nested custom types.
-}

-- CHECK: nested


type Tree a
    = Leaf a
    | Node (Tree a) (Tree a)


main =
    let
        tree = Node (Leaf 1) (Node (Leaf 2) (Leaf 3))
        _ = Debug.log "nested" tree
    in
    text "done"
```

### CustomTypePattern

**Expected:** `name: "Alice"`, `age: 30`

```elm
{-| Test pattern matching on custom types with extraction.
-}

-- CHECK: name: "Alice"
-- CHECK: age: 30


type Person
    = Person String Int


getName (Person name _) = name
getAge (Person _ age) = age


main =
    let
        p = Person "Alice" 30
        _ = Debug.log "name" (getName p)
        _ = Debug.log "age" (getAge p)
    in
    text "done"
```

### DictMapStagedCapture

**Expected:** `result: [("a", ("hello", 15)), ("b", ("world", 25))]`

```elm
{-| Test: captured function parameter applied to multiple args inside Dict.map lambda.

Reproduces a bug where a captured function with staged type (returns a function)
is only partially applied inside a closure -- the second arg is silently dropped.

The pattern mirrors Data.Map.map: Dict stores (k, v) tuples, and the mapping
lambda destructures the tuple and applies the captured function to both parts.
-}

-- CHECK: result: [("a", ("hello", 15)), ("b", ("world", 25))]

import Dict


{-| A function that returns another function (naturally staged).
makeAdder "hello" returns (\value -> 5 + value).
-}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Dict.map wrapper: captures 'alter' in a lambda that applies it to 2 args.
This is the pattern from Data.Map.map.
-}
mapTupleDict : (String -> Int -> Int) -> Dict.Dict String ( String, Int ) -> Dict.Dict String ( String, Int )
mapTupleDict alter dict =
    Dict.map (\_ ( key, value ) -> ( key, alter key value )) dict


main =
    let
        d =
            Dict.fromList
                [ ( "a", ( "hello", 10 ) )
                , ( "b", ( "world", 20 ) )
                ]

        result =
            mapTupleDict makeAdder d

        _ =
            Debug.log "result" (Dict.toList result)
    in
    text "done"
```

### EqualityCharPap

**Expected:** `filtered: ['a', 'a']`

```elm
{-| Test that using (==) as a function value on Char works correctly.
Char uses i16 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: ['a', 'a']


main =
    let
        eq = (==)
        filtered = List.filter (eq 'a') ['a', 'b', 'a', 'c']
        _ = Debug.log "filtered" filtered
    in
    text "done"
```

### EqualityFloatPap

**Expected:** `filtered: [1.5, 1.5]`

```elm
{-| Test that using (==) as a function value on Float works correctly.
Float uses f64 ABI, so kernel PAP must use AllBoxed (!eco.value).
-}

-- CHECK: filtered: [1.5, 1.5]


main =
    let
        eq = (==)
        filtered = List.filter (eq 1.5) [1.0, 1.5, 2.0, 1.5]
        _ = Debug.log "filtered" filtered
    in
    text "done"
```

### EqualityIntPapWithStringChain

**Expected:** `filtered: [5, 5]`, `classify: "matched foo"`

```elm
{-| Test that using (==) as a function value on Int coexists with
string pattern matching in a case expression. Both paths register
Elm_Kernel_Utils_equal - the PAP path must use AllBoxed ABI.
Exercises CGEN_038 and KERN_006.
-}

-- CHECK: filtered: [5, 5]
-- CHECK: classify: "matched foo"


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        "bar" ->
            "matched bar"

        _ ->
            "other"


main =
    let
        eq = (==)
        filtered = List.filter (eq 5) [1, 2, 5, 3, 5]
        _ = Debug.log "filtered" filtered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
```

### EqualityMultiTypePap

**Expected:** `intFiltered: [3, 3]`, `strFiltered: ["b", "b"]`, `classify: "matched foo"`

```elm
{-| Test that (==) used as a function value across multiple types
(Int, String, Char) in the same module does not cause kernel
signature mismatch. All must use AllBoxed ABI.
-}

-- CHECK: intFiltered: [3, 3]
-- CHECK: strFiltered: ["b", "b"]
-- CHECK: classify: "matched foo"


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        _ ->
            "other"


main =
    let
        eqInt = (==)
        eqStr = (==)
        intFiltered = List.filter (eqInt 3) [1, 2, 3, 4, 3]
        strFiltered = List.filter (eqStr "b") ["a", "b", "c", "b"]
        _ = Debug.log "intFiltered" intFiltered
        _ = Debug.log "strFiltered" strFiltered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
```

### EqualityPapWithStringChain

**Expected:** `filter: ["a", "a"]`

```elm
{-| Test that using (==) as a function value (PAP) coexists with string
chain patterns in tuple case expressions.

This validates that the kernel ABI for Utils_equal is consistent:
the PAP path and the IsStr chain path both use eco.value return.
-}

-- CHECK: filter: ["a", "a"]


main =
    let
        eq = (==)
        filtered = List.filter (eq "a") ["a", "b", "a"]
        _ = Debug.log "filter" filtered
    in
    text "done"
```

### EqualityStringChainCase

**Expected:** `case1: "matched foo+True"`, `case2: "matched bar+False"`, `case3: "other"`, `eq1: True`, `eq2: False`

```elm
{-| Test that string equality in chain patterns (tuple case) coexists with
direct string equality calls.

When a string pattern appears in a tuple case like (String, Bool), the
decision tree may produce a Chain node with IsStr test, which calls
Utils_equal with I1 return. Direct (==) on strings calls Utils_equal
with eco.value return. Both must use the same kernel signature.
-}

-- CHECK: case1: "matched foo+True"
-- CHECK: case2: "matched bar+False"
-- CHECK: case3: "other"
-- CHECK: eq1: True
-- CHECK: eq2: False


classify : String -> Bool -> String
classify s b =
    case ( s, b ) of
        ( "foo", True ) -> "matched foo+True"
        ( "bar", False ) -> "matched bar+False"
        _ -> "other"


main =
    let
        _ = Debug.log "case1" (classify "foo" True)
        _ = Debug.log "case2" (classify "bar" False)
        _ = Debug.log "case3" (classify "baz" True)
        _ = Debug.log "eq1" ("hello" == "hello")
        _ = Debug.log "eq2" ("hello" == "world")
    in
    text "done"
```

### Equality

**Expected:** `eq1: True`, `eq2: False`, `ne1: True`, `ne2: False`, `listEq: True`

```elm
{-| Test equality operators.
-}

-- CHECK: eq1: True
-- CHECK: eq2: False
-- CHECK: ne1: True
-- CHECK: ne2: False
-- CHECK: listEq: True


main =
    let
        _ = Debug.log "eq1" (5 == 5)
        _ = Debug.log "eq2" (5 == 6)
        _ = Debug.log "ne1" (5 /= 6)
        _ = Debug.log "ne2" (5 /= 5)
        _ = Debug.log "listEq" ([1, 2, 3] == [1, 2, 3])
    in
    text "done"
```

---

## E2E Tests: Flip / Float / Floor / Function / Hello / HeteroClosure / HigherOrder / HOParam / IndirectCall / InlineVar / Int

### FlipFunction

**Expected:** `result: 3.14`

```elm
{-| Test flip function with type annotation.
-}

-- CHECK: result: 3.14


flip : (a -> b -> c) -> b -> a -> c
flip f y x = f x y


main =
    let
        result = flip (\a b -> 3.14) "world" 7
        _ = Debug.log "result" result
    in
    text "done"
```

### FloatAbs

**Expected:** `abs1: 3.14`, `abs2: 3.14`, `abs3: 0`

```elm
{-| Test float absolute value.
-}

-- CHECK: abs1: 3.14
-- CHECK: abs2: 3.14
-- CHECK: abs3: 0


main =
    let
        _ = Debug.log "abs1" (abs 3.14)
        _ = Debug.log "abs2" (abs -3.14)
        _ = Debug.log "abs3" (abs 0.0)
    in
    text "done"
```

### FloatAdd

**Expected:** `add1: 13`, `add2: 0`, `add3: -5`

```elm
{-| Test float addition.
-}

-- CHECK: add1: 13
-- CHECK: add2: 0
-- CHECK: add3: -5


main =
    let
        _ = Debug.log "add1" (10.0 + 3.0)
        _ = Debug.log "add2" (5.0 + -5.0)
        _ = Debug.log "add3" (-2.0 + -3.0)
    in
    text "done"
```

### FloatCeiling

**Expected:** `ceil1: 3`, `ceil2: 2`, `ceil3: -2`, `ceil4: -2`

```elm
{-| Test ceiling function.
-}

-- CHECK: ceil1: 3
-- CHECK: ceil2: 2
-- CHECK: ceil3: -2
-- CHECK: ceil4: -2


main =
    let
        _ = Debug.log "ceil1" (ceiling 2.3)
        _ = Debug.log "ceil2" (ceiling 2.0)
        _ = Debug.log "ceil3" (ceiling -2.3)
        _ = Debug.log "ceil4" (ceiling -2.7)
    in
    text "done"
```

### FloatCompare

**Expected:** `lt: True`, `gt: True`, `le: True`, `ge: True`, `eq: True`, `ne: True`

```elm
{-| Test float comparisons.
-}

-- CHECK: lt: True
-- CHECK: gt: True
-- CHECK: le: True
-- CHECK: ge: True
-- CHECK: eq: True
-- CHECK: ne: True


main =
    let
        _ = Debug.log "lt" (3.14 < 10.0)
        _ = Debug.log "gt" (10.0 > 3.14)
        _ = Debug.log "le" (3.14 <= 3.14)
        _ = Debug.log "ge" (3.14 >= 3.14)
        _ = Debug.log "eq" (3.14 == 3.14)
        _ = Debug.log "ne" (3.14 /= 2.71)
    in
    text "done"
```

### FloatDiv

**Expected:** `div1: 2.5`, `div2: -2.5`, `div3: -2.5`, `div4: 2.5`

```elm
{-| Test float division.
-}

-- CHECK: div1: 2.5
-- CHECK: div2: -2.5
-- CHECK: div3: -2.5
-- CHECK: div4: 2.5


main =
    let
        _ = Debug.log "div1" (10.0 / 4.0)
        _ = Debug.log "div2" (-10.0 / 4.0)
        _ = Debug.log "div3" (10.0 / -4.0)
        _ = Debug.log "div4" (-10.0 / -4.0)
    in
    text "done"
```

### FloatFloor

**Expected:** `floor1: 2`, `floor2: 2`, `floor3: -3`, `floor4: -3`

```elm
{-| Test floor function.
-}

-- CHECK: floor1: 2
-- CHECK: floor2: 2
-- CHECK: floor3: -3
-- CHECK: floor4: -3


main =
    let
        _ = Debug.log "floor1" (floor 2.7)
        _ = Debug.log "floor2" (floor 2.0)
        _ = Debug.log "floor3" (floor -2.3)
        _ = Debug.log "floor4" (floor -2.7)
    in
    text "done"
```

### FloatInfinity

**Expected:** `isInf1: True`, `isInf2: True`, `isInf3: False`

```elm
{-| Test infinity behavior.
-}

-- CHECK: isInf1: True
-- CHECK: isInf2: True
-- CHECK: isInf3: False


main =
    let
        posInf = 1.0 / 0.0
        negInf = -1.0 / 0.0
        _ = Debug.log "isInf1" (isInfinite posInf)
        _ = Debug.log "isInf2" (isInfinite negInf)
        _ = Debug.log "isInf3" (isInfinite 3.14)
    in
    text "done"
```

### FloatMinMax

**Expected:** `min1: 3.14`, `min2: -5`, `max1: 10`, `max2: 5`

```elm
{-| Test min and max on floats.
-}

-- CHECK: min1: 3.14
-- CHECK: min2: -5
-- CHECK: max1: 10
-- CHECK: max2: 5


main =
    let
        _ = Debug.log "min1" (min 10.0 3.14)
        _ = Debug.log "min2" (min -5.0 5.0)
        _ = Debug.log "max1" (max 10.0 3.14)
        _ = Debug.log "max2" (max -5.0 5.0)
    in
    text "done"
```

### FloatMul

**Expected:** `mul1: 30`, `mul2: -15`, `mul3: 6`, `mul4: 0`

```elm
{-| Test float multiplication.
-}

-- CHECK: mul1: 30
-- CHECK: mul2: -15
-- CHECK: mul3: 6
-- CHECK: mul4: 0


main =
    let
        _ = Debug.log "mul1" (10.0 * 3.0)
        _ = Debug.log "mul2" (5.0 * -3.0)
        _ = Debug.log "mul3" (-2.0 * -3.0)
        _ = Debug.log "mul4" (0.0 * 100.0)
    in
    text "done"
```

### FloatNaN

**Expected:** `isNaN1: True`, `isNaN2: False`, `nanProp`

```elm
{-| Test NaN behavior.
-}

-- CHECK: isNaN1: True
-- CHECK: isNaN2: False
-- CHECK: nanProp


main =
    let
        nan = 0.0 / 0.0
        _ = Debug.log "isNaN1" (isNaN nan)
        _ = Debug.log "isNaN2" (isNaN 3.14)
        _ = Debug.log "nanProp" (nan + 1.0)
    in
    text "done"
```

### FloatNegate

**Expected:** `neg1: -3.14`, `neg2: 3.14`, `neg3: 0`

```elm
{-| Test float negation.
-}

-- CHECK: neg1: -3.14
-- CHECK: neg2: 3.14
-- CHECK: neg3: 0


main =
    let
        _ = Debug.log "neg1" (negate 3.14)
        _ = Debug.log "neg2" (negate -3.14)
        _ = Debug.log "neg3" (negate 0.0)
    in
    text "done"
```

### FloatNegativeZero

**Expected:** `eq: True`, `div1: Infinity`, `div2: -Infinity`

```elm
{-| Test negative zero behavior.
-}

-- CHECK: eq: True
-- CHECK: div1: Infinity
-- CHECK: div2: -Infinity


main =
    let
        negZero = -0.0
        _ = Debug.log "eq" (negZero == 0.0)
        _ = Debug.log "div1" (1.0 / 0.0)
        _ = Debug.log "div2" (1.0 / negZero)
    in
    text "done"
```

### FloatPow

**Expected:** `pow1: 8`, `pow2: 1`, `pow3: 1024`, `pow4: 0.5`

```elm
{-| Test float exponentiation.
-}

-- CHECK: pow1: 8
-- CHECK: pow2: 1
-- CHECK: pow3: 1024
-- CHECK: pow4: 0.5


main =
    let
        _ = Debug.log "pow1" (2.0 ^ 3.0)
        _ = Debug.log "pow2" (5.0 ^ 0.0)
        _ = Debug.log "pow3" (2.0 ^ 10.0)
        _ = Debug.log "pow4" (2.0 ^ -1.0)
    in
    text "done"
```

### FloatRound

**Expected:** `round1: 3`, `round2: 2`, `round3: -3`, `round4: 3`, `round5: 4`

```elm
{-| Test round function (banker's rounding - ties to even).
-}

-- CHECK: round1: 3
-- CHECK: round2: 2
-- CHECK: round3: -3
-- CHECK: round4: 3
-- CHECK: round5: 4


main =
    let
        _ = Debug.log "round1" (round 2.7)
        _ = Debug.log "round2" (round 2.3)
        _ = Debug.log "round3" (round -2.7)
        _ = Debug.log "round4" (round 2.5)
        _ = Debug.log "round5" (round 3.5)
    in
    text "done"
```

### FloatSqrt

**Expected:** `sqrt1: 2`, `sqrt2: 3`, `sqrt3: 0`

```elm
{-| Test square root.
-}

-- CHECK: sqrt1: 2
-- CHECK: sqrt2: 3
-- CHECK: sqrt3: 0


main =
    let
        _ = Debug.log "sqrt1" (sqrt 4.0)
        _ = Debug.log "sqrt2" (sqrt 9.0)
        _ = Debug.log "sqrt3" (sqrt 0.0)
    in
    text "done"
```

### FloatSub

**Expected:** `sub1: 7`, `sub2: 10`, `sub3: 1`

```elm
{-| Test float subtraction.
-}

-- CHECK: sub1: 7
-- CHECK: sub2: 10
-- CHECK: sub3: 1


main =
    let
        _ = Debug.log "sub1" (10.0 - 3.0)
        _ = Debug.log "sub2" (5.0 - -5.0)
        _ = Debug.log "sub3" (-2.0 - -3.0)
    in
    text "done"
```

### FloatTruncate

**Expected:** `trunc1: 2`, `trunc2: 2`, `trunc3: -2`, `trunc4: -2`

```elm
{-| Test truncate function (toward zero).
-}

-- CHECK: trunc1: 2
-- CHECK: trunc2: 2
-- CHECK: trunc3: -2
-- CHECK: trunc4: -2


main =
    let
        _ = Debug.log "trunc1" (truncate 2.7)
        _ = Debug.log "trunc2" (truncate 2.3)
        _ = Debug.log "trunc3" (truncate -2.3)
        _ = Debug.log "trunc4" (truncate -2.7)
    in
    text "done"
```

### FloorToInt

**Expected:** `floor1: 2`, `floor2: -3`

```elm
{-| Test floor for Float to Int conversion.
-}

-- CHECK: floor1: 2
-- CHECK: floor2: -3


main =
    let
        _ = Debug.log "floor1" (floor 2.7)
        _ = Debug.log "floor2" (floor -2.3)
    in
    text "done"
```

### FunctionBasic

**Expected:** `add1: 5`, `double1: 10`, `identity1: 42`

```elm
{-| Test basic function definitions.
-}

-- CHECK: add1: 5
-- CHECK: double1: 10
-- CHECK: identity1: 42


add a b = a + b
double x = x * 2
identity x = x


main =
    let
        _ = Debug.log "add1" (add 2 3)
        _ = Debug.log "double1" (double 5)
        _ = Debug.log "identity1" (identity 42)
    in
    text "done"
```

### FunctionMultiArg

**Expected:** `three: 6`, `four: 10`, `five: 15`

```elm
{-| Test functions with multiple arguments.
-}

-- CHECK: three: 6
-- CHECK: four: 10
-- CHECK: five: 15


addThree a b c = a + b + c
addFour a b c d = a + b + c + d
addFive a b c d e = a + b + c + d + e


main =
    let
        _ = Debug.log "three" (addThree 1 2 3)
        _ = Debug.log "four" (addFour 1 2 3 4)
        _ = Debug.log "five" (addFive 1 2 3 4 5)
    in
    text "done"
```

### Hello

**Expected:** `HelloTest: "hello"`

```elm
{-| Simple test that verifies basic Elm compilation and execution.
-}

-- CHECK: HelloTest: "hello"


main =
    let
        msg =
            "hello"

        _ =
            Debug.log "HelloTest" msg
    in
    text msg
```

### HeteroClosureBoxedUnboxed

**Expected:** `boxed_cap: 13`, `unboxed_cap: 10`

```elm
{-| Test heterogeneous closure ABI: boxed custom type (!eco.value) vs
unboxed Int (i64) captures chosen dynamically, then called.
-}

-- CHECK: boxed_cap: 13
-- CHECK: unboxed_cap: 10


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


main =
    let
        f =
            if True then
                shapeBonus Circle
            else
                addN 5

        _ = Debug.log "boxed_cap" (f 3)

        g =
            if False then
                shapeBonus Square
            else
                addN 7

        _ = Debug.log "unboxed_cap" (g 3)
    in
    text "done"
```

### HeteroClosureIntFloat

**Expected:** `hetero_true: 13`, `hetero_false: 10`

```elm
{-| Test heterogeneous closure ABI: Int (i64) vs Float (f64) captures
chosen dynamically, then called through the same call site.
-}

-- CHECK: hetero_true: 13
-- CHECK: hetero_false: 10


addN : Int -> Int -> Int
addN n x =
    n + x


mulF : Float -> Int -> Int
mulF f x =
    truncate (f * toFloat x)


main =
    let
        f =
            if True then
                addN 10
            else
                mulF 2.5

        _ = Debug.log "hetero_true" (f 3)

        g =
            if False then
                addN 10
            else
                mulF 2.5

        _ = Debug.log "hetero_false" (g 4)
    in
    text "done"
```

### HigherOrder

**Expected:** `apply1: 10`, `apply2: 25`, `twice1: 20`

```elm
{-| Test higher-order functions.
-}

-- CHECK: apply1: 10
-- CHECK: apply2: 25
-- CHECK: twice1: 20


apply f x = f x
twice f x = f (f x)
double x = x * 2
square x = x * x


main =
    let
        _ = Debug.log "apply1" (apply double 5)
        _ = Debug.log "apply2" (apply square 5)
        _ = Debug.log "twice1" (twice double 5)
    in
    text "done"
```

### HOParamApplyTwo

**Expected:** `result: 1`

```elm
{-| Test higher-order param: apply f a b with a two-arg lambda.
-}

-- CHECK: result: 1


main =
    let
        applyTwo f a b = f a b

        result = applyTwo (\x y -> x) 1 2
        _ = Debug.log "result" result
    in
    text "done"
```

### IndirectCallFloat

**Expected:** `apply_double: 10`, `apply_negate: -3`, `apply_addTen: 15`, `twice_double: 8`, `twice_addTen: 20`, `compose_result: 22`

```elm
{-| Test indirect calls (higher-order functions) with Float return types.
This exercises the f64 result conversion path in closure calls.
-}

-- CHECK: apply_double: 10
-- CHECK: apply_negate: -3
-- CHECK: apply_addTen: 15
-- CHECK: twice_double: 8
-- CHECK: twice_addTen: 20
-- CHECK: compose_result: 22


-- Higher-order function that applies a Float->Float function
applyFloat : (Float -> Float) -> Float -> Float
applyFloat f x =
    f x


-- Higher-order function that applies a Float->Float function twice
twiceFloat : (Float -> Float) -> Float -> Float
twiceFloat f x =
    f (f x)


-- Simple float operations to pass as closures
double : Float -> Float
double x =
    x * 2.0


negate : Float -> Float
negate x =
    0.0 - x


addTen : Float -> Float
addTen x =
    x + 10.0


main =
    let
        -- Test applyFloat with various float functions
        _ = Debug.log "apply_double" (applyFloat double 5.0)      -- 10.0
        _ = Debug.log "apply_negate" (applyFloat negate 3.0)      -- -3.0
        _ = Debug.log "apply_addTen" (applyFloat addTen 5.0)      -- 15.0

        -- Test twiceFloat (chained indirect calls)
        _ = Debug.log "twice_double" (twiceFloat double 2.0)      -- 8.0 (2 * 2 * 2)
        _ = Debug.log "twice_addTen" (twiceFloat addTen 0.0)      -- 20.0 (0 + 10 + 10)

        -- Test with composition
        doubleThenAddTen = double >> addTen
        _ = Debug.log "compose_result" (applyFloat doubleThenAddTen 6.0) -- 22.0 (6 * 2 + 10)
    in
    text "done"
```

### InlineVarCollision

**Expected:** `result: 84`

```elm
{-| Test for variable name shadowing after MonoInlineSimplify inlines a function
whose internal destructured variable name matches a variable in the enclosing scope.

This mirrors the bug in Compiler_Monomorphize_Specialize_specializePath:
  TOpt.Index index hint subPath ->
    let resultType = computeIndexProjectionType ... (Index.toMachine index) ...
    in  Mono.MonoIndex (Index.toMachine index) ...

Index.toMachine is: toMachine (ZeroBased index) = index
After inlining the first call, the destructured name "index" overwrites the
outer "index" variable mapping. When the second call tries to pass "index"
as its argument, it gets the i64 result instead of the !eco.value wrapper.
-}

-- CHECK: result: 84


type Wrapped
    = Wrapped Int


{-| Simple destructuring function whose internal binding name matches the
parameter name of the enclosing call site's variable. The destructured
name "n" will shadow the outer "n" after inlining.
-}
extract : Wrapped -> Int
extract (Wrapped n) =
    n


{-| Helper that takes an Int argument to force the first extract to be evaluated. -}
helper : Int -> Int -> Int
helper a b =
    a + b


{-| This function has a parameter named `n` and calls extract(n) twice.
After inlining extract, the internal destructured binding "n" (from
`Wrapped n`) overwrites the outer "n" mapping in varMappings.

Flow:
  1. `n` (outer, type Wrapped) -> mapped to %X (!eco.value)
  2. First `extract n` inlines: destructures `n` -> overrides mapping to %Y (i64)
  3. `helper (extract n) 0` evaluates fine with %Y
  4. Second `extract n`: argument `n` resolves to %Y (i64, WRONG!)
     Should resolve to %X (!eco.value)
-}
useTwice : Wrapped -> Int
useTwice n =
    helper (extract n) (extract n)


main =
    let
        w =
            Wrapped 42

        _ =
            Debug.log "result" (useTwice w)
    in
    text "done"
```

### IntAbs

**Expected:** `abs1: 5`, `abs2: 5`, `abs3: 0`

```elm
{-| Test integer absolute value.
-}

-- CHECK: abs1: 5
-- CHECK: abs2: 5
-- CHECK: abs3: 0


main =
    let
        _ = Debug.log "abs1" (abs 5)
        _ = Debug.log "abs2" (abs -5)
        _ = Debug.log "abs3" (abs 0)
    in
    text "done"
```

### IntAdd

**Expected:** `add1: 13`, `add2: 0`, `add3: -5`

```elm
{-| Test integer addition.
-}

-- CHECK: add1: 13
-- CHECK: add2: 0
-- CHECK: add3: -5


main =
    let
        _ = Debug.log "add1" (10 + 3)
        _ = Debug.log "add2" (5 + -5)
        _ = Debug.log "add3" (-2 + -3)
    in
    text "done"
```

### IntCompare

**Expected:** `lt: True`, `gt: True`, `le1: True`, `le2: True`, `ge1: True`, `ge2: True`, `eq: True`, `ne: True`

```elm
{-| Test integer comparisons.
-}

-- CHECK: lt: True
-- CHECK: gt: True
-- CHECK: le1: True
-- CHECK: le2: True
-- CHECK: ge1: True
-- CHECK: ge2: True
-- CHECK: eq: True
-- CHECK: ne: True


main =
    let
        _ = Debug.log "lt" (3 < 10)
        _ = Debug.log "gt" (10 > 3)
        _ = Debug.log "le1" (3 <= 10)
        _ = Debug.log "le2" (5 <= 5)
        _ = Debug.log "ge1" (10 >= 3)
        _ = Debug.log "ge2" (5 >= 5)
        _ = Debug.log "eq" (5 == 5)
        _ = Debug.log "ne" (5 /= 3)
    in
    text "done"
```

### IntDivByZero

**Expected:** `divZero1: 0`, `divZero2: 0`

```elm
{-| Test integer division by zero returns 0 (Elm semantics).
-}

-- CHECK: divZero1: 0
-- CHECK: divZero2: 0


main =
    let
        _ = Debug.log "divZero1" (10 // 0)
        _ = Debug.log "divZero2" (-5 // 0)
    in
    text "done"
```

### IntDiv

**Expected:** `div1: 3`, `div2: -3`, `div3: -3`, `div4: 3`

```elm
{-| Test integer division with truncation toward zero.
-}

-- CHECK: div1: 3
-- CHECK: div2: -3
-- CHECK: div3: -3
-- CHECK: div4: 3


main =
    let
        _ = Debug.log "div1" (10 // 3)
        _ = Debug.log "div2" (-10 // 3)
        _ = Debug.log "div3" (10 // -3)
        _ = Debug.log "div4" (-10 // -3)
    in
    text "done"
```

### IntMinMax

**Expected:** `min1: 3`, `min2: -5`, `max1: 10`, `max2: 5`

```elm
{-| Test min and max on integers.
-}

-- CHECK: min1: 3
-- CHECK: min2: -5
-- CHECK: max1: 10
-- CHECK: max2: 5


main =
    let
        _ = Debug.log "min1" (min 10 3)
        _ = Debug.log "min2" (min -5 5)
        _ = Debug.log "max1" (max 10 3)
        _ = Debug.log "max2" (max -5 5)
    in
    text "done"
```

### IntModBy

**Expected:** `mod1: 3`, `mod2: 1`, `mod3: 3`, `mod4: 1`, `mod5: 0`

```elm
{-| Test modBy with all sign combinations.
    modBy always returns a non-negative result (floored division).
-}

-- CHECK: mod1: 3
-- CHECK: mod2: 1
-- CHECK: mod3: 3
-- CHECK: mod4: 1
-- CHECK: mod5: 0


main =
    let
        _ = Debug.log "mod1" (modBy 4 7)
        _ = Debug.log "mod2" (modBy 4 -7)
        _ = Debug.log "mod3" (modBy 4 7)
        _ = Debug.log "mod4" (modBy 4 -7)
        _ = Debug.log "mod5" (modBy 5 0)
    in
    text "done"
```

### IntMul

**Expected:** `mul1: 30`, `mul2: -15`, `mul3: 6`, `mul4: 0`

```elm
{-| Test integer multiplication.
-}

-- CHECK: mul1: 30
-- CHECK: mul2: -15
-- CHECK: mul3: 6
-- CHECK: mul4: 0


main =
    let
        _ = Debug.log "mul1" (10 * 3)
        _ = Debug.log "mul2" (5 * -3)
        _ = Debug.log "mul3" (-2 * -3)
        _ = Debug.log "mul4" (0 * 100)
    in
    text "done"
```

### IntNegate

**Expected:** `neg1: -5`, `neg2: 5`, `neg3: 0`

```elm
{-| Test integer negation.
-}

-- CHECK: neg1: -5
-- CHECK: neg2: 5
-- CHECK: neg3: 0


main =
    let
        _ = Debug.log "neg1" (negate 5)
        _ = Debug.log "neg2" (negate -5)
        _ = Debug.log "neg3" (negate 0)
    in
    text "done"
```

### IntOverflow

**Expected:** `overflow`

```elm
{-| Test integer overflow behavior.
-}

-- CHECK: overflow


main =
    let
        big = 9223372036854775807
        _ = Debug.log "overflow" (big + 1)
    in
    text "done"
```

### IntPow

**Expected:** `pow1: 8`, `pow2: 1`, `pow3: 1024`, `pow4: -8`

```elm
{-| Test integer exponentiation.
-}

-- CHECK: pow1: 8
-- CHECK: pow2: 1
-- CHECK: pow3: 1024
-- CHECK: pow4: -8


main =
    let
        _ = Debug.log "pow1" (2 ^ 3)
        _ = Debug.log "pow2" (5 ^ 0)
        _ = Debug.log "pow3" (2 ^ 10)
        _ = Debug.log "pow4" ((-2) ^ 3)
    in
    text "done"
```

### IntRemainderBy

**Expected:** `rem1: 3`, `rem2: -3`, `rem3: 3`, `rem4: -3`

```elm
{-| Test remainderBy with all sign combinations.
    remainderBy preserves the sign of the dividend (truncated division).
-}

-- CHECK: rem1: 3
-- CHECK: rem2: -3
-- CHECK: rem3: 3
-- CHECK: rem4: -3


main =
    let
        _ = Debug.log "rem1" (remainderBy 4 7)
        _ = Debug.log "rem2" (remainderBy 4 -7)
        _ = Debug.log "rem3" (remainderBy -4 7)
        _ = Debug.log "rem4" (remainderBy -4 -7)
    in
    text "done"
```

### IntSub

**Expected:** `sub1: 7`, `sub2: 10`, `sub3: 1`

```elm
{-| Test integer subtraction.
-}

-- CHECK: sub1: 7
-- CHECK: sub2: 10
-- CHECK: sub3: 1


main =
    let
        _ = Debug.log "sub1" (10 - 3)
        _ = Debug.log "sub2" (5 - -5)
        _ = Debug.log "sub3" (-2 - -3)
    in
    text "done"
```

---

## E2E Tests: Lambda / Let / List / LocalTailRec

### LambdaCaseBoundary

**Expected:** `add: 7`, `sub: 3`, `mul: 20`, `nested_add: 11`, `nested_sub: 3`, `partial_add: 15`

```elm
{-| Test lambda boundary normalization for case expressions.

This tests that `\x -> case x of ... -> \a b -> expr` is correctly
optimized by pulling lambda parameters across the case boundary:
`\x a b -> case x of ... -> expr`

This reduces closure allocation by avoiding intermediate lambdas.
-}

-- CHECK: add: 7
-- CHECK: sub: 3
-- CHECK: mul: 20
-- CHECK: nested_add: 11
-- CHECK: nested_sub: 3
-- CHECK: partial_add: 15


type Op
    = Add
    | Sub
    | Mul


{-| Case returning binary lambda - should be normalized to take all args at once.
-}
getOp : Op -> Int -> Int -> Int
getOp op =
    case op of
        Add ->
            \a b -> a + b

        Sub ->
            \a b -> a - b

        Mul ->
            \a b -> a * b


{-| Nested case with lambda in inner branches.
-}
nestedCaseOp : Int -> Int -> Int -> Int
nestedCaseOp x =
    case x of
        0 ->
            \a b ->
                case a of
                    0 ->
                        b

                    _ ->
                        a + b

        _ ->
            \a b -> a - b


{-| Test partial application still works after normalization.
-}
applyPartial : (Int -> Int -> Int) -> Int -> Int
applyPartial f x =
    f x 10


main =
    let
        -- Test basic case-boundary normalization
        _ = Debug.log "add" (getOp Add 3 4)
        _ = Debug.log "sub" (getOp Sub 5 2)
        _ = Debug.log "mul" (getOp Mul 4 5)

        -- Test nested case with lambda
        _ = Debug.log "nested_add" (nestedCaseOp 0 1 10)
        _ = Debug.log "nested_sub" (nestedCaseOp 1 5 2)

        -- Test partial application
        addFive = getOp Add 5
        _ = Debug.log "partial_add" (addFive 10)
    in
    text "done"
```

### LambdaLetBoundary

**Expected:** `basic: 15`, `capturing: 19`, `multi_let: 20`, `nested: 42`, `partial: 25`

```elm
{-| Test lambda boundary normalization for let expressions.

This tests that `\a -> let y = expr1 in \z -> expr2` is correctly
optimized by pulling the inner lambda across the let boundary:
`\a z -> let y = expr1 in expr2`

This reduces staging boundaries and closure allocation.
-}

-- CHECK: basic: 15
-- CHECK: capturing: 19
-- CHECK: multi_let: 20
-- CHECK: nested: 42
-- CHECK: partial: 25


{-| Basic let-separated staging: \a -> let y = ... in \z -> y + z
After normalization: \a z -> let y = ... in y + z
-}
letSeparated : Int -> Int -> Int
letSeparated a =
    let
        y = a + 5
    in
    \z -> y + z


{-| Let capturing outer variable: \a -> let y = a * 2 in \z -> y + z + a
After normalization: \a z -> let y = a * 2 in y + z + a
-}
letCapturing : Int -> Int -> Int
letCapturing a =
    let
        y = a * 2
    in
    \z -> y + z + a


{-| Multiple let bindings before inner lambda.
-}
multiLet : Int -> Int -> Int
multiLet a =
    let
        x = a + 1
        y = x * 2
    in
    \z -> x + y + z


{-| Nested let expressions with lambdas.
-}
nestedLet : Int -> Int -> Int -> Int
nestedLet a =
    let
        x = a + 1
    in
    \b ->
        let
            y = b + x
        in
        \c -> x + y + c


main =
    let
        -- Basic let-separated staging
        _ = Debug.log "basic" (letSeparated 5 5)

        -- Let capturing outer variable
        _ = Debug.log "capturing" (letCapturing 3 10)

        -- Multiple let bindings
        _ = Debug.log "multi_let" (multiLet 4 5)

        -- Nested let expressions
        _ = Debug.log "nested" (nestedLet 10 15 5)

        -- Test partial application still works
        partial = letSeparated 10
        _ = Debug.log "partial" (partial 10)
    in
    text "done"
```

### LetBasic

**Expected:** `result1: 5`, `result2: "hello world"`

```elm
{-| Test basic let expressions.
-}

-- CHECK: result1: 5
-- CHECK: result2: "hello world"


main =
    let
        x = 2
        y = 3
        result1 = x + y

        greeting = "hello"
        name = "world"
        result2 = greeting ++ " " ++ name

        _ = Debug.log "result1" result1
        _ = Debug.log "result2" result2
    in
    text "done"
```

### LetBoundLambdaCall

**Expected:** `result: 1`

```elm
{-| Test let-bound lambda expression called with two args.
-}

-- CHECK: result: 1


main =
    let
        f = \x y -> x

        result = f 1 2
        _ = Debug.log "result" result
    in
    text "done"
```

### LetDestructuring

**Expected:** `first: 1`, `second: 2`, `head: 10`

```elm
{-| Test pattern destructuring in let.
-}

-- CHECK: first: 1
-- CHECK: second: 2
-- CHECK: head: 10


main =
    let
        (first, second) = (1, 2)
        (a, b, c) = (10, 20, 30)
        _ = Debug.log "first" first
        _ = Debug.log "second" second
        _ = Debug.log "head" a
    in
    text "done"
```

### LetMultiFunc

**Expected:** `r1: 1`, `r2: 2`

```elm
{-| Test let with multiple function definitions.
-}

-- CHECK: r1: 1
-- CHECK: r2: 2


main =
    let
        identity x = x
        const x y = x

        r1 = identity 1
        r2 = const 2 3
        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
```

### LetMultiple

**Expected:** `sum: 15`, `product: 120`

```elm
{-| Test let with multiple bindings.
-}

-- CHECK: sum: 15
-- CHECK: product: 120


main =
    let
        a = 1
        b = 2
        c = 3
        d = 4
        e = 5
        sum = a + b + c + d + e
        product = a * b * c * d * e
        _ = Debug.log "sum" sum
        _ = Debug.log "product" product
    in
    text "done"
```

### LetNested

**Expected:** `nested: 30`

```elm
{-| Test nested let expressions.
-}

-- CHECK: nested: 30


main =
    let
        outer =
            let
                inner = 10
            in
            inner * 3

        _ = Debug.log "nested" outer
    in
    text "done"
```

### LetRecClosure

**Expected:** `LetRecClosureTest: [1, 2, 3]`

```elm
{-| Test for local recursive closure in let-binding.
Reproduces the takeListItems pattern from Cheapskate/Parse.elm:
a local recursive function defined in a let block that captures
a variable from an outer scope and is used before its definition.
-}

-- CHECK: LetRecClosureTest: [1, 2, 3]


type Item
    = Num Int
    | Blank


main =
    let
        items =
            [ Num 1, Num 2, Num 3, Blank, Num 99 ]

        result =
            processItems 0 items

        _ =
            Debug.log "LetRecClosureTest" result
    in
    text "hello"


processItems : Int -> List Item -> List Int
processItems threshold items =
    case items of
        [] ->
            []

        (Num n) :: rest ->
            let
                collected =
                    takeMore rest

                takeMore : List Item -> List Int
                takeMore xs =
                    case xs of
                        (Num m) :: ys ->
                            if m > threshold then
                                m :: takeMore ys

                            else
                                []

                        _ ->
                            []
            in
            n :: collected

        Blank :: rest ->
            processItems threshold rest
```

### LetRecMultiArg

**Expected:** `result: 2`

```elm
{-| Test recursive let-bound function with multiple args.
-}

-- CHECK: result: 2


main =
    let
        f a b =
            if a <= 0 then b else f (a - 1) (b + 1)

        result = f 1 1
        _ = Debug.log "result" result
    in
    text "done"
```

### LetSeparatedStaging

**Expected:** `result: 18`

```elm
caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc n k =
    case n of
        0 -> \a -> let y = a + k in \z -> y + z
        _ -> \a z -> a + z

main =
    let
        _ = Debug.log "result" (caseFunc 0 10 5 3)
    in
    text "done"
```

### ListAnyBool

**Expected:** `any_id_true: True`, `any_id_false: False`, `any_not_true: True`, `any_not_false: False`, `all_id_true: True`, `all_id_false: False`

```elm
{-| Test List.any with List Bool — exercises papExtend with Bool (i1) elements.
-}

-- CHECK: any_id_true: True
-- CHECK: any_id_false: False
-- CHECK: any_not_true: True
-- CHECK: any_not_false: False
-- CHECK: all_id_true: True
-- CHECK: all_id_false: False


main =
    let
        _ = Debug.log "any_id_true" (List.any identity [False, True, False])
        _ = Debug.log "any_id_false" (List.any identity [False, False, False])
        _ = Debug.log "any_not_true" (List.any not [True, False])
        _ = Debug.log "any_not_false" (List.any not [True, True])
        _ = Debug.log "all_id_true" (List.all identity [True, True, True])
        _ = Debug.log "all_id_false" (List.all identity [True, False, True])
    in
    text "done"
```

### ListConcat

**Expected:** `append: [1, 2, 3, 4]`, `concat: [1, 2, 3, 4, 5, 6]`, `empty: [1, 2, 3]`

```elm
{-| Test List.concat and ++.
-}

-- CHECK: append: [1, 2, 3, 4]
-- CHECK: concat: [1, 2, 3, 4, 5, 6]
-- CHECK: empty: [1, 2, 3]


main =
    let
        _ = Debug.log "append" ([1, 2] ++ [3, 4])
        _ = Debug.log "concat" (List.concat [[1, 2], [3, 4], [5, 6]])
        _ = Debug.log "empty" ([] ++ [1, 2, 3])
    in
    text "done"
```

### ListCons

**Expected:** `cons1: [1]`, `cons2: [1, 2]`, `cons3: [1, 2, 3]`

```elm
{-| Test list cons operator.
-}

-- CHECK: cons1: [1]
-- CHECK: cons2: [1, 2]
-- CHECK: cons3: [1, 2, 3]


main =
    let
        _ = Debug.log "cons1" (1 :: [])
        _ = Debug.log "cons2" (1 :: 2 :: [])
        _ = Debug.log "cons3" (1 :: 2 :: 3 :: [])
    in
    text "done"
```

### ListEmpty

**Expected:** `empty: []`, `isEmpty: True`

```elm
{-| Test empty list.
-}

-- CHECK: empty: []
-- CHECK: isEmpty: True


main =
    let
        _ = Debug.log "empty" []
        _ = Debug.log "isEmpty" (List.isEmpty [])
    in
    text "done"
```

### ListFilter

**Expected:** `even: [2, 4]`, `positive: [1, 2, 3]`, `empty: []`

```elm
{-| Test List.filter.
-}

-- CHECK: even: [2, 4]
-- CHECK: positive: [1, 2, 3]
-- CHECK: empty: []


isEven x = modBy 2 x == 0
isPositive x = x > 0


main =
    let
        _ = Debug.log "even" (List.filter isEven [1, 2, 3, 4, 5])
        _ = Debug.log "positive" (List.filter isPositive [-1, 0, 1, 2, 3])
        _ = Debug.log "empty" (List.filter isEven [])
    in
    text "done"
```

### ListFoldl

**Expected:** `sum: 10`, `product: 24`, `concat: "cba"`

```elm
{-| Test List.foldl.
-}

-- CHECK: sum: 10
-- CHECK: product: 24
-- CHECK: concat: "cba"


main =
    let
        _ = Debug.log "sum" (List.foldl (+) 0 [1, 2, 3, 4])
        _ = Debug.log "product" (List.foldl (*) 1 [1, 2, 3, 4])
        _ = Debug.log "concat" (List.foldl (++) "" ["a", "b", "c"])
    in
    text "done"
```

### ListFoldr

**Expected:** `sum: 10`, `concat: "abc"`

```elm
{-| Test List.foldr.
-}

-- CHECK: sum: 10
-- CHECK: concat: "abc"


main =
    let
        _ = Debug.log "sum" (List.foldr (+) 0 [1, 2, 3, 4])
        _ = Debug.log "concat" (List.foldr (++) "" ["a", "b", "c"])
    in
    text "done"
```

### ListHeadTail

**Expected:** `head1: Just 1`, `head2: Nothing`, `tail1: Just [2, 3]`, `tail2: Nothing`

```elm
{-| Test List.head and List.tail.
-}

-- CHECK: head1: Just 1
-- CHECK: head2: Nothing
-- CHECK: tail1: Just [2, 3]
-- CHECK: tail2: Nothing


main =
    let
        _ = Debug.log "head1" (List.head [1, 2, 3])
        _ = Debug.log "head2" (List.head [])
        _ = Debug.log "tail1" (List.tail [1, 2, 3])
        _ = Debug.log "tail2" (List.tail [])
    in
    text "done"
```

### ListLength

**Expected:** `len1: 0`, `len2: 3`, `len3: 5`

```elm
{-| Test List.length.
-}

-- CHECK: len1: 0
-- CHECK: len2: 3
-- CHECK: len3: 5


main =
    let
        _ = Debug.log "len1" (List.length [])
        _ = Debug.log "len2" (List.length [1, 2, 3])
        _ = Debug.log "len3" (List.length [1, 2, 3, 4, 5])
    in
    text "done"
```

### ListLiteral

**Expected:** `list1: [1]`, `list2: [1, 2, 3]`, `list3: [10, 20, 30, 40, 50]`

```elm
{-| Test list literal syntax.
-}

-- CHECK: list1: [1]
-- CHECK: list2: [1, 2, 3]
-- CHECK: list3: [10, 20, 30, 40, 50]


main =
    let
        _ = Debug.log "list1" [1]
        _ = Debug.log "list2" [1, 2, 3]
        _ = Debug.log "list3" [10, 20, 30, 40, 50]
    in
    text "done"
```

### ListMapBool

**Expected:** `map_not: [False, True, False]`, `map_id: [True, False, True]`

```elm
{-| Test List.map producing Bool results — exercises list head projection with Bool.
-}

-- CHECK: map_not: [False, True, False]
-- CHECK: map_id: [True, False, True]


main =
    let
        _ = Debug.log "map_not" (List.map not [True, False, True])
        _ = Debug.log "map_id" (List.map identity [True, False, True])
    in
    text "done"
```

### ListMap

**Expected:** `map1: [2, 4, 6]`, `map2: []`, `map3: [1, 4, 9]`

```elm
{-| Test List.map.
-}

-- CHECK: map1: [2, 4, 6]
-- CHECK: map2: []
-- CHECK: map3: [1, 4, 9]


double x = x * 2
square x = x * x


main =
    let
        _ = Debug.log "map1" (List.map double [1, 2, 3])
        _ = Debug.log "map2" (List.map double [])
        _ = Debug.log "map3" (List.map square [1, 2, 3])
    in
    text "done"
```

### ListReverse

**Expected:** `rev1: []`, `rev2: [3, 2, 1]`, `rev3: [5, 4, 3, 2, 1]`

```elm
{-| Test List.reverse.
-}

-- CHECK: rev1: []
-- CHECK: rev2: [3, 2, 1]
-- CHECK: rev3: [5, 4, 3, 2, 1]


main =
    let
        _ = Debug.log "rev1" (List.reverse [])
        _ = Debug.log "rev2" (List.reverse [1, 2, 3])
        _ = Debug.log "rev3" (List.reverse [1, 2, 3, 4, 5])
    in
    text "done"
```

### ListTakeDrop

**Expected:** `take1: [1, 2]`, `take2: []`, `drop1: [3, 4, 5]`, `drop2: [1, 2, 3, 4, 5]`

```elm
{-| Test List.take and List.drop.
-}

-- CHECK: take1: [1, 2]
-- CHECK: take2: []
-- CHECK: drop1: [3, 4, 5]
-- CHECK: drop2: [1, 2, 3, 4, 5]


main =
    let
        _ = Debug.log "take1" (List.take 2 [1, 2, 3, 4, 5])
        _ = Debug.log "take2" (List.take 0 [1, 2, 3])
        _ = Debug.log "drop1" (List.drop 2 [1, 2, 3, 4, 5])
        _ = Debug.log "drop2" (List.drop 0 [1, 2, 3, 4, 5])
    in
    text "done"
```

### LocalTailRecSimple

**Expected:** `result: 55`

```elm
{-| Test a simple local tail-recursive function (MonoTailDef in a let binding).
-}

-- CHECK: result: 55


main =
    let
        sumUpTo : Int -> Int -> Int
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)

        result = sumUpTo 10 0
        _ = Debug.log "result" result
    in
    text "done"
```

---

## E2E Tests: Maybe / MutualRecursion / PapExtend / PapSaturate / PartialApp / Pipeline / Poly

### MaybeAndThen

**Expected:**
```
andThen1: Just 21
andThen2: Nothing
andThen3: Nothing
```

```elm
half x =
    if modBy 2 x == 0 then
        Just (x // 2)
    else
        Nothing


main =
    let
        _ = Debug.log "andThen1" (Maybe.andThen half (Just 42))
        _ = Debug.log "andThen2" (Maybe.andThen half (Just 41))
        _ = Debug.log "andThen3" (Maybe.andThen half Nothing)
    in
    text "done"
```

### MaybeJust

**Expected:**
```
just1: Just 42
just2: Just "hello"
just3: Just True
```

```elm
main =
    let
        _ = Debug.log "just1" (Just 42)
        _ = Debug.log "just2" (Just "hello")
        _ = Debug.log "just3" (Just True)
    in
    text "done"
```

### MaybeMap

**Expected:**
```
map1: Just 84
map2: Nothing
```

```elm
main =
    let
        _ = Debug.log "map1" (Maybe.map (\x -> x * 2) (Just 42))
        _ = Debug.log "map2" (Maybe.map (\x -> x * 2) Nothing)
    in
    text "done"
```

### MaybeNothing

**Expected:**
```
nothing: Nothing
```

```elm
main =
    let
        _ = Debug.log "nothing" Nothing
    in
    text "done"
```

### MaybePatternMatch

**Expected:**
```
match1: 42
match2: 0
```

```elm
unwrap maybe =
    case maybe of
        Just x -> x
        Nothing -> 0


main =
    let
        _ = Debug.log "match1" (unwrap (Just 42))
        _ = Debug.log "match2" (unwrap Nothing)
    in
    text "done"
```

### MaybeWithDefault

**Expected:**
```
withDefault1: 42
withDefault2: 0
```

```elm
main =
    let
        _ = Debug.log "withDefault1" (Maybe.withDefault 0 (Just 42))
        _ = Debug.log "withDefault2" (Maybe.withDefault 0 Nothing)
    in
    text "done"
```

### MutualRecursion

**Expected:**
```
isEven0: True
isEven5: False
isOdd5: True
```

```elm
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


main =
    let
        _ = Debug.log "isEven0" (isEven 0)
        _ = Debug.log "isEven5" (isEven 5)
        _ = Debug.log "isOdd5" (isOdd 5)
    in
    text "done"
```

### PapExtendArity

**Expected:**
```
result1: 7
result2: 10
result3: 30
```

```elm
{-| A function defined with explicit return lambda.
This creates a multi-stage type: MFunction [Int] (MFunction [Int] Int)
with stage arities [1, 1], NOT a single-stage MFunction [Int, Int] Int.
-}
curried : Int -> Int -> Int
curried x =
    \y -> x + y


{-| Takes a (multi-stage) function parameter and partially applies it.
Inside the closure body, `f` is a closure parameter NOT tracked in varSourceArity.
When calling `f a`, sourceArityForCallee falls back to countTotalArityFromType
which returns 2 (total) instead of 1 (first stage source arity).
-}
applyPartial : (Int -> Int -> Int) -> Int -> (Int -> Int)
applyPartial f a =
    f a


{-| A function that takes a binary function, wraps it in a 3-arg lambda
(like Basics.Extra.flip), and applies it. This matches sub-pattern A.
-}
flip : (a -> b -> c) -> b -> a -> c
flip f b a =
    f a b


{-| Another multi-stage function for the flip pattern. -}
sub : Int -> Int -> Int
sub x =
    \y -> x - y


main =
    let
        -- Pattern 1: Partial application of multi-stage function through higher-order
        add3 = applyPartial curried 3
        result1 = add3 4
        _ = Debug.log "result1" result1

        -- Pattern 2: Flip applied to a multi-stage function
        result2 = flip curried 4 6
        _ = Debug.log "result2" result2

        -- Pattern 3: Chain of partial applications through closures
        multiply : Int -> Int -> Int
        multiply x =
            \y -> x * y

        applyBoth : (Int -> Int -> Int) -> Int -> Int -> Int
        applyBoth f x y =
            f x y

        result3 = applyBoth multiply 5 6
        _ = Debug.log "result3" result3
    in
    text "done"
```

### PapSaturatePolyPipeMinimal

**Expected:**
```
result: 42
```

```elm
{-| Polymorphic function using pipe with Maybe.withDefault.
When monomorphized with a = Int, the pipe's intermediate result type
should be i64 but remains !eco.value due to the inlining bug.
-}
polyWithDefault : a -> Maybe a -> a
polyWithDefault default mx =
    mx |> Maybe.withDefault default


main =
    let
        result = polyWithDefault 0 (Just 42)
        _ = Debug.log "result" result
    in
    text (String.fromInt result)
```

### PartialAppChain

**Expected:**
```
chain1: 10
chain2: 6
```

```elm
addThree a b c = a + b + c


main =
    let
        addTo3 = addThree 3
        addTo3And4 = addTo3 4
        _ = Debug.log "chain1" (addTo3And4 3)
        _ = Debug.log "chain2" (addThree 1 2 3)
    in
    text "done"
```

### PartialApplication

**Expected:**
```
partial1: 7
partial2: 15
partial3: [2, 3, 4]
```

```elm
add a b = a + b
multiply a b = a * b


main =
    let
        add5 = add 5
        triple = multiply 3
        addOne = add 1
        _ = Debug.log "partial1" (add5 2)
        _ = Debug.log "partial2" (triple 5)
        _ = Debug.log "partial3" (List.map addOne [1, 2, 3])
    in
    text "done"
```

### Pipeline

**Expected:**
```
pipe1: 12
pipe2: [2, 4, 6]
backpipe: 10
```

```elm
double x = x * 2
addOne x = x + 1


main =
    let
        _ = Debug.log "pipe1" (5 |> double |> addOne |> addOne)
        _ = Debug.log "pipe2" ([1, 2, 3] |> List.map double)
        _ = Debug.log "backpipe" (double <| addOne <| 4)
    in
    text "done"
```

### PolyApplyLambda

**Expected:**
```
applyIntId: 1
applyStrId: "hi"
applyLambda: 42
```

```elm
apply f x = f x


intId n = n


strId s = s


main =
    let
        _ = Debug.log "applyIntId" (apply intId 1)
        _ = Debug.log "applyStrId" (apply strId "hi")
        _ = Debug.log "applyLambda" (apply (\n -> n) 42)
    in
    text "done"
```

### PolyLetConst

**Expected:**
```
r1: 1
r2: "hi"
```

```elm
main =
    let
        const a b = a

        r1 = const 1 "hi"
        r2 = const "hi" 1
        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
```

---

## E2E Tests: Record / Recursive / Result / Round / SingleCtorPair

### RecordAccessorFunction

**Expected:**
```
names: ["Alice", "Bob"]
xs: [1, 4]
```

```elm
{-| Test .field as a function.
-}

-- CHECK: names: ["Alice", "Bob"]
-- CHECK: xs: [1, 4]


main =
    let
        people = [ { name = "Alice", age = 30 }, { name = "Bob", age = 25 } ]
        points = [ { x = 1, y = 2 }, { x = 4, y = 5 } ]
        _ = Debug.log "names" (List.map .name people)
        _ = Debug.log "xs" (List.map .x points)
    in
    text "done"
```

### RecordAccess

**Expected:**
```
x: 1
y: 2
name: "Alice"
```

```elm
{-| Test record field access.
-}

-- CHECK: x: 1
-- CHECK: y: 2
-- CHECK: name: "Alice"


main =
    let
        point = { x = 1, y = 2 }
        person = { name = "Alice", age = 30 }
        _ = Debug.log "x" point.x
        _ = Debug.log "y" point.y
        _ = Debug.log "name" person.name
    in
    text "done"
```

### RecordCreate

**Expected:**
```
record1: { x = 1, y = 2 }
record2: { age = 30, name = "Alice" }
```

```elm
{-| Test record creation.
-}

-- CHECK: record1: { x = 1, y = 2 }
-- CHECK: record2: { age = 30, name = "Alice" }


main =
    let
        _ = Debug.log "record1" { x = 1, y = 2 }
        _ = Debug.log "record2" { name = "Alice", age = 30 }
    in
    text "done"
```

### RecordUpdate

**Expected:**
```
updated: { x = 10, y = 2 }
original: { x = 1, y = 2 }
```

```elm
{-| Test record update syntax.
-}

-- CHECK: updated: { x = 10, y = 2 }
-- CHECK: original: { x = 1, y = 2 }


main =
    let
        original = { x = 1, y = 2 }
        updated = { original | x = 10 }
        _ = Debug.log "updated" updated
        _ = Debug.log "original" original
    in
    text "done"
```

### RecursiveFactorial

**Expected:**
```
fact0: 1
fact5: 120
fact10: 3628800
```

```elm
{-| Test simple recursion with factorial.
-}

-- CHECK: fact0: 1
-- CHECK: fact5: 120
-- CHECK: fact10: 3628800


factorial n =
    if n <= 1 then
        1
    else
        n * factorial (n - 1)


main =
    let
        _ = Debug.log "fact0" (factorial 0)
        _ = Debug.log "fact5" (factorial 5)
        _ = Debug.log "fact10" (factorial 10)
    in
    text "done"
```

### RecursiveFibonacci

**Expected:**
```
fib0: 0
fib1: 1
fib10: 55
```

```elm
{-| Test recursion with multiple recursive calls.
-}

-- CHECK: fib0: 0
-- CHECK: fib1: 1
-- CHECK: fib10: 55


fib n =
    if n <= 0 then
        0
    else if n == 1 then
        1
    else
        fib (n - 1) + fib (n - 2)


main =
    let
        _ = Debug.log "fib0" (fib 0)
        _ = Debug.log "fib1" (fib 1)
        _ = Debug.log "fib10" (fib 10)
    in
    text "done"
```

### RecursiveListLength

**Expected:**
```
len0: 0
len3: 3
len5: 5
```

```elm
{-| Test recursive list traversal.
-}

-- CHECK: len0: 0
-- CHECK: len3: 3
-- CHECK: len5: 5


myLength list =
    case list of
        [] -> 0
        _ :: rest -> 1 + myLength rest


main =
    let
        _ = Debug.log "len0" (myLength [])
        _ = Debug.log "len3" (myLength [1, 2, 3])
        _ = Debug.log "len5" (myLength [1, 2, 3, 4, 5])
    in
    text "done"
```

### ResultAndThen

**Expected:**
```
andThen1: Ok 21
andThen2: Err "odd"
andThen3: Err "original"
```

```elm
{-| Test Result.andThen.
-}

-- CHECK: andThen1: Ok 21
-- CHECK: andThen2: Err "odd"
-- CHECK: andThen3: Err "original"


half x =
    if modBy 2 x == 0 then
        Ok (x // 2)
    else
        Err "odd"


main =
    let
        _ = Debug.log "andThen1" (Result.andThen half (Ok 42))
        _ = Debug.log "andThen2" (Result.andThen half (Ok 41))
        _ = Debug.log "andThen3" (Result.andThen half (Err "original"))
    in
    text "done"
```

### ResultErr

**Expected:**
```
err1: Err "failed"
err2: Err 404
```

```elm
{-| Test Err creation.
-}

-- CHECK: err1: Err "failed"
-- CHECK: err2: Err 404


main =
    let
        _ = Debug.log "err1" (Err "failed")
        _ = Debug.log "err2" (Err 404)
    in
    text "done"
```

### ResultMap

**Expected:**
```
map1: Ok 84
map2: Err "error"
```

```elm
{-| Test Result.map.
-}

-- CHECK: map1: Ok 84
-- CHECK: map2: Err "error"


main =
    let
        _ = Debug.log "map1" (Result.map (\x -> x * 2) (Ok 42))
        _ = Debug.log "map2" (Result.map (\x -> x * 2) (Err "error"))
    in
    text "done"
```

### ResultOk

**Expected:**
```
ok1: Ok 42
ok2: Ok "success"
```

```elm
{-| Test Ok creation.
-}

-- CHECK: ok1: Ok 42
-- CHECK: ok2: Ok "success"


main =
    let
        _ = Debug.log "ok1" (Ok 42)
        _ = Debug.log "ok2" (Ok "success")
    in
    text "done"
```

### ResultWithDefault

**Expected:**
```
withDefault1: 42
withDefault2: 0
```

```elm
{-| Test Result.withDefault.
-}

-- CHECK: withDefault1: 42
-- CHECK: withDefault2: 0


main =
    let
        _ = Debug.log "withDefault1" (Result.withDefault 0 (Ok 42))
        _ = Debug.log "withDefault2" (Result.withDefault 0 (Err "error"))
    in
    text "done"
```

### RoundToInt

**Expected:**
```
round1: 3
round2: 2
round3: -3
```

```elm
{-| Test round for Float to Int conversion.
-}

-- CHECK: round1: 3
-- CHECK: round2: 2
-- CHECK: round3: -3


main =
    let
        _ = Debug.log "round1" (round 2.7)
        _ = Debug.log "round2" (round 2.3)
        _ = Debug.log "round3" (round -2.7)
    in
    text "done"
```

### SingleCtorPairBoolChar

**Expected:**
```
match_true: "yes"
match_false: "no"
unwrap_char: 'x'
```

```elm
{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapChar (Char, i16 unboxed).
Tests that case-matching on WrapBool doesn't use WrapChar's unboxed i16 layout.
-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: unwrap_char: 'x'


type WrapBool
    = WrapBool Bool


type WrapChar
    = WrapChar Char


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'x'))
    in
    text "done"
```

### SingleCtorPairBoolFloat

**Expected:**
```
match_true: "yes"
match_false: "no"
unwrap_float: 3.14
```

```elm
{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapFloat (Float, f64 unboxed).
Tests that case-matching on WrapBool doesn't use WrapFloat's unboxed f64 layout.
-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: unwrap_float: 3.14


type WrapBool
    = WrapBool Bool


type WrapFloat
    = WrapFloat Float


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 3.14))
    in
    text "done"
```

### SingleCtorPairBoolIntBidi

**Expected:**
```
match_true: "yes"
match_false: "no"
match_pos: "positive"
match_neg: "non-positive"
extract_bool: True
extract_int: 42
```

```elm
{-| Two single-constructor types: WrapBool (Bool, boxed) and WrapInt (Int, i64 unboxed).
Tests BOTH directions: matching on WrapBool (should not use i64 layout from WrapInt)
AND matching on WrapInt (should not use boxed layout from WrapBool).
-}

-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: match_pos: "positive"
-- CHECK: match_neg: "non-positive"
-- CHECK: extract_bool: True
-- CHECK: extract_int: 42


type WrapBool
    = WrapBool Bool


type WrapInt
    = WrapInt Int


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


matchInt : Int -> String
matchInt n =
    let
        w =
            WrapInt n
    in
    case w of
        WrapInt x ->
            if x > 0 then
                "positive"

            else
                "non-positive"


extractBool : WrapBool -> Bool
extractBool w =
    case w of
        WrapBool b ->
            b


extractInt : WrapInt -> Int
extractInt w =
    case w of
        WrapInt n ->
            n


main =
    let
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "match_pos" (matchInt 7)
        _ = Debug.log "match_neg" (matchInt -3)
        _ = Debug.log "extract_bool" (extractBool (WrapBool True))
        _ = Debug.log "extract_int" (extractInt (WrapInt 42))
    in
    text "done"
```

### SingleCtorPairCharFloat

**Expected:**
```
unwrap_char: 'Z'
unwrap_float: 1.5
match_char: "got_Z"
```

```elm
{-| Two single-constructor types: WrapChar (Char, i16 unboxed) and WrapFloat (Float, f64 unboxed).
Both have unboxed fields but completely different types (i16 vs f64).
findSingleCtorUnboxedField could return the wrong type entirely.
-}

-- CHECK: unwrap_char: 'Z'
-- CHECK: unwrap_float: 1.5
-- CHECK: match_char: "got_Z"


type WrapChar
    = WrapChar Char


type WrapFloat
    = WrapFloat Float


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


matchChar : Char -> String
matchChar c =
    let
        w =
            WrapChar c
    in
    case w of
        WrapChar x ->
            "got_" ++ String.fromChar x


main =
    let
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'Z'))
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 1.5))
        _ = Debug.log "match_char" (matchChar 'Z')
    in
    text "done"
```

### SingleCtorPairCharInt

**Expected:**
```
unwrap_char: 'A'
unwrap_int: 256
match_char: "got_A"
```

```elm
{-| Two single-constructor types: WrapChar (Char, i16 unboxed) and WrapInt (Int, i64 unboxed).
Both have unboxed fields but different widths (i16 vs i64).
findSingleCtorUnboxedField could return the wrong width, causing truncation or garbage.
-}

-- CHECK: unwrap_char: 'A'
-- CHECK: unwrap_int: 256
-- CHECK: match_char: "got_A"


type WrapChar
    = WrapChar Char


type WrapInt
    = WrapInt Int


unwrapChar : WrapChar -> Char
unwrapChar w =
    case w of
        WrapChar c ->
            c


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchChar : Char -> String
matchChar c =
    let
        w =
            WrapChar c
    in
    case w of
        WrapChar x ->
            "got_" ++ String.fromChar x


main =
    let
        _ = Debug.log "unwrap_char" (unwrapChar (WrapChar 'A'))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 256))
        _ = Debug.log "match_char" (matchChar 'A')
    in
    text "done"
```

### SingleCtorPairFloatBool

**Expected:**
```
unwrap_float: 9.81
match_true: "yes"
match_false: "no"
match_float: "big"
```

```elm
{-| Two single-constructor types: WrapFloat (Float, f64 unboxed) and WrapBool (Bool, boxed).
Tests that case-matching on WrapFloat doesn't use WrapBool's boxed layout,
and that WrapBool matching doesn't use WrapFloat's unboxed f64 layout.
-}

-- CHECK: unwrap_float: 9.81
-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"
-- CHECK: match_float: "big"


type WrapFloat
    = WrapFloat Float


type WrapBool
    = WrapBool Bool


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


matchFloat : Float -> String
matchFloat f =
    let
        w =
            WrapFloat f
    in
    case w of
        WrapFloat x ->
            if x > 5.0 then
                "big"

            else
                "small"


main =
    let
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 9.81))
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
        _ = Debug.log "match_float" (matchFloat 100.0)
    in
    text "done"
```

### SingleCtorPairIntFloat

**Expected:**
```
unwrap_int: 42
unwrap_float: 2.718
match_int_pos: "positive"
match_float_big: "big"
```

```elm
{-| Two single-constructor types: WrapInt (Int, i64 unboxed) and WrapFloat (Float, f64 unboxed).
Both have unboxed fields but different types. findSingleCtorUnboxedField could return
the wrong one, causing silent bit-reinterpretation bugs.
-}

-- CHECK: unwrap_int: 42
-- CHECK: unwrap_float: 2.718
-- CHECK: match_int_pos: "positive"
-- CHECK: match_float_big: "big"


type WrapInt
    = WrapInt Int


type WrapFloat
    = WrapFloat Float


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


unwrapFloat : WrapFloat -> Float
unwrapFloat w =
    case w of
        WrapFloat f ->
            f


matchInt : Int -> String
matchInt n =
    let
        w =
            WrapInt n
    in
    case w of
        WrapInt x ->
            if x > 0 then
                "positive"

            else
                "non-positive"


matchFloat : Float -> String
matchFloat f =
    let
        w =
            WrapFloat f
    in
    case w of
        WrapFloat x ->
            if x > 100.0 then
                "big"

            else
                "small"


main =
    let
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 42))
        _ = Debug.log "unwrap_float" (unwrapFloat (WrapFloat 2.718))
        _ = Debug.log "match_int_pos" (matchInt 7)
        _ = Debug.log "match_float_big" (matchFloat 999.9)
    in
    text "done"
```

### SingleCtorPairStringBool

**Expected:**
```
unwrap_str: "world"
match_true: "yes"
match_false: "no"
```

```elm
{-| Two single-constructor types: WrapString (String, boxed) and WrapBool (Bool, boxed).
Both fields are boxed, so findSingleCtorUnboxedField should return Nothing.
Tests the fallthrough path works correctly when no unboxed fields exist.
-}

-- CHECK: unwrap_str: "world"
-- CHECK: match_true: "yes"
-- CHECK: match_false: "no"


type WrapString
    = WrapString String


type WrapBool
    = WrapBool Bool


unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s ->
            s


matchBool : Bool -> String
matchBool b =
    let
        w =
            WrapBool b
    in
    case w of
        WrapBool True ->
            "yes"

        WrapBool False ->
            "no"


main =
    let
        _ = Debug.log "unwrap_str" (unwrapString (WrapString "world"))
        _ = Debug.log "match_true" (matchBool True)
        _ = Debug.log "match_false" (matchBool False)
    in
    text "done"
```

### SingleCtorPairStringInt

**Expected:**
```
unwrap_str: "hello"
unwrap_int: 99
match_str: "found_hello"
```

```elm
{-| Two single-constructor types: WrapString (String, boxed) and WrapInt (Int, i64 unboxed).
Tests that case-matching on WrapString doesn't use WrapInt's unboxed i64 layout.
-}

-- CHECK: unwrap_str: "hello"
-- CHECK: unwrap_int: 99
-- CHECK: match_str: "found_hello"


type WrapString
    = WrapString String


type WrapInt
    = WrapInt Int


unwrapString : WrapString -> String
unwrapString w =
    case w of
        WrapString s ->
            s


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchString : String -> String
matchString s =
    let
        w =
            WrapString s
    in
    case w of
        WrapString x ->
            "found_" ++ x


main =
    let
        _ = Debug.log "unwrap_str" (unwrapString (WrapString "hello"))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 99))
        _ = Debug.log "match_str" (matchString "hello")
    in
    text "done"
```

### SingleCtorPairUnitInt

**Expected:**
```
unwrap_unit: ()
unwrap_int: 77
match_unit: "got_unit"
```

```elm
{-| Two single-constructor types: WrapUnit ((), boxed/constant) and WrapInt (Int, i64 unboxed).
Tests that case-matching on WrapUnit doesn't use WrapInt's unboxed layout.
-}

-- CHECK: unwrap_unit: ()
-- CHECK: unwrap_int: 77
-- CHECK: match_unit: "got_unit"


type WrapUnit
    = WrapUnit ()


type WrapInt
    = WrapInt Int


unwrapUnit : WrapUnit -> ()
unwrapUnit w =
    case w of
        WrapUnit u ->
            u


unwrapInt : WrapInt -> Int
unwrapInt w =
    case w of
        WrapInt n ->
            n


matchUnit : () -> String
matchUnit u =
    let
        w =
            WrapUnit u
    in
    case w of
        WrapUnit _ ->
            "got_unit"


main =
    let
        _ = Debug.log "unwrap_unit" (unwrapUnit (WrapUnit ()))
        _ = Debug.log "unwrap_int" (unwrapInt (WrapInt 77))
        _ = Debug.log "match_unit" (matchUnit ())
    in
    text "done"
```

---

## E2E Tests: String / TailRec / Timer / ToFloat / Truncate / Tuple

### StringConcat

**Expected:**
```
concat1: "HelloWorld"
concat2: "Hello World"
append: "foobar"
```

```elm
{-| Test string concatenation.
-}

-- CHECK: concat1: "HelloWorld"
-- CHECK: concat2: "Hello World"
-- CHECK: append: "foobar"


main =
    let
        _ = Debug.log "concat1" ("Hello" ++ "World")
        _ = Debug.log "concat2" ("Hello" ++ " " ++ "World")
        _ = Debug.log "append" (String.append "foo" "bar")
    in
    text "done"
```

### StringEmpty

**Expected:**
```
empty: ""
isEmpty: True
```

```elm
{-| Test empty string.
-}

-- CHECK: empty: ""
-- CHECK: isEmpty: True


main =
    let
        _ = Debug.log "empty" ""
        _ = Debug.log "isEmpty" (String.isEmpty "")
    in
    text "done"
```

### StringEscapeSingleQuote

**Expected:**
```
q1: "it's working"
q2: "don't panic"
q3: "quotes: ' and '"
```

```elm
{-| Test that strings containing single quotes (apostrophes) compile correctly.
The MLIR string literal emitter must not produce \' escapes, since MLIR
only recognizes \\, \", \n, \t, and hex escapes inside double-quoted strings.
-}

-- CHECK: q1: "it's working"
-- CHECK: q2: "don't panic"
-- CHECK: q3: "quotes: ' and '"


main =
    let
        _ = Debug.log "q1" "it's working"
        _ = Debug.log "q2" "don't panic"
        _ = Debug.log "q3" ("quotes: ' and '")
    in
    text "done"
```

### StringEscapes

**Expected:**
```
newline
tab
quote: "\""
```

```elm
{-| Test string escape sequences.
-}

-- CHECK: newline
-- CHECK: tab
-- CHECK: quote: "\""


main =
    let
        _ = Debug.log "newline" "line1\nline2"
        _ = Debug.log "tab" "col1\tcol2"
        _ = Debug.log "quote" "\""
    in
    text "done"
```

### StringLength

**Expected:**
```
len1: 5
len2: 0
len3: 13
```

```elm
{-| Test String.length.
-}

-- CHECK: len1: 5
-- CHECK: len2: 0
-- CHECK: len3: 13


main =
    let
        _ = Debug.log "len1" (String.length "Hello")
        _ = Debug.log "len2" (String.length "")
        _ = Debug.log "len3" (String.length "Hello, World!")
    in
    text "done"
```

### StringLiteral

**Expected:**
```
str1: "Hello"
str2: "Hello, World!"
str3: "abc123"
```

```elm
{-| Test basic string literals.
-}

-- CHECK: str1: "Hello"
-- CHECK: str2: "Hello, World!"
-- CHECK: str3: "abc123"


main =
    let
        _ = Debug.log "str1" "Hello"
        _ = Debug.log "str2" "Hello, World!"
        _ = Debug.log "str3" "abc123"
    in
    text "done"
```

### StringUnicode

**Expected:**
```
greek
emoji
chinese
```

```elm
{-| Test Unicode in strings.
-}

-- CHECK: greek
-- CHECK: emoji
-- CHECK: chinese


main =
    let
        _ = Debug.log "greek" "alpha beta gamma"
        _ = Debug.log "emoji" "hello"
        _ = Debug.log "chinese" "hello"
    in
    text "done"
```

### TailRecBoolCarry

**Expected:**
```
result1: 10
result2: 0
result3: 42
```

```elm
{-| Test tail-recursive function that carries a Bool through the loop.

This exercises the bug where compileTailCallStep yields i1 (SSA type for Bool)
in a position where the scf.while carry type expects !eco.value (ABI type for Bool).

The pattern:
  - Tail-recursive function with a Bool parameter (becomes !eco.value carry type)
  - Case expression inside the loop body (becomes eco.case inside scf.while)
  - Tail call passes a Bool value (Expr.generateExpr produces i1, but carry expects !eco.value)
-}

-- CHECK: result1: 10
-- CHECK: result2: 0
-- CHECK: result3: 42


{-| A tail-recursive function with a Bool parameter.
The Bool `found` is carried through the while-loop as !eco.value (ABI type),
but inside the case branch, the tail call yields it as i1 (SSA type).
-}
searchList : Bool -> Int -> List Int -> Int
searchList found acc list =
    case list of
        [] ->
            if found then
                acc
            else
                0

        x :: xs ->
            if x > 5 then
                searchList True (acc + x) xs
            else
                searchList found acc xs


main =
    let
        _ = Debug.log "result1" (searchList False 0 [1, 2, 3, 10])
        _ = Debug.log "result2" (searchList False 0 [1, 2, 3])
        _ = Debug.log "result3" (searchList False 0 [1, 42])
    in
    text "done"
```

### TailRecCaseDestruct

**Expected:**
```
foldl: 15
sum: 10
count: 3
```

```elm
{-| Test tail-recursive function with case expression and
pattern destructuring in branches containing tail calls.
Exercises TailRec.compileCaseStep + compileDestructStep.
-}

-- CHECK: foldl: 15
-- CHECK: sum: 10
-- CHECK: count: 3


myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl func acc list =
    case list of
        [] ->
            acc

        x :: xs ->
            myFoldl func (func x acc) xs


mySum : List Int -> Int
mySum list =
    myFoldl (+) 0 list


myCountHelper : Int -> List a -> Int
myCountHelper acc list =
    case list of
        [] ->
            acc

        _ :: rest ->
            myCountHelper (acc + 1) rest


main =
    let
        _ = Debug.log "foldl" (myFoldl (+) 0 [1, 2, 3, 4, 5])
        _ = Debug.log "sum" (mySum [1, 2, 3, 4])
        _ = Debug.log "count" (myCountHelper 0 [10, 20, 30])
    in
    text "done"
```

### TailRecClosureAcc

**Expected:**
```
result: 15
```

```elm
{-| Test tail-recursive accumulator closure in a let binding.
-}

-- CHECK: result: 15


recursiveLet : Int -> Int
recursiveLet n =
    let
        go acc m =
            if m <= 0 then acc else go (acc + m) (m - 1)
    in
    go 0 n


main =
    let
        result = recursiveLet 5
        _ = Debug.log "result" result
    in
    text "done"
```

### TailRecCustomCase

**Expected:**
```
total: 10
```

```elm
{-| Test tail-recursive function with case on custom type and
pattern destructuring, ensuring TailRec handles FanOut correctly.
-}

-- CHECK: total: 10


type MyList a
    = Nil
    | Cons a (MyList a)


sumMyList : Int -> MyList Int -> Int
sumMyList acc list =
    case list of
        Nil ->
            acc

        Cons x rest ->
            sumMyList (acc + x) rest


main =
    let
        myList = Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))
        _ = Debug.log "total" (sumMyList 0 myList)
    in
    text "done"
```

### TailRecDeciderSearch

**Expected:**
```
found: 42
```

```elm
{-| FAILING TEST: SSA dominance violation in let-bound tail-recursive function
with self-referencing non-tail recursive call.

Bug: When a let-bound tail-recursive function (MonoTailDef) makes a NON-tail
recursive call to itself inside the loop body, the self-reference resolves
to a stale sibling mapping SSA var from the outer scope, not the correct
closure reference.

Root cause: Lambdas.generateLambdaFunc merges siblingMappings into varMappings.
These sibling SSA vars come from the outer function's placeholder allocation.
Inside the compiled lambda, nextVar is reset, so fresh vars (doneInitVar,
resInitVar, scf.while results) alias with the sibling mapping vars.

The pattern requires:
  1. A let-bound tail-recursive function (MonoTailDef -> _tail_ prefix)
  2. A self-referencing non-tail recursive call in the body
     (e.g., case firstInlineExpr yes of Just e -> ...; Nothing -> firstInlineExpr no)
  3. The non-tail call uses eco.papExtend with the function closure as operand
  4. The closure reference resolves to a sibling mapping SSA var that has been
     overwritten by doneInitVar or another fresh var in the lambda function
-}

-- CHECK: found: 42


type Choice
    = Inline Int
    | Jump Int


type Decider
    = Leaf Choice
    | Chain Decider Decider


type Maybe_ a
    = Just_ a
    | Nothing_


search : Decider -> Maybe_ Int
search tree =
    let
        firstInlineExpr decider =
            case decider of
                Leaf choice ->
                    case choice of
                        Inline val ->
                            Just_ val

                        Jump _ ->
                            Nothing_

                Chain yes no ->
                    case firstInlineExpr yes of
                        Just_ e ->
                            Just_ e

                        Nothing_ ->
                            firstInlineExpr no
    in
    firstInlineExpr tree


unwrap : Maybe_ Int -> Int
unwrap m =
    case m of
        Just_ x -> x
        Nothing_ -> -1


main =
    let
        tree = Chain (Leaf (Jump 0)) (Chain (Leaf (Jump 1)) (Leaf (Inline 42)))
        result = unwrap (search tree)
        _ = Debug.log "found" result
    in
    text "done"
```

### TailRecFoldlCase

**Expected:**
```
result: 6
```

```elm
{-| Test hand-written tail-recursive foldl with case on list.
-}

-- CHECK: result: 6


main =
    let
        myFoldl f acc list =
            case list of
                [] -> acc
                x :: xs -> myFoldl f (f x acc) xs

        result = myFoldl (\a b -> a + b) 0 [ 1, 2, 3 ]
        _ = Debug.log "result" result
    in
    text "done"
```

### TailRecNestedCase

**Expected:**
```
find: True
nofind: False
last: 4
```

```elm
{-| Test tail-recursive function with nested case expressions
where multiple branches contain tail calls.
-}

-- CHECK: find: True
-- CHECK: nofind: False
-- CHECK: last: 4


contains : a -> List a -> Bool
contains target list =
    case list of
        [] ->
            False

        x :: rest ->
            if x == target then
                True
            else
                contains target rest


myLast : a -> List a -> a
myLast default list =
    case list of
        [] ->
            default

        x :: [] ->
            x

        _ :: rest ->
            myLast default rest


main =
    let
        _ = Debug.log "find" (contains 3 [1, 2, 3, 4])
        _ = Debug.log "nofind" (contains 5 [1, 2, 3, 4])
        _ = Debug.log "last" (myLast 0 [1, 2, 3, 4])
    in
    text "done"
```

### TailRecursiveSum

**Expected:**
```
sum1: 15
sum2: 55
sum3: 5050
```

```elm
{-| Test tail recursion.
-}

-- CHECK: sum1: 15
-- CHECK: sum2: 55
-- CHECK: sum3: 5050


sumHelper n acc =
    if n <= 0 then
        acc
    else
        sumHelper (n - 1) (acc + n)


sumTo n = sumHelper n 0


main =
    let
        _ = Debug.log "sum1" (sumTo 5)
        _ = Debug.log "sum2" (sumTo 10)
        _ = Debug.log "sum3" (sumTo 100)
    in
    text "done"
```

### TailRecWithLocalTailDef

**Expected:**
```
result: 220
```

```elm
{-| Test that an outer tail-recursive function containing a local
tail-recursive definition (MonoTailDef inside MonoLet) correctly
compiles when the body after the local def contains a tail call
to the outer function inside a case expression.

This exercises the TailRec.compileLetStep handling of MonoTailDef:
the body must be compiled via compileStep (maintaining TailRec context)
rather than falling back to Expr.generateExpr (which loses it).
-}

-- CHECK: result: 220


{-| Outer tail-recursive function. After computing a local helper result,
it uses a case expression where one branch tail-calls back to outerLoop.
-}
outerLoop : Int -> Int -> Int
outerLoop n acc =
    let
        -- Local tail-recursive function (will become MonoTailDef)
        sumUpTo : Int -> Int -> Int
        sumUpTo i s =
            if i <= 0 then
                s
            else
                sumUpTo (i - 1) (s + i)

        localResult = sumUpTo n 0
    in
    case localResult of
        0 ->
            -- Base case: done
            acc

        _ ->
            -- Tail call to outer function (MonoTailCall inside case after MonoTailDef)
            outerLoop (n - 1) (acc + localResult)


main =
    let
        -- outerLoop 10 0 should compute:
        -- n=10: sumUpTo 10 = 55, acc=0+55=55
        -- n=9:  sumUpTo 9 = 45, acc=55+45=100
        -- ... down to n=1: sumUpTo 1 = 1
        -- n=0: sumUpTo 0 = 0 -> base case, return acc
        result = outerLoop 10 0
        _ = Debug.log "result" result
    in
    text "done"
```

### TimerEffect

**Expected:**
```
TimerEffectTest: "fired 1"
TimerEffectTest: "fired 2"
TimerEffectTest: "fired 3"
TimerEffectTest: "fired 4"
TimerEffectTest: "fired 5"
TimerEffectTest: "done"
```

```elm
{-| Test that exercises the Platform.worker effect/scheduler mechanism.

On init, fire a 100ms timer via Process.sleep + Task.perform.
Each time it fires, update increments a counter and fires another.
After 5 firings, return Cmd.none so the program has no pending work.
-}

-- CHECK: TimerEffectTest: "fired 1"
-- CHECK: TimerEffectTest: "fired 2"
-- CHECK: TimerEffectTest: "fired 3"
-- CHECK: TimerEffectTest: "fired 4"
-- CHECK: TimerEffectTest: "fired 5"
-- CHECK: TimerEffectTest: "done"


type Msg
    = TimerFired


type alias Model =
    { count : Int
    }


sleepCmd : Cmd Msg
sleepCmd =
    Process.sleep 100
        |> Task.perform (\_ -> TimerFired)


init : () -> ( Model, Cmd Msg )
init _ =
    ( { count = 0 }
    , sleepCmd
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        TimerFired ->
            let
                newCount =
                    model.count + 1

                _ =
                    Debug.log "TimerEffectTest" ("fired " ++ String.fromInt newCount)
            in
            if newCount >= 5 then
                let
                    _ =
                        Debug.log "TimerEffectTest" "done"
                in
                ( { model | count = newCount }, Cmd.none )

            else
                ( { model | count = newCount }, sleepCmd )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
```

### ToFloat

**Expected:**
```
toFloat1: 42
toFloat2: -10
toFloat3: 0
```

```elm
{-| Test toFloat conversion.
-}

-- CHECK: toFloat1: 42
-- CHECK: toFloat2: -10
-- CHECK: toFloat3: 0


main =
    let
        _ = Debug.log "toFloat1" (toFloat 42)
        _ = Debug.log "toFloat2" (toFloat -10)
        _ = Debug.log "toFloat3" (toFloat 0)
    in
    text "done"
```

### TruncateToInt

**Expected:**
```
trunc1: 2
trunc2: -2
```

```elm
{-| Test truncate for Float to Int conversion.
-}

-- CHECK: trunc1: 2
-- CHECK: trunc2: -2


main =
    let
        _ = Debug.log "trunc1" (truncate 2.7)
        _ = Debug.log "trunc2" (truncate -2.7)
    in
    text "done"
```

### TupleFirst

**Expected:**
```
first1: 1
first2: "hello"
```

```elm
{-| Test Tuple.first.
-}

-- CHECK: first1: 1
-- CHECK: first2: "hello"


main =
    let
        _ = Debug.log "first1" (Tuple.first (1, 2))
        _ = Debug.log "first2" (Tuple.first ("hello", "world"))
    in
    text "done"
```

### TupleMapFirst

**Expected:**
```
mapFirst1: (2, 10)
mapFirst2: (10, 20)
```

```elm
{-| Test Tuple.mapFirst.
-}

-- CHECK: mapFirst1: (2, 10)
-- CHECK: mapFirst2: (10, 20)


main =
    let
        _ = Debug.log "mapFirst1" (Tuple.mapFirst (\x -> x * 2) (1, 10))
        _ = Debug.log "mapFirst2" (Tuple.mapFirst (\x -> x + 5) (5, 20))
    in
    text "done"
```

### TupleMapSecond

**Expected:**
```
mapSecond1: (1, 20)
mapSecond2: (5, 25)
```

```elm
{-| Test Tuple.mapSecond.
-}

-- CHECK: mapSecond1: (1, 20)
-- CHECK: mapSecond2: (5, 25)


main =
    let
        _ = Debug.log "mapSecond1" (Tuple.mapSecond (\x -> x * 2) (1, 10))
        _ = Debug.log "mapSecond2" (Tuple.mapSecond (\x -> x + 5) (5, 20))
    in
    text "done"
```

### TuplePairFunc

**Expected:**
```
pair1: (1, 2)
pair2: ("a", "b")
```

```elm
{-| Test Tuple.pair function.
-}

-- CHECK: pair1: (1, 2)
-- CHECK: pair2: ("a", "b")


main =
    let
        _ = Debug.log "pair1" (Tuple.pair 1 2)
        _ = Debug.log "pair2" (Tuple.pair "a" "b")
    in
    text "done"
```

### TuplePair

**Expected:**
```
pair1: (1, 2)
pair2: ("a", "b")
pair3: (True, False)
```

```elm
{-| Test tuple pair creation.
-}

-- CHECK: pair1: (1, 2)
-- CHECK: pair2: ("a", "b")
-- CHECK: pair3: (True, False)


main =
    let
        _ = Debug.log "pair1" (1, 2)
        _ = Debug.log "pair2" ("a", "b")
        _ = Debug.log "pair3" (True, False)
    in
    text "done"
```

### TupleSecond

**Expected:**
```
second1: 2
second2: "world"
```

```elm
{-| Test Tuple.second.
-}

-- CHECK: second1: 2
-- CHECK: second2: "world"


main =
    let
        _ = Debug.log "second1" (Tuple.second (1, 2))
        _ = Debug.log "second2" (Tuple.second ("hello", "world"))
    in
    text "done"
```

### TupleTriple

**Expected:**
```
triple1: (1, 2, 3)
triple2: ("a", "b", "c")
```

```elm
{-| Test triple creation.
-}

-- CHECK: triple1: (1, 2, 3)
-- CHECK: triple2: ("a", "b", "c")


main =
    let
        _ = Debug.log "triple1" (1, 2, 3)
        _ = Debug.log "triple2" ("a", "b", "c")
    in
    text "done"
```

---

## E2E Tests: New Coverage Alignment Tests

### AccessorVariable

**Expected:** `via_var: 42`, `mapped: [10,20,30]`, `person_name: "Alice"`, `company_name: "ACME"`

```elm
{-| Test accessor function stored in a variable and used on different record types. -}

-- CHECK: via_var: 42
-- CHECK: mapped: [10,20,30]
-- CHECK: person_name: "Alice"
-- CHECK: company_name: "ACME"


main =
    let
        accessor = .value
        item = { value = 42, label = "test" }
        _ = Debug.log "via_var" (accessor item)
        items = [ { value = 10 }, { value = 20 }, { value = 30 } ]
        _ = Debug.log "mapped" (List.map .value items)
        persons = [ { name = "Alice", age = 30 } ]
        companies = [ { name = "ACME", employees = 100 } ]
        personName =
            case List.head (List.map .name persons) of
                Just n ->
                    n

                Nothing ->
                    "none"
        companyName =
            case List.head (List.map .name companies) of
                Just n ->
                    n

                Nothing ->
                    "none"
        _ = Debug.log "person_name" personName
        _ = Debug.log "company_name" companyName
    in
    text "done"
```

### AsPatternFuncArg

**Expected:** `var_alias: (42, 42)`, `tuple_alias: (1, (1, 2))`, `record_alias: (1, { x = 1, y = 2 })`, `cons_alias: (1, [1, 2, 3])`

```elm
{-| Test as-patterns in function arguments. -}

-- CHECK: var_alias: (42, 42)
-- CHECK: tuple_alias: (1, (1, 2))
-- CHECK: record_alias: (1, { x = 1, y = 2 })
-- CHECK: cons_alias: (1, [1, 2, 3])


withVar (x as whole) = (x, whole)


withPair (((a, b)) as pair) = (a, pair)


withRec (({ x, y }) as point) = (x, point)


withList (((h :: t)) as list) = (h, list)


main =
    let
        _ = Debug.log "var_alias" (withVar 42)
        _ = Debug.log "tuple_alias" (withPair (1, 2))
        _ = Debug.log "record_alias" (withRec { x = 1, y = 2 })
        _ = Debug.log "cons_alias" (withList [1, 2, 3])
    in
    text "done"
```

### CaseCharManyBranch

**Expected:** `d0: 0`, `d5: 5`, `d9: 9`, `other: -1`

```elm
{-| Test case on Char with many literal patterns (digit detection). -}

-- CHECK: d0: 0
-- CHECK: d5: 5
-- CHECK: d9: 9
-- CHECK: other: -1


digitToInt c =
    case c of
        '0' -> 0
        '1' -> 1
        '2' -> 2
        '3' -> 3
        '4' -> 4
        '5' -> 5
        '6' -> 6
        '7' -> 7
        '8' -> 8
        '9' -> 9
        _ -> -1


main =
    let
        _ = Debug.log "d0" (digitToInt '0')
        _ = Debug.log "d5" (digitToInt '5')
        _ = Debug.log "d9" (digitToInt '9')
        _ = Debug.log "other" (digitToInt 'x')
    in
    text "done"
```

### CaseCtorArgPattern

**Expected:** `id: 30`, `age: 25`

```elm
{-| Test constructor argument patterns in function parameters. -}

-- CHECK: id: 30
-- CHECK: age: 25


type Person
    = Person Int Int


getId : Person -> Int
getId (Person id _) =
    id


getAge : Person -> Int
getAge (Person _ age) =
    age


main =
    let
        p =
            Person 30 25

        _ =
            Debug.log "id" (getId p)

        _ =
            Debug.log "age" (getAge p)
    in
    text "done"
```

### CaseDeepNest

**Expected:** `r1: "x=0,y=0"`, `r2: "x=0,y=other"`, `r3: "x=1,y=0"`, `r4: "x=other"`, `triple: "all zero"`, `triple2: "z=other"`

```elm
{-| Test deeply nested case expressions (case inside case branch) with int/string scrutinees. -}

-- CHECK: r1: "x=0,y=0"
-- CHECK: r2: "x=0,y=other"
-- CHECK: r3: "x=1,y=0"
-- CHECK: r4: "x=other"
-- CHECK: triple: "all zero"
-- CHECK: triple2: "z=other"


classify x y =
    case x of
        0 ->
            case y of
                0 ->
                    "x=0,y=0"

                _ ->
                    "x=0,y=other"

        1 ->
            case y of
                0 ->
                    "x=1,y=0"

                _ ->
                    "x=1,y=other"

        _ ->
            "x=other"


classifyTriple x y z =
    case x of
        0 ->
            case y of
                0 ->
                    case z of
                        0 ->
                            "all zero"

                        _ ->
                            "z=other"

                _ ->
                    "y=other"

        _ ->
            "x=other"


main =
    let
        _ = Debug.log "r1" (classify 0 0)
        _ = Debug.log "r2" (classify 0 5)
        _ = Debug.log "r3" (classify 1 0)
        _ = Debug.log "r4" (classify 9 0)
        _ = Debug.log "triple" (classifyTriple 0 0 0)
        _ = Debug.log "triple2" (classifyTriple 0 0 7)
    in
    text "done"
```

### CaseMaybePair

**Expected:** `both: 7`, `first: 3`, `second: 4`, `neither: 0`

```elm
{-| Test overlapping Maybe pair patterns in decision tree. -}

-- CHECK: both: 7
-- CHECK: first: 3
-- CHECK: second: 4
-- CHECK: neither: 0


match t =
    case t of
        (Just a, Just b) -> a + b
        (Just a, Nothing) -> a
        (Nothing, Just b) -> b
        (Nothing, Nothing) -> 0


main =
    let
        _ = Debug.log "both" (match (Just 3, Just 4))
        _ = Debug.log "first" (match (Just 3, Nothing))
        _ = Debug.log "second" (match (Nothing, Just 4))
        _ = Debug.log "neither" (match (Nothing, Nothing))
    in
    text "done"
```

### CaseMixedPattern

**Expected:** `head: 42`, `empty: 0`, `pair_head: 10`, `pair_empty: -1`, `nested: 99`

```elm
{-| Test case with mixed constructor and list patterns in a single expression. -}

-- CHECK: head: 42
-- CHECK: empty: 0
-- CHECK: pair_head: 10
-- CHECK: pair_empty: -1
-- CHECK: nested: 99


type Container
    = Container (List Int)


headOfContainer c =
    case c of
        Container (x :: _) ->
            x

        Container [] ->
            0


type Pair
    = Pair Int (List Int)


pairHead p =
    case p of
        Pair n (x :: _) ->
            x

        Pair n [] ->
            -1


type Nested
    = Nested (Maybe (List Int))


nestedHead n =
    case n of
        Nested (Just (x :: _)) ->
            x

        Nested (Just []) ->
            0

        Nested Nothing ->
            -1


main =
    let
        _ = Debug.log "head" (headOfContainer (Container [ 42, 99 ]))
        _ = Debug.log "empty" (headOfContainer (Container []))
        _ = Debug.log "pair_head" (pairHead (Pair 5 [ 10, 20 ]))
        _ = Debug.log "pair_empty" (pairHead (Pair 5 []))
        _ = Debug.log "nested" (nestedHead (Nested (Just [ 99, 88 ])))
    in
    text "done"
```

### CaseNegativeInt

**Expected:** `neg: "minus one"`, `zero: "zero"`, `pos: "one"`, `other: "other"`

```elm
{-| Test case on negative int patterns. -}

-- CHECK: neg: "minus one"
-- CHECK: zero: "zero"
-- CHECK: pos: "one"
-- CHECK: other: "other"


classify n =
    case n of
        -1 -> "minus one"
        0 -> "zero"
        1 -> "one"
        _ -> "other"


main =
    let
        _ = Debug.log "neg" (classify (-1))
        _ = Debug.log "zero" (classify 0)
        _ = Debug.log "pos" (classify 1)
        _ = Debug.log "other" (classify 42)
    in
    text "done"
```

### CaseNestedCtor

**Expected:** `single: 42`, `double: 3`

```elm
{-| Test nested constructor patterns (Container (Wrap n)). -}

-- CHECK: single: 42
-- CHECK: double: 3


type Wrapper
    = Wrap Int


type Container
    = Container Wrapper


extract : Container -> Int
extract c =
    case c of
        Container (Wrap n) ->
            n


type Box
    = Box ( Int, Int )


sumBox : Box -> Int
sumBox b =
    case b of
        Box ( a, x ) ->
            a + x


main =
    let
        _ =
            Debug.log "single" (extract (Container (Wrap 42)))

        _ =
            Debug.log "double" (sumBox (Box ( 1, 2 )))
    in
    text "done"
```

### CaseStringManyBranch

**Expected:** `d1: "Monday"`, `d4: "Thursday"`, `d7: "Sunday"`, `other: "unknown"`

```elm
{-| Test case on String with many literal patterns (day names). -}

-- CHECK: d1: "Monday"
-- CHECK: d4: "Thursday"
-- CHECK: d7: "Sunday"
-- CHECK: other: "unknown"


dayName day =
    case day of
        "Mon" -> "Monday"
        "Tue" -> "Tuesday"
        "Wed" -> "Wednesday"
        "Thu" -> "Thursday"
        "Fri" -> "Friday"
        "Sat" -> "Saturday"
        "Sun" -> "Sunday"
        _ -> "unknown"


main =
    let
        _ = Debug.log "d1" (dayName "Mon")
        _ = Debug.log "d4" (dayName "Thu")
        _ = Debug.log "d7" (dayName "Sun")
        _ = Debug.log "other" (dayName "xyz")
    in
    text "done"
```

### CaseTupleLiteral

**Expected:** `origin: "origin"`, `xaxis: "x-axis"`, `yaxis: "y-axis"`, `unit: "unit"`, `general: "general"`

```elm
{-| Test case on nested tuple with literal patterns. -}

-- CHECK: origin: "origin"
-- CHECK: xaxis: "x-axis"
-- CHECK: yaxis: "y-axis"
-- CHECK: unit: "unit"
-- CHECK: general: "general"


classify t =
    case t of
        (0, 0) -> "origin"
        (0, _) -> "y-axis"
        (_, 0) -> "x-axis"
        (1, 1) -> "unit"
        _ -> "general"


main =
    let
        _ = Debug.log "origin" (classify (0, 0))
        _ = Debug.log "xaxis" (classify (3, 0))
        _ = Debug.log "yaxis" (classify (0, 5))
        _ = Debug.log "unit" (classify (1, 1))
        _ = Debug.log "general" (classify (2, 3))
    in
    text "done"
```

### ClosureCaptureRecord

**Expected:** `rec: 6`, `tup: 6`

```elm
{-| Test closures capturing record fields and tuple elements. -}

-- CHECK: rec: 6
-- CHECK: tup: 6


closureFromRecord : { x : Int, y : Int } -> Int -> Int
closureFromRecord rec =
    \n -> rec.x + rec.y + n


closureFromTuple : (Int, Int) -> Int -> Int
closureFromTuple pair =
    case pair of
        (a, b) -> \n -> a + b + n


main =
    let
        _ = Debug.log "rec" (closureFromRecord { x = 1, y = 2 } 3)
        _ = Debug.log "tup" (closureFromTuple (1, 2) 3)
    in
    text "done"
```

### ClosureCaptureTuple

**Expected:** `add: 6`, `nested: 10`, `mixed: 9`

```elm
{-| Test closure capturing tuple values. -}

-- CHECK: add: 6
-- CHECK: nested: 10
-- CHECK: mixed: 9


addWithTuple : ( Int, Int ) -> Int -> Int
addWithTuple pair =
    \n ->
        let
            ( a, b ) =
                pair
        in
        a + b + n


nestedTuple : ( ( Int, Int ), Int ) -> Int -> Int
nestedTuple outer =
    \n ->
        let
            ( inner, c ) =
                outer

            ( a, b ) =
                inner
        in
        a + b + c + n


mixedCapture : Int -> ( Int, Int ) -> Int -> Int
mixedCapture x pair =
    \n ->
        let
            ( a, b ) =
                pair
        in
        x + a + b + n


main =
    let
        _ =
            Debug.log "add" (addWithTuple ( 1, 2 ) 3)

        _ =
            Debug.log "nested" (nestedTuple ( ( 1, 2 ), 3 ) 4)

        _ =
            Debug.log "mixed" (mixedCapture 1 ( 2, 3 ) 3)
    in
    text "done"
```

### CustomTypeFuncField

**Expected:** `op1: 11`, `op2: 20`

```elm
{-| Test custom type wrapping a function field. -}

-- CHECK: op1: 11
-- CHECK: op2: 20


type Op
    = Op (Int -> Int)


runOp : Op -> Int
runOp (Op f) =
    f 10


main =
    let
        _ =
            Debug.log "op1" (runOp (Op (\x -> x + 1)))

        _ =
            Debug.log "op2" (runOp (Op (\x -> x * 2)))
    in
    text "done"
```

### DeepNestStress

**Expected:** `nested_list: 1`, `nested_tuple: 1`, `nested_record: 1`, `nested_let: 10`

```elm
{-| Test deeply nested data structures: lists, tuples, records, and lets. -}

-- CHECK: nested_list: 1
-- CHECK: nested_tuple: 1
-- CHECK: nested_record: 1
-- CHECK: nested_let: 10


main =
    let
        nl = [ [ [ [ 1 ] ] ] ]
        nlVal =
            case nl of
                [ [ [ [ x ] ] ] ] ->
                    x

                _ ->
                    0
        _ = Debug.log "nested_list" nlVal
        nt = ( ( ( ( 1, 2 ), 3 ), 4 ), 5 )
        ( ( ( ( first, _ ), _ ), _ ), _ ) = nt
        _ = Debug.log "nested_tuple" first
        nr = { n = { n = { n = { v = 1 } } } }
        _ = Debug.log "nested_record" nr.n.n.n.v
        a =
            let
                b =
                    let
                        c =
                            let
                                d = 10
                            in
                            d
                    in
                    c
            in
            b
        _ = Debug.log "nested_let" a
    in
    text "done"
```

### EitherType

**Expected:** `left: 42`, `right: 0`, `mapLeft: 84`, `isLeft: True`

```elm
{-| Test Either-like polymorphic type with two constructors and two type parameters. -}

-- CHECK: left: 42
-- CHECK: right: 0
-- CHECK: mapLeft: 84
-- CHECK: isLeft: True


type Either a b
    = Left a
    | Right b


fromEither e default =
    case e of
        Left x ->
            x

        Right _ ->
            default


mapLeft f e =
    case e of
        Left x ->
            Left (f x)

        Right y ->
            Right y


isLeft e =
    case e of
        Left _ ->
            True

        Right _ ->
            False


main =
    let
        _ = Debug.log "left" (fromEither (Left 42) 0)
        _ = Debug.log "right" (fromEither (Right "err") 0)
        mapped = mapLeft (\x -> x * 2) (Left 42)
        _ = Debug.log "mapLeft" (fromEither mapped 0)
        _ = Debug.log "isLeft" (isLeft (Left 1))
    in
    text "done"
```

### LambdaPatternArg

**Expected:** `swap: (2,1)`, `getX: 42`, `mixed: "b"`

```elm
{-| Test lambda with tuple and record pattern arguments. -}

-- CHECK: swap: (2,1)
-- CHECK: getX: 42
-- CHECK: mixed: "b"


main =
    let
        swap =
            \( x, y ) -> ( y, x )

        getX =
            \{ x } -> x

        mixed =
            \a ( b, c ) _ -> b

        _ =
            Debug.log "swap" (swap ( 1, 2 ))

        _ =
            Debug.log "getX" (getX { x = 42 })

        _ =
            Debug.log "mixed" (mixed 1 ( "b", 2 ) 3)
    in
    text "done"
```

### LetDestructAlias

**Expected:** `pair: (1, 2)`, `first: 1`

```elm
{-| Test let-destructuring with alias patterns. -}

-- CHECK: pair: (1, 2)
-- CHECK: first: 1


main =
    let
        (((a, b)) as pair) = (1, 2)
        _ = Debug.log "pair" pair
        _ = Debug.log "first" a
    in
    text "done"
```

### LetDestructCons

**Expected:** `head: 1`, `second: 20`

```elm
{-| Test cons/list pattern destructuring in let bindings. -}

-- CHECK: head: 1
-- CHECK: second: 20


main =
    let
        h :: t = [1, 2, 3]
        a :: b :: rest = [10, 20, 30]
        _ = Debug.log "head" h
        _ = Debug.log "second" b
    in
    text "done"
```

### LetDestructFuncTuple

**Expected:** `get: 10`, `set: 99`

```elm
{-| Test let-destructuring a tuple of functions selected by case. -}

-- CHECK: get: 10
-- CHECK: set: 99


type Loc
    = First
    | Second


choose : Loc -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
choose loc rec =
    let
        ( getter, setter ) =
            case loc of
                First ->
                    ( .a, \x m -> { m | a = x } )

                Second ->
                    ( .b, \x m -> { m | b = x } )
    in
    ( getter rec, setter 99 rec )


main =
    let
        ( v, r ) =
            choose First { a = 10, b = 20 }

        _ =
            Debug.log "get" v

        _ =
            Debug.log "set" r.a
    in
    text "done"
```

### LetDestructRecord

**Expected:** `single: 42`, `multi: 3`, `partial: 4`, `mixed: 3`

```elm
{-| Test record destructuring in let bindings. -}

-- CHECK: single: 42
-- CHECK: multi: 3
-- CHECK: partial: 4
-- CHECK: mixed: 3


main =
    let
        { x } = { x = 42 }
        { a, b } = { a = 1, b = 2 }
        { p, r } = { p = 1, q = 2, r = 3 }
        ({ s }, t) = ({ s = 1 }, 2)
        _ = Debug.log "single" x
        _ = Debug.log "multi" (a + b)
        _ = Debug.log "partial" (p + r)
        _ = Debug.log "mixed" (s + t)
    in
    text "done"
```

### LetDestructTupleNested

**Expected:** `basic: 3`, `nested: 8`, `chain: 6`

```elm
{-| Test nested and chained tuple destructuring in let bindings. -}

-- CHECK: basic: 3
-- CHECK: nested: 8
-- CHECK: chain: 6


main =
    let
        (a, b) = (1, 2)
        ((c, d), (e, f)) = ((3, 4), (5, 6))
        (g, rest) = (1, (2, 3))
        (h, i) = rest
        _ = Debug.log "basic" (a + b)
        _ = Debug.log "nested" (c + d + e - f + 2)
        _ = Debug.log "chain" (g + h + i)
    in
    text "done"
```

### LetShadowing

**Expected:** `outer: 1`, `inner: 2`, `afterInner: 1`, `deep: 3`, `param_shadow: 20`

```elm
{-| Test nested let bindings with variable shadowing. -}

-- CHECK: outer: 1
-- CHECK: inner: 2
-- CHECK: afterInner: 1
-- CHECK: deep: 3
-- CHECK: param_shadow: 20


useShadow x =
    let
        y = x * 2
        result =
            let
                y = x * 4
            in
            y
    in
    result


main =
    let
        x = 1
        _ = Debug.log "outer" x
        result =
            let
                x = 2
            in
            x
        _ = Debug.log "inner" result
        _ = Debug.log "afterInner" x
        deep =
            let
                a = 1
            in
            let
                a = 2
            in
            let
                a = 3
            in
            a
        _ = Debug.log "deep" deep
        _ = Debug.log "param_shadow" (useShadow 5)
    in
    text "done"
```

### ListCompoundElements

**Expected:** `tupleLen: 3`, `firstTuple: (1,"a")`, `recordLen: 2`, `firstX: 10`, `sumX: 30`

```elm
{-| Test lists containing compound elements: tuples and records. -}

-- CHECK: tupleLen: 3
-- CHECK: firstTuple: (1,"a")
-- CHECK: recordLen: 2
-- CHECK: firstX: 10
-- CHECK: sumX: 30


main =
    let
        tuples = [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ]
        _ = Debug.log "tupleLen" (List.length tuples)
        _ = Debug.log "firstTuple" (case List.head tuples of
            Just t -> t
            Nothing -> ( 0, "" ))
        records = [ { x = 10, y = "hello" }, { x = 20, y = "world" } ]
        _ = Debug.log "recordLen" (List.length records)
        firstX =
            case List.head records of
                Just r ->
                    r.x

                Nothing ->
                    0
        _ = Debug.log "firstX" firstX
        _ = Debug.log "sumX" (List.foldl (\r acc -> acc + r.x) 0 records)
    in
    text "done"
```

### MultiLocalTailRec

**Expected:** `result: 15`

```elm
{-| Test multiple local tail-recursive defs in same let block. -}

-- CHECK: result: 15


main =
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

        _ =
            Debug.log "result" (countDown 5 + sumUp 5 0)
    in
    text "done"
```

### MutualRecursionThreeWay

**Expected:** `a10: 1`, `a9: 0`, `a3: 0`, `a0: 0`

```elm
{-| Test three-way mutual recursion: funcA calls funcB, funcB calls funcC, funcC calls funcA. -}

-- CHECK: a10: 1
-- CHECK: a9: 0
-- CHECK: a3: 0
-- CHECK: a0: 0


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


main =
    let
        _ = Debug.log "a10" (funcA 10)
        _ = Debug.log "a9" (funcA 9)
        _ = Debug.log "a3" (funcA 3)
        _ = Debug.log "a0" (funcA 0)
    in
    text "done"
```

### PartialAppCaptureTypes

**Expected:** `float_cap: 1.5`, `char_cap: 'x'`, `bool_cap: True`, `string_cap: "hello"`, `combined: 3.5`

```elm
{-| Test partial application capturing Float, Char, Bool, and String values. -}

-- CHECK: float_cap: 1.5
-- CHECK: char_cap: 'x'
-- CHECK: bool_cap: True
-- CHECK: string_cap: "hello"
-- CHECK: combined: 3.5


first3 a b c =
    a


addFloat a b =
    a + b


main =
    let
        pFloat = first3 1.5
        pChar = first3 'x'
        pBool = first3 True
        pStr = first3 "hello"
        _ = Debug.log "float_cap" (pFloat 2 3)
        _ = Debug.log "char_cap" (pChar 2 3)
        _ = Debug.log "bool_cap" (pBool 2 3)
        _ = Debug.log "string_cap" (pStr 2 3)
        partialAdd = addFloat 1.5
        _ = Debug.log "combined" (partialAdd 2.0)
    in
    text "done"
```

### PolyChainCall

**Expected:** `size: 2`

```elm
{-| Test polymorphic chain callers: polymorphic function calling polymorphic callee multiple times. -}

-- CHECK: size: 2


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
        Leaf ->
            0

        Node left _ right ->
            1 + sizeTree left + sizeTree right


main =
    let
        _ =
            Debug.log "size" (sizeTree (buildTree 1 2))
    in
    text "done"
```

### PolyEscapeRecord

**Expected:** `result: 42`, `narrowed: 6`

```elm
{-| Test polymorphic values escaping through records. -}

-- CHECK: result: 42
-- CHECK: narrowed: 6


main =
    let
        r =
            { fn = \x -> x }

        _ =
            Debug.log "result" (r.fn 42)

        r2 =
            { r | fn = \y -> y + 1 }

        _ =
            Debug.log "narrowed" (r2.fn 5)
    in
    text "done"
```

### PolySpecializeRecursive

**Expected:** `intLen: 3`, `strLen: 2`, `intMap: [2, 4, 6]`, `strMap: ["aa", "bb"]`

```elm
{-| Test polymorphic function specialization at multiple types. -}

-- CHECK: intLen: 3
-- CHECK: strLen: 2
-- CHECK: intMap: [2, 4, 6]
-- CHECK: strMap: ["aa", "bb"]


myLength : List a -> Int
myLength xs =
    case xs of
        [] -> 0
        _ :: rest -> 1 + myLength rest


myMap : (a -> b) -> List a -> List b
myMap f xs =
    case xs of
        [] -> []
        x :: rest -> f x :: myMap f rest


main =
    let
        _ = Debug.log "intLen" (myLength [1, 2, 3])
        _ = Debug.log "strLen" (myLength ["a", "b"])
        _ = Debug.log "intMap" (myMap (\x -> x * 2) [1, 2, 3])
        _ = Debug.log "strMap" (myMap (\s -> s ++ s) ["a", "b"])
    in
    text "done"
```

### PolyTailRecReverse

**Expected:** `intRev: [3, 2, 1]`, `strRev: ["c", "b", "a"]`

```elm
{-| Test polymorphic tail-recursive reverse at multiple types. -}

-- CHECK: intRev: [3, 2, 1]
-- CHECK: strRev: ["c", "b", "a"]


reverseHelper acc xs =
    case xs of
        [] -> acc
        x :: rest -> reverseHelper (x :: acc) rest


myReverse xs = reverseHelper [] xs


main =
    let
        _ = Debug.log "intRev" (myReverse [1, 2, 3])
        _ = Debug.log "strRev" (myReverse ["a", "b", "c"])
    in
    text "done"
```

### RecordChainedUpdate

**Expected:** `multi: { x = 100, y = 20, z = 300 }`, `chain: { x = 10, y = 20 }`

```elm
{-| Test multi-field record update and chained updates. -}

-- CHECK: multi: { x = 100, y = 20, z = 300 }
-- CHECK: chain: { x = 10, y = 20 }


main =
    let
        r =
            { x = 1, y = 20, z = 3 }

        multi =
            { r | x = 100, z = 300 }

        s =
            { x = 1, y = 2 }

        s2 =
            { s | x = 10 }

        chain =
            { s2 | y = 20 }

        _ =
            Debug.log "multi" multi

        _ =
            Debug.log "chain" chain
    in
    text "done"
```

### RecordNestedAccess

**Expected:** `deep: 42`, `chain: 99`

```elm
{-| Test nested record chained access. -}

-- CHECK: deep: 42
-- CHECK: chain: 99


main =
    let
        r =
            { nested = { value = 42 } }

        s =
            { a = { b = { c = 99 } } }

        _ =
            Debug.log "deep" r.nested.value

        _ =
            Debug.log "chain" s.a.b.c
    in
    text "done"
```

### RecordWithFunctions

**Expected:** `apply1: 11`, `apply2: 20`, `composed: 22`, `updated: 7`

```elm
{-| Test records containing function values in fields. -}

-- CHECK: apply1: 11
-- CHECK: apply2: 20
-- CHECK: composed: 22
-- CHECK: updated: 7


main =
    let
        ops = { add = \x -> x + 1, mul = \x -> x * 2 }
        _ = Debug.log "apply1" (ops.add 10)
        _ = Debug.log "apply2" (ops.mul 10)
        _ = Debug.log "composed" (ops.mul (ops.add 10))
        ops2 = { ops | add = \x -> x + 2 }
        _ = Debug.log "updated" (ops2.add 5)
    in
    text "done"
```

### RecursiveMutualType

**Expected:** `nodes: 4`

```elm
{-| Test mutually recursive types (Forest/RoseTree). -}

-- CHECK: nodes: 4


type Forest a
    = Forest (List (RoseTree a))


type RoseTree a
    = RoseNode a (Forest a)


countNodes : RoseTree a -> Int
countNodes (RoseNode _ (Forest children)) =
    1 + List.foldl (\child acc -> acc + countNodes child) 0 children


main =
    let
        tree = RoseNode 1 (Forest
            [ RoseNode 2 (Forest [])
            , RoseNode 3 (Forest [ RoseNode 4 (Forest []) ])
            ])
        _ = Debug.log "nodes" (countNodes tree)
    in
    text "done"
```

### RecursiveTree

**Expected:** `sum: 6`, `depth: 3`

```elm
{-| Test recursive binary tree type with sum and depth traversals. -}

-- CHECK: sum: 6
-- CHECK: depth: 3


type Tree a
    = Leaf a
    | Branch (Tree a) (Tree a)


sumTree tree =
    case tree of
        Leaf n -> n
        Branch left right -> sumTree left + sumTree right


depth tree =
    case tree of
        Leaf _ -> 1
        Branch left right ->
            1 + max (depth left) (depth right)


main =
    let
        t = Branch (Branch (Leaf 1) (Leaf 2)) (Leaf 3)
        _ = Debug.log "sum" (sumTree t)
        _ = Debug.log "depth" (depth t)
    in
    text "done"
```

### RecursiveTypeInRecord

**Expected:** `eval: 6`

```elm
{-| Test recursive type nested in record field. -}

-- CHECK: eval: 6


type Expr
    = Lit Int
    | Add { left : Expr, right : Expr }


eval : Expr -> Int
eval expr =
    case expr of
        Lit n ->
            n

        Add r ->
            eval r.left + eval r.right


main =
    let
        e =
            Add { left = Lit 1, right = Add { left = Lit 2, right = Lit 3 } }

        _ =
            Debug.log "eval" (eval e)
    in
    text "done"
```

### TypeClassConstraint

**Expected:** `absInt: 5`, `absFloat: 3.14`, `minInt: 3`, `concatStr: "hello world"`

```elm
{-| Test number, comparable, and appendable type-class constraints. -}

-- CHECK: absInt: 5
-- CHECK: absFloat: 3.14
-- CHECK: minInt: 3
-- CHECK: concatStr: "hello world"


zabs : number -> number
zabs n =
    if n < 0 then
        -n

    else
        n


zmin : comparable -> comparable -> comparable
zmin a b =
    if a < b then
        a

    else
        b


zconcat : appendable -> appendable -> appendable
zconcat a b =
    a ++ b


main =
    let
        _ =
            Debug.log "absInt" (zabs -5)

        _ =
            Debug.log "absFloat" (zabs -3.14)

        _ =
            Debug.log "minInt" (zmin 3 5)

        _ =
            Debug.log "concatStr" (zconcat "hello " "world")
    in
    text "done"
```

### WrapperUnionField

**Expected:** `result: 7`

```elm
{-| Test wrapper type holding a record with a union field. -}

-- CHECK: result: 7


type Kind
    = A
    | B Int


type Error
    = Error { tag : Kind, count : Int }


getTag : Error -> Int
getTag e =
    case e of
        Error props ->
            case props.tag of
                A ->
                    0

                B n ->
                    n


main =
    let
        _ =
            Debug.log "result" (getTag (Error { tag = B 7, count = 1 }))
    in
    text "done"
```

---
