module SourceIR.LiteralCases exposing (expectSuite)

{-| A catalogue of minimal programs, each a module whose one value is a single
literal, or `True` or `False`. It exists to run a caller's check against each
of these forms on its own, in a program that holds nothing else.

This module checks nothing itself. `expectSuite` takes an expectation function
and applies it to each program, so what is established depends entirely on the
function passed in.

Every program is built with `Compiler.AST.SourceBuilder.makeModule`: a module
named `Test` that imports `Basics` and `List` and defines one value,
`testValue`, with no arguments and no annotation. The cases differ only in
`testValue`'s body:

  - `Int` literals `0`, `42` and `-42`.
  - `Float` literals `0` (built from `0.0`), `0.001` and `-3.14`.
  - String literals: the empty string; `hello\nworld\ttab`, whose text holds
    the two-character escapes `\n` and `\t` as they are written in source;
    and `hello 世界`, which holds two non-ASCII characters.
  - The `Char` literal `a`.
  - The unit value `()`.
  - `True` and `False`, each a reference to the constructor `Basics.True` or
    `Basics.False` rather than a literal.

The negative numbers are built directly as negative literals. The parser never
produces one: it reads `-42` as a negation applied to the literal `42`.

Among what is not tested: character escapes and non-ASCII characters in a
`Char`, multi-line strings, hexadecimal integers, floats written with an
exponent, and literals anywhere other than as the whole body of a top-level
value.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( boolExpr
        , chrExpr
        , floatExpr
        , intExpr
        , makeModule
        , strExpr
        , unitExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Literal expressions "` followed by `condStr`,
that passes when `expectFn` passes for every program in this module.

The cases run as one `Compiler.BulkCheck.bulkCheck`, so a failure names only
the first failing case, and the cases after it do not run.

-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Literal expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each checked by `expectFn`: the `Int` cases, then
`Float`, string, `Char`, unit and `Bool`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ intLiteralCases expectFn
        , floatLiteralCases expectFn
        , stringLiteralCases expectFn
        , charLiteralCases expectFn
        , unitCases expectFn
        , boolCases expectFn
        ]



-- ============================================================================
-- INT LITERALS
-- ============================================================================


{-| Returns the three `Int` literal cases, checked by `expectFn`.
-}
intLiteralCases : (Src.Module -> Expectation) -> List TestCase
intLiteralCases expectFn =
    [ { label = "Zero", run = zeroInt expectFn }
    , { label = "Positive int", run = positiveInt expectFn }
    , { label = "Negative int", run = negativeInt expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is the `Int` literal
`0`.
-}
zeroInt : (Src.Module -> Expectation) -> (() -> Expectation)
zeroInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 0)
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is the `Int` literal
`42`.
-}
positiveInt : (Src.Module -> Expectation) -> (() -> Expectation)
positiveInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr 42)
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is a single negative
`Int` literal, `-42`, rather than a negation of `42`.
-}
negativeInt : (Src.Module -> Expectation) -> (() -> Expectation)
negativeInt expectFn _ =
    let
        modul =
            makeModule "testValue" (intExpr -42)
    in
    expectFn modul



-- ============================================================================
-- FLOAT LITERALS
-- ============================================================================


{-| Returns the three `Float` literal cases, checked by `expectFn`.
-}
floatLiteralCases : (Src.Module -> Expectation) -> List TestCase
floatLiteralCases expectFn =
    [ { label = "Zero float", run = zeroFloat expectFn }
    , { label = "Small positive float", run = smallPositiveFloat expectFn }
    , { label = "Negative float", run = negativeFloat expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is the `Float` literal
zero, whose source text is `0` with no decimal point.
-}
zeroFloat : (Src.Module -> Expectation) -> (() -> Expectation)
zeroFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 0.0)
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is the `Float` literal
`0.001`.
-}
smallPositiveFloat : (Src.Module -> Expectation) -> (() -> Expectation)
smallPositiveFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr 0.001)
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is a single negative
`Float` literal, `-3.14`, rather than a negation of `3.14`.
-}
negativeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
negativeFloat expectFn _ =
    let
        modul =
            makeModule "testValue" (floatExpr -3.14)
    in
    expectFn modul



-- ============================================================================
-- STRING LITERALS
-- ============================================================================


{-| Returns the three string literal cases, checked by `expectFn`.
-}
stringLiteralCases : (Src.Module -> Expectation) -> List TestCase
stringLiteralCases expectFn =
    [ { label = "Empty string", run = emptyString expectFn }
    , { label = "String with escapes", run = stringWithEscapes expectFn }
    , { label = "Unicode string", run = unicodeString expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is the empty string.
-}
emptyString : (Src.Module -> Expectation) -> (() -> Expectation)
emptyString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "")
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is a string literal
holding the escapes `\n` and `\t`, each kept as a backslash and a letter, as
the parser keeps them.
-}
stringWithEscapes : (Src.Module -> Expectation) -> (() -> Expectation)
stringWithEscapes expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello\\nworld\\ttab")
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is the string
`hello 世界`, which ends in two non-ASCII characters.
-}
unicodeString : (Src.Module -> Expectation) -> (() -> Expectation)
unicodeString expectFn _ =
    let
        modul =
            makeModule "testValue" (strExpr "hello 世界")
    in
    expectFn modul



-- ============================================================================
-- CHAR LITERALS
-- ============================================================================


{-| Returns the one `Char` literal case, checked by `expectFn`.
-}
charLiteralCases : (Src.Module -> Expectation) -> List TestCase
charLiteralCases expectFn =
    [ { label = "Letter char", run = letterChar expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is the `Char` literal
`'a'`.
-}
letterChar : (Src.Module -> Expectation) -> (() -> Expectation)
letterChar expectFn _ =
    let
        modul =
            makeModule "testValue" (chrExpr "a")
    in
    expectFn modul



-- ============================================================================
-- UNIT
-- ============================================================================


{-| Returns the one unit case, checked by `expectFn`.
-}
unitCases : (Src.Module -> Expectation) -> List TestCase
unitCases expectFn =
    [ { label = "Unit expression", run = unitExpression expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is `()`.
-}
unitExpression : (Src.Module -> Expectation) -> (() -> Expectation)
unitExpression expectFn _ =
    let
        modul =
            makeModule "testValue" unitExpr
    in
    expectFn modul



-- ============================================================================
-- BOOL
-- ============================================================================


{-| Returns the `True` and `False` cases, checked by `expectFn`.
-}
boolCases : (Src.Module -> Expectation) -> List TestCase
boolCases expectFn =
    [ { label = "True", run = trueExpr expectFn }
    , { label = "False", run = falseExpr expectFn }
    ]


{-| Applies `expectFn` to the program whose `testValue` is `Basics.True`.
-}
trueExpr : (Src.Module -> Expectation) -> (() -> Expectation)
trueExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr True)
    in
    expectFn modul


{-| Applies `expectFn` to the program whose `testValue` is `Basics.False`.
-}
falseExpr : (Src.Module -> Expectation) -> (() -> Expectation)
falseExpr expectFn _ =
    let
        modul =
            makeModule "testValue" (boolExpr False)
    in
    expectFn modul
