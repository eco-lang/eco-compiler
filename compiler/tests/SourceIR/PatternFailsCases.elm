module SourceIR.PatternFailsCases exposing (expectRejectedSuite, expectSuite)

{-| Programs that pattern-match checking (`Compiler.Nitpick.PatternMatches`)
must reject, each with the report it must be rejected with: the
pattern-match module of the negative catalogue
(`SourceIR.Suite.RejectedSuites`). They type check, so the stage that rejects
them is the one between type checking and typed optimization.

`expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`, the title of the first report and a
fragment of its text, usually the pattern the report says is missing;
`TestLogic.Reporting.ExpectedRejectionTest` checks that pattern-match checking,
and no earlier stage, rejects each program with that report. `expectSuite`
gives a check only the programs; the parity of the two type-checking paths,
which must accept them alike, and the canonicalization checks run on them.

Each program is written as source text and defines `testValue`. The cases
cover the shapes the reporter of `Compiler.Nitpick.Error` distinguishes, by
group:

  - "Missing patterns" (`MISSING PATTERNS`): a `case` without a branch for one
    constructor of a custom type; one over `Int`, `Char` and `String`
    literals, which can never cover their type; one over lists of length zero
    and one; one over pairs of `Bool` without `( False, False )`; and one on a
    record field's `Maybe` without `Nothing`.
  - "Redundant patterns" (`REDUNDANT PATTERN`): a branch after a wildcard, and
    a branch after branches that already cover every constructor.
  - "Unsafe patterns" (`UNSAFE PATTERN`): a pattern that does not cover its
    type where no branch can be added: a `let` destructuring of a `Just`, a
    function argument matching `Just`, and a lambda argument matching a
    non-empty list.
  - "Catalogue unsafe patterns" (`UNSAFE PATTERN`): the 21 programs that
    standard-catalogue cases held before they were made valid
    (`SourceIR.PatternArgCases` 9, `SourceIR.AsPatternCases` 5,
    `SourceIR.LetDestructCases` 3, `SourceIR.EdgeCaseCases` 2,
    `SourceIR.MultiDefCases` 1, `SourceIR.HigherOrderCases` 1): list, cons
    and literal patterns in function, lambda and `let`-function arguments, alone,
    aliased, or nested in tuples and records, and list patterns in `let`
    destructurings.

Among what is not tested: the order and wording of several missing patterns
in one report.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromSource
        , rejectedWith
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Pattern match failure tests " followed by
`condStr`, with one test per group of cases (see `groups`). Each test applies
`expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Pattern match failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Pattern match failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Missing patterns", missingCases )
    , ( "Redundant patterns", redundantCases )
    , ( "Unsafe patterns", unsafeCases )
    , ( "Catalogue unsafe patterns", catalogueUnsafeCases )
    ]



-- ============================================================================
-- MISSING PATTERNS
-- ============================================================================


{-| A `case` that misses a value of each kind the checker distinguishes: a
constructor, an `Int`, a `Char` and a `String` literal, a list length, and a
shape of a tuple. The fragment is the missing pattern as the report prints it.
-}
missingCases : List RejectedCase
missingCases =
    [ fromSource "a missing constructor"
        (rejectedWithFragment "MISSING PATTERNS" "Blue")
        """
type Colour
    = Red
    | Green
    | Blue


code colour =
    case colour of
        Red ->
            1

        Green ->
            2


testValue =
    code Green
"""
    , fromSource "a missing Int literal"
        (rejectedWithFragment "MISSING PATTERNS" "This `case` does not have branches for all possibilities")
        """
name n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"


testValue =
    name 1
"""
    , fromSource "a missing Char literal"
        (rejectedWithFragment "MISSING PATTERNS" "This `case` does not have branches for all possibilities")
        """
isVowel c =
    case c of
        'a' ->
            True

        'e' ->
            True


testValue =
    isVowel 'a'
"""
    , fromSource "a missing String literal"
        (rejectedWithFragment "MISSING PATTERNS" "This `case` does not have branches for all possibilities")
        """
greet s =
    case s of
        "hello" ->
            1

        "bye" ->
            2


testValue =
    greet "hello"
"""
    , fromSource "a missing list length"
        (rejectedWithFragment "MISSING PATTERNS" "_ :: _ :: _")
        """
firstOrZero xs =
    case xs of
        [] ->
            0

        [ x ] ->
            x


testValue =
    firstOrZero [ 1 ]
"""
    , fromSource "a missing tuple shape"
        (rejectedWithFragment "MISSING PATTERNS" "( False, False )")
        """
either pair =
    case pair of
        ( True, _ ) ->
            1

        ( False, True ) ->
            2


testValue =
    either ( True, False )
"""
    , fromSource "a missing shape inside a record field"
        (rejectedWithFragment "MISSING PATTERNS" "Nothing")
        """
unwrap r =
    case r.value of
        Just v ->
            v


testValue =
    unwrap { value = Just 1 }
"""
    ]



-- ============================================================================
-- REDUNDANT PATTERNS
-- ============================================================================


{-| A branch that can never be reached: after a wildcard, and after branches
that already cover every constructor.
-}
redundantCases : List RejectedCase
redundantCases =
    [ fromSource "a branch after a wildcard"
        (rejectedWithFragment "REDUNDANT PATTERN" "The 2nd pattern is redundant")
        """
name n =
    case n of
        _ ->
            "any"

        0 ->
            "zero"


testValue =
    name 0
"""
    , fromSource "a branch after every constructor"
        (rejectedWithFragment "REDUNDANT PATTERN" "The 3rd pattern is redundant")
        """
orZero m =
    case m of
        Just v ->
            v

        Nothing ->
            0

        Just 1 ->
            1


testValue =
    orZero (Just 2)
"""
    ]



-- ============================================================================
-- UNSAFE PATTERNS
-- ============================================================================


{-| A pattern that does not cover its type where there is no `case` to add a
branch to: in a `let` destructuring, in a function argument and in a lambda
argument.
-}
unsafeCases : List RejectedCase
unsafeCases =
    [ fromSource "a let destructuring that can fail"
        (rejectedWithFragment "UNSAFE PATTERN" "Nothing")
        """
testValue =
    let
        (Just v) =
            Just 1
    in
    v
"""
    , fromSource "a function argument that can fail"
        (rejectedWithFragment "UNSAFE PATTERN" "Nothing")
        """
unwrap (Just v) =
    v


testValue =
    unwrap (Just 1)
"""
    , fromSource "a lambda argument that can fail"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    (\\(x :: _) -> x) [ 1 ]
"""
    ]



-- ============================================================================
-- UNSAFE PATTERNS FROM THE STANDARD CATALOGUE
-- ============================================================================


{-| The programs that cases of the standard catalogue held before they were
made valid: a list or literal pattern in a function argument, a lambda
argument, the argument of a `let`-bound function or a `let` destructuring.
Each case is labelled with the label and module of the catalogue case it came
from, which now matches the pattern in a `case`. The fragment of a list
pattern is `[]`, a list it misses; a literal pattern's report is recorded by
its title only.
-}
catalogueUnsafeCases : List RejectedCase
catalogueUnsafeCases =
    [ fromSource "Cons pattern (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
head (h :: t) =
    h


testValue =
    head [ 1, 2 ]
"""
    , fromSource "Fixed list pattern (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
firstTwo [ a, b ] =
    ( a, b )


testValue =
    firstTwo [ 1, 2 ]
"""
    , fromSource "Nested cons pattern (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
secondElem (_ :: x :: _) =
    x


testValue =
    secondElem [ 1, 2, 3 ]
"""
    , fromSource "List pattern in lambda (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    \\(x :: _) -> x
"""
    , fromSource "Int literal pattern (PatternArgCases)"
        (rejectedWith "UNSAFE PATTERN")
        """
isZero 0 =
    "zero"


testValue =
    isZero 0
"""
    , fromSource "String literal pattern (PatternArgCases)"
        (rejectedWith "UNSAFE PATTERN")
        """
greet "hello" =
    "hi"


testValue =
    greet "hello"
"""
    , fromSource "Multiple literal patterns (PatternArgCases)"
        (rejectedWith "UNSAFE PATTERN")
        """
match 0 "" =
    0


testValue =
    match 0 ""
"""
    , fromSource "Mixed nested patterns (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
mixed ( { x }, h :: _ ) =
    ( x, h )


testValue =
    mixed ( { x = 1 }, [ "hello", "world" ] )
"""
    , fromSource "Triple nested patterns (PatternArgCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
complex ( ( a, b ), { x, y }, h :: t ) =
    a


testValue =
    complex ( ( 1, "hello" ), { x = 3.14, y = 2 }, [ 3, 4 ] )
"""
    , fromSource "Alias on cons pattern (AsPatternCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
withList ((h :: t) as list) =
    ( list, h )


testValue =
    withList [ 1, 2 ]
"""
    , fromSource "Alias on fixed list pattern (AsPatternCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
pairList ([ a, b ] as both) =
    both


testValue =
    pairList [ 1, 2 ]
"""
    , fromSource "Nested alias in list (AsPatternCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
parts ((h as head) :: (t as tail)) =
    ( head, tail )


testValue =
    parts [ 1, 2 ]
"""
    , fromSource "Alias on nested cons (AsPatternCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
twoOrMore ((a :: b :: rest) as list) =
    list


testValue =
    twoOrMore [ 1, 2, 3 ]
"""
    , fromSource "Mixed nested aliases (AsPatternCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
mixed (( { x }, (h :: _) as list ) as all) =
    all


testValue =
    mixed ( { x = 1 }, [ 1, 2 ] )
"""
    , fromSource "Destruct cons pattern (LetDestructCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        (head :: tail) =
            [ 1, 2, 3 ]
    in
    head
"""
    , fromSource "Destruct fixed list pattern (LetDestructCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        [ a, b ] =
            [ 1, 2 ]
    in
    ( a, b )
"""
    , fromSource "Destruct nested cons (LetDestructCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        (a :: b :: rest) =
            [ 1, 2, 3 ]
    in
    ( a, b )
"""
    , fromSource "Multiple pattern types in one function (EdgeCaseCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        complex a ( b, c ) { d, e } (f :: _) (g as h) =
            [ a, b, d, f, g ]
    in
    complex
"""
    , fromSource "All destruct patterns (EdgeCaseCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        ( a, b ) =
            ( 1, 2 )

        { x } =
            { x = 3 }

        (h :: t) =
            [ 4, 5 ]

        (v as w) =
            6
    in
    [ a, x, h, v ]
"""
    , fromSource "Definitions with list patterns (MultiDefCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
f [ a ] =
    a


g [ x, y ] =
    x + y


testValue =
    ( f [ 1 ], g [ 2, 3 ] )
"""
    , fromSource "Higher-order with list pattern (HigherOrderCases)"
        (rejectedWithFragment "UNSAFE PATTERN" "[]")
        """
testValue =
    let
        mapHead f (h :: t) =
            [ f h ]
    in
    mapHead (\\x -> x) [ 1, 2 ]
"""
    ]
