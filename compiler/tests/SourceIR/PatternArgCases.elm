module SourceIR.PatternArgCases exposing (expectSuite)

{-| Supplies programs whose function arguments are patterns of each shape
listed below, so that a stage's checks are run on arguments of each shape.

An Elm function argument can be any pattern: a wildcard, a tuple, a record, a
list, a literal, a constructor, or one of these nested in another. A stage that
handles a function has to bind the names inside such a pattern, and it can get
one shape right and another wrong. This module builds small programs, several
per shape, and asserts nothing itself. `expectSuite` makes one elm-test test,
in which `Compiler.BulkCheck.bulkCheck` runs the programs in order through the
caller's expectation. The first program that fails ends the test and is
reported under its label, and the programs after it are not checked.

Every program is a module named `Test` that defines `testValue`. Most declare
one unannotated top-level function with `makeModuleWithDefs`, which imports
only `Basics` and `List`, and make `testValue` an unannotated call of it.
The four "in lambda" cases instead make `testValue` itself a one-argument
lambda, with `makeModule`, and never apply it. The two custom-type cases declare
a type with one constructor, annotate every definition, and use
`makeModuleWithTypedDefsUnionsAliases`, which imports `Basics`, `Maybe`,
`List`, `Elm.JsArray as JsArray`, `String` and `Char`.

In nine of the programs an argument pattern, such as `h :: t`, `[ a, b ]`,
`0` or `"hello"`, does not match every value of its type, and
`Compiler.Nitpick.PatternMatches` reports such an argument as an incomplete
pattern. These are the cases labelled "Cons pattern", "Fixed list pattern",
"Nested cons pattern", "List pattern in lambda", "Int literal pattern", "String
literal pattern", "Multiple literal patterns", "Mixed nested patterns" and
"Triple nested patterns". An expectation that runs the pattern checker rejects
them.

The programs, group by group, in the order they run:

  - Variable patterns: `identity x = x`, a two-argument and a three-argument
    function that each return one argument, `swap x y = ( y, x )`, and
    `toList x = [ x ]`.
  - Wildcard patterns: `const _ = 42`, `const x _ = x`, a function of three
    `_` arguments, and the lambda `\_ -> 0`.
  - Tuple patterns: a pair, a triple, a pair with a `_` element, a pair nested
    in a pair, the lambda `\( x, y ) -> x`, and a function of two pairs.
  - Record patterns: `{ x }`, `{ x, y }`, the lambda `\{ name } -> name`, a
    five-field pattern, a function of two records, and a record followed by a
    plain name.
  - List patterns: `h :: t`, `[ a, b ]`, `_ :: x :: _`, and the lambda
    `\(x :: _) -> x`.
  - Literal patterns: `0`, `"hello"`, `()`, and `0` followed by `""`. Of
    these only `()` matches every value of its type.
  - Nested patterns: a pair of pairs; a pair of `{ x }` and `h :: _`; a triple
    of a pair, `{ x, y }` and `h :: t`; and a pair of pairs with `_` in
    opposite corners.
  - Multi-argument patterns: five arguments mixing names, a pair, a record and
    `_`; three pairs; and names alternating with `_`.
  - Custom type patterns: `getId (Person id _)` and `getAge (Person _ age)` on
    `type Person = Person Int Int`, and `unbox (Box x)` on `type Box = Box Int`.
    `Box` has one constructor with one argument, the shape that
    `Compiler.Canonicalize.Environment.Local` gives the `Unbox` representation;
    `Person` has two arguments and does not get it.

Among what is not tested: `as` patterns, character patterns, a constructor of
a type with more than one constructor, a type with type parameters, and the
arguments of `let`-bound functions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , ctorExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pStr
        , pTuple
        , pTuple3
        , pUnit
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tuple3Expr
        , tupleExpr
        , unitExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Pattern argument tests " followed by `condStr`,
that passes when `expectFn` passes on every program in this module and
otherwise fails under the label of the first program it fails on, as
`Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Pattern argument tests " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case of this module, group by group in the order the module
docstring lists them, each applying `expectFn` to its own program.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    variablePatternCases expectFn
        ++ wildcardPatternCases expectFn
        ++ tuplePatternCases expectFn
        ++ recordPatternCases expectFn
        ++ listPatternCases expectFn
        ++ literalPatternCases expectFn
        ++ nestedPatternCases expectFn
        ++ multiArgPatternCases expectFn
        ++ customTypePatternCases expectFn



-- ============================================================================
-- VARIABLE PATTERNS
-- ============================================================================


{-| Returns the labelled variable-pattern cases for `expectFn`.
-}
variablePatternCases : (Src.Module -> Expectation) -> List TestCase
variablePatternCases expectFn =
    [ { label = "Single variable pattern", run = singleVariablePattern expectFn }
    , { label = "Two variable patterns", run = twoVariablePatterns expectFn }
    , { label = "Three variable patterns", run = threeVariablePatterns expectFn }
    , { label = "Variable pattern returning tuple", run = variablePatternReturningTuple expectFn }
    , { label = "Variable pattern returning list", run = variablePatternReturningList expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `identity x = x` and
`testValue = identity 1`.
-}
singleVariablePattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleVariablePattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "identity", [ pVar "x" ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "identity") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `first x y = x` and
`testValue = first 1 "hello"`.
-}
twoVariablePatterns : (Src.Module -> Expectation) -> (() -> Expectation)
twoVariablePatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "first", [ pVar "x", pVar "y" ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "first") [ intExpr 1, strExpr "hello" ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `second a b c = b` and
`testValue = second 1 "hello" 3.14`.
-}
threeVariablePatterns : (Src.Module -> Expectation) -> (() -> Expectation)
threeVariablePatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "second", [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                , ( "testValue", [], callExpr (varExpr "second") [ intExpr 1, strExpr "hello", floatExpr 3.14 ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `swap x y = ( y, x )` and
`testValue = swap 1 "hello"`.
-}
variablePatternReturningTuple : (Src.Module -> Expectation) -> (() -> Expectation)
variablePatternReturningTuple expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "swap", [ pVar "x", pVar "y" ], tupleExpr (varExpr "y") (varExpr "x") )
                , ( "testValue", [], callExpr (varExpr "swap") [ intExpr 1, strExpr "hello" ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `toList x = [ x ]` and
`testValue = toList 1`.
-}
variablePatternReturningList : (Src.Module -> Expectation) -> (() -> Expectation)
variablePatternReturningList expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "toList", [ pVar "x" ], listExpr [ varExpr "x" ] )
                , ( "testValue", [], callExpr (varExpr "toList") [ intExpr 1 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- WILDCARD PATTERNS
-- ============================================================================


{-| Returns the labelled wildcard-pattern cases for `expectFn`.
-}
wildcardPatternCases : (Src.Module -> Expectation) -> List TestCase
wildcardPatternCases expectFn =
    [ { label = "Single wildcard pattern", run = singleWildcardPattern expectFn }
    , { label = "Wildcard with variable", run = wildcardWithVariable expectFn }
    , { label = "Multiple wildcards", run = multipleWildcards expectFn }
    , { label = "Wildcard in lambda", run = wildcardInLambda expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `const _ = 42` and
`testValue = const 1`.
-}
singleWildcardPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleWildcardPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "const", [ pAnything ], intExpr 42 )
                , ( "testValue", [], callExpr (varExpr "const") [ intExpr 1 ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `const x _ = x` and
`testValue = const 1 "hello"`.
-}
wildcardWithVariable : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardWithVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "const", [ pVar "x", pAnything ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "const") [ intExpr 1, strExpr "hello" ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `zero _ _ _ = 0` and
`testValue = zero 1 "hello" 3.14`.
-}
multipleWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
multipleWildcards expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "zero", [ pAnything, pAnything, pAnything ], intExpr 0 )
                , ( "testValue", [], callExpr (varExpr "zero") [ intExpr 1, strExpr "hello", floatExpr 3.14 ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module whose one value is
`testValue = \_ -> 0`.
-}
wildcardInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
wildcardInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pAnything ] (intExpr 0)

        modul =
            makeModule "testValue" fn
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERNS
-- ============================================================================


{-| Returns the labelled tuple-pattern cases for `expectFn`.
-}
tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "2-tuple pattern", run = tuple2Pattern expectFn }
    , { label = "3-tuple pattern", run = tuple3Pattern expectFn }
    , { label = "Tuple pattern with wildcard", run = tuplePatternWithWildcard expectFn }
    , { label = "Nested tuple pattern", run = nestedTuplePattern expectFn }
    , { label = "Tuple pattern in lambda", run = tuplePatternInLambda expectFn }
    , { label = "Multiple tuple pattern args", run = multipleTuplePatternArgs expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `fst ( x, y ) = x` and
`testValue = fst ( 1, "hello" )`.
-}
tuple2Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple2Pattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "fst", [ pTuple (pVar "x") (pVar "y") ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "fst") [ tupleExpr (intExpr 1) (strExpr "hello") ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `snd3 ( a, b, c ) = b` and
`testValue = snd3 ( 1, "hello", 3.14 )`.
-}
tuple3Pattern : (Src.Module -> Expectation) -> (() -> Expectation)
tuple3Pattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "snd3", [ pTuple3 (pVar "a") (pVar "b") (pVar "c") ], varExpr "b" )
                , ( "testValue", [], callExpr (varExpr "snd3") [ tuple3Expr (intExpr 1) (strExpr "hello") (floatExpr 3.14) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `snd ( _, y ) = y` and
`testValue = snd ( 1, "hello" )`.
-}
tuplePatternWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternWithWildcard expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "snd", [ pTuple pAnything (pVar "y") ], varExpr "y" )
                , ( "testValue", [], callExpr (varExpr "snd") [ tupleExpr (intExpr 1) (strExpr "hello") ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `deep ( ( a, b ), c ) = a`
and `testValue = deep ( ( 1, "hello" ), 3.14 )`.
-}
nestedTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedTuplePattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "deep", [ pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c") ], varExpr "a" )
                , ( "testValue", [], callExpr (varExpr "deep") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "hello")) (floatExpr 3.14) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module whose one value is
`testValue = \( x, y ) -> x`.
-}
tuplePatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
tuplePatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pTuple (pVar "x") (pVar "y") ] (varExpr "x")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`addPairs ( a, b ) ( c, d ) = ( a, c )` and
`testValue = addPairs ( 1, "hello" ) ( 3.14, 2 )`.
-}
multipleTuplePatternArgs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleTuplePatternArgs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "addPairs"
                  , [ pTuple (pVar "a") (pVar "b"), pTuple (pVar "c") (pVar "d") ]
                  , tupleExpr (varExpr "a") (varExpr "c")
                  )
                , ( "testValue", [], callExpr (varExpr "addPairs") [ tupleExpr (intExpr 1) (strExpr "hello"), tupleExpr (floatExpr 3.14) (intExpr 2) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- RECORD PATTERNS
-- ============================================================================


{-| Returns the labelled record-pattern cases for `expectFn`.
-}
recordPatternCases : (Src.Module -> Expectation) -> List TestCase
recordPatternCases expectFn =
    [ { label = "Single field record pattern", run = singleFieldRecordPattern expectFn }
    , { label = "Multi-field record pattern", run = multiFieldRecordPattern expectFn }
    , { label = "Record pattern in lambda", run = recordPatternInLambda expectFn }
    , { label = "Record pattern with many fields", run = recordPatternWithManyFields expectFn }
    , { label = "Multiple record pattern args", run = multipleRecordPatternArgs expectFn }
    , { label = "Record pattern with variable", run = recordPatternWithVariable expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `getX { x } = x` and
`testValue = getX { x = 1 }`.
-}
singleFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
singleFieldRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getX", [ pRecord [ "x" ] ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "getX") [ recordExpr [ ( "x", intExpr 1 ) ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`getXY { x, y } = ( x, y )` and `testValue = getXY { x = 1, y = "hello" }`.
-}
multiFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
multiFieldRecordPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getXY", [ pRecord [ "x", "y" ] ], tupleExpr (varExpr "x") (varExpr "y") )
                , ( "testValue", [], callExpr (varExpr "getXY") [ recordExpr [ ( "x", intExpr 1 ), ( "y", strExpr "hello" ) ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module whose one value is
`testValue = \{ name } -> name`.
-}
recordPatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pRecord [ "name" ] ] (varExpr "name")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`getAll { a, b, c, d, e } = a` and
`testValue = getAll { a = 1, b = 2, c = 3, d = 4, e = 5 }`.
-}
recordPatternWithManyFields : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternWithManyFields expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "getAll", [ pRecord [ "a", "b", "c", "d", "e" ] ], varExpr "a" )
                , ( "testValue", [], callExpr (varExpr "getAll") [ recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ), ( "d", intExpr 4 ), ( "e", intExpr 5 ) ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`combine { x } { y } = ( x, y )` and
`testValue = combine { x = 1 } { y = "hello" }`.
-}
multipleRecordPatternArgs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordPatternArgs expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "combine"
                  , [ pRecord [ "x" ], pRecord [ "y" ] ]
                  , tupleExpr (varExpr "x") (varExpr "y")
                  )
                , ( "testValue", [], callExpr (varExpr "combine") [ recordExpr [ ( "x", intExpr 1 ) ], recordExpr [ ( "y", strExpr "hello" ) ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`extract { value } default = value` and
`testValue = extract { value = 1 } "default"`.
-}
recordPatternWithVariable : (Src.Module -> Expectation) -> (() -> Expectation)
recordPatternWithVariable expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "extract", [ pRecord [ "value" ], pVar "default" ], varExpr "value" )
                , ( "testValue", [], callExpr (varExpr "extract") [ recordExpr [ ( "value", intExpr 1 ) ], strExpr "default" ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERNS
-- ============================================================================


{-| Returns the labelled list-pattern cases for `expectFn`.
-}
listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Cons pattern", run = consPattern expectFn }
    , { label = "Fixed list pattern", run = fixedListPattern expectFn }
    , { label = "Nested cons pattern", run = nestedConsPattern expectFn }
    , { label = "List pattern in lambda", run = listPatternInLambda expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `head (h :: t) = h` and
`testValue = head [ 1, 2 ]`. The argument pattern does not match `[]`.
-}
consPattern : (Src.Module -> Expectation) -> (() -> Expectation)
consPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "head", [ pCons (pVar "h") (pVar "t") ], varExpr "h" )
                , ( "testValue", [], callExpr (varExpr "head") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`firstTwo [ a, b ] = ( a, b )` and `testValue = firstTwo [ 1, 2 ]`. The
argument pattern matches only a list of exactly two elements.
-}
fixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
fixedListPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "firstTwo", [ pList [ pVar "a", pVar "b" ] ], tupleExpr (varExpr "a") (varExpr "b") )
                , ( "testValue", [], callExpr (varExpr "firstTwo") [ listExpr [ intExpr 1, intExpr 2 ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`secondElem (_ :: x :: _) = x` and `testValue = secondElem [ 1, 2, 3 ]`. The
argument pattern does not match a list shorter than two.
-}
nestedConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
nestedConsPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "secondElem", [ pCons pAnything (pCons (pVar "x") pAnything) ], varExpr "x" )
                , ( "testValue", [], callExpr (varExpr "secondElem") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module whose one value is
`testValue = \(x :: _) -> x`. The argument pattern does not match `[]`.
-}
listPatternInLambda : (Src.Module -> Expectation) -> (() -> Expectation)
listPatternInLambda expectFn _ =
    let
        fn =
            lambdaExpr [ pCons (pVar "x") pAnything ] (varExpr "x")

        modul =
            makeModule "testValue" fn
    in
    expectFn modul



-- ============================================================================
-- LITERAL PATTERNS
-- ============================================================================


{-| Returns the labelled literal-pattern cases for `expectFn`.
-}
literalPatternCases : (Src.Module -> Expectation) -> List TestCase
literalPatternCases expectFn =
    [ { label = "Int literal pattern", run = intLiteralPattern expectFn }
    , { label = "String literal pattern", run = stringLiteralPattern expectFn }
    , { label = "Unit pattern", run = unitPattern expectFn }
    , { label = "Multiple literal patterns", run = multipleLiteralPatterns expectFn }
    ]


{-| Returns `expectFn` applied to a module defining `isZero 0 = "zero"` and
`testValue = isZero 0`. The argument pattern matches only `0`.
-}
intLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
intLiteralPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "isZero", [ pInt 0 ], strExpr "zero" )
                , ( "testValue", [], callExpr (varExpr "isZero") [ intExpr 0 ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `greet "hello" = "hi"`
and `testValue = greet "hello"`. The argument pattern matches only
`"hello"`.
-}
stringLiteralPattern : (Src.Module -> Expectation) -> (() -> Expectation)
stringLiteralPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "greet", [ pStr "hello" ], strExpr "hi" )
                , ( "testValue", [], callExpr (varExpr "greet") [ strExpr "hello" ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `unit () = 0` and
`testValue = unit ()`.
-}
unitPattern : (Src.Module -> Expectation) -> (() -> Expectation)
unitPattern expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "unit", [ pUnit ], intExpr 0 )
                , ( "testValue", [], callExpr (varExpr "unit") [ unitExpr ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining `match 0 "" = 0` and
`testValue = match 0 ""`. Both argument patterns match only one value.
-}
multipleLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
multipleLiteralPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "match", [ pInt 0, pStr "" ], intExpr 0 )
                , ( "testValue", [], callExpr (varExpr "match") [ intExpr 0, strExpr "" ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- NESTED PATTERNS
-- ============================================================================


{-| Returns the labelled nested-pattern cases for `expectFn`.
-}
nestedPatternCases : (Src.Module -> Expectation) -> List TestCase
nestedPatternCases expectFn =
    [ { label = "Deeply nested tuple", run = deeplyNestedTuplePattern expectFn }
    , { label = "Mixed nested patterns", run = mixedNestedPatterns expectFn }
    , { label = "Triple nested patterns", run = tripleNestedPatterns expectFn }
    , { label = "Nested with wildcards", run = nestedWithWildcards expectFn }
    ]


{-| Returns `expectFn` applied to a module defining
`extract ( ( a, b ), ( c, d ) ) = a` and
`testValue = extract ( ( 1, "hello" ), ( 3.14, 2 ) )`.
-}
deeplyNestedTuplePattern : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedTuplePattern expectFn _ =
    let
        pattern =
            pTuple
                (pTuple (pVar "a") (pVar "b"))
                (pTuple (pVar "c") (pVar "d"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "extract", [ pattern ], varExpr "a" )
                , ( "testValue", [], callExpr (varExpr "extract") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "hello")) (tupleExpr (floatExpr 3.14) (intExpr 2)) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`mixed ( { x }, h :: _ ) = ( x, h )` and
`testValue = mixed ( { x = 1 }, [ "hello", "world" ] )`. The argument
pattern does not match a pair whose list is empty.
-}
mixedNestedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
mixedNestedPatterns expectFn _ =
    let
        pattern =
            pTuple (pRecord [ "x" ]) (pCons (pVar "h") pAnything)

        modul =
            makeModuleWithDefs "Test"
                [ ( "mixed", [ pattern ], tupleExpr (varExpr "x") (varExpr "h") )
                , ( "testValue", [], callExpr (varExpr "mixed") [ tupleExpr (recordExpr [ ( "x", intExpr 1 ) ]) (listExpr [ strExpr "hello", strExpr "world" ]) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`complex ( ( a, b ), { x, y }, h :: t ) = a` and
`testValue = complex ( ( 1, "hello" ), { x = 3.14, y = 2 }, [ 3, 4 ] )`.
The argument pattern does not match a triple whose list is empty.
-}
tripleNestedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedPatterns expectFn _ =
    let
        pattern =
            pTuple3
                (pTuple (pVar "a") (pVar "b"))
                (pRecord [ "x", "y" ])
                (pCons (pVar "h") (pVar "t"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "complex", [ pattern ], varExpr "a" )
                , ( "testValue", [], callExpr (varExpr "complex") [ tuple3Expr (tupleExpr (intExpr 1) (strExpr "hello")) (recordExpr [ ( "x", floatExpr 3.14 ), ( "y", intExpr 2 ) ]) (listExpr [ intExpr 3, intExpr 4 ]) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`corners ( ( x, _ ), ( _, y ) ) = ( x, y )` and
`testValue = corners ( ( 1, "hello" ), ( 3.14, 2 ) )`.
-}
nestedWithWildcards : (Src.Module -> Expectation) -> (() -> Expectation)
nestedWithWildcards expectFn _ =
    let
        pattern =
            pTuple
                (pTuple (pVar "x") pAnything)
                (pTuple pAnything (pVar "y"))

        modul =
            makeModuleWithDefs "Test"
                [ ( "corners", [ pattern ], tupleExpr (varExpr "x") (varExpr "y") )
                , ( "testValue", [], callExpr (varExpr "corners") [ tupleExpr (tupleExpr (intExpr 1) (strExpr "hello")) (tupleExpr (floatExpr 3.14) (intExpr 2)) ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- MULTI-ARG PATTERNS
-- ============================================================================


{-| Returns the labelled multi-argument cases for `expectFn`.
-}
multiArgPatternCases : (Src.Module -> Expectation) -> List TestCase
multiArgPatternCases expectFn =
    [ { label = "Five args with mixed patterns", run = fiveArgsWithMixedPatterns expectFn }
    , { label = "All same pattern type", run = allSamePatternType expectFn }
    , { label = "Alternating patterns", run = alternatingPatterns expectFn }
    ]


{-| Returns `expectFn` applied to a module defining
`fiveArgs a ( b, c ) { d } _ e = a` and
`testValue = fiveArgs 1 ( "hello", 3.14 ) { d = 2 } 3 "world"`.
-}
fiveArgsWithMixedPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
fiveArgsWithMixedPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "fiveArgs"
                  , [ pVar "a", pTuple (pVar "b") (pVar "c"), pRecord [ "d" ], pAnything, pVar "e" ]
                  , varExpr "a"
                  )
                , ( "testValue", [], callExpr (varExpr "fiveArgs") [ intExpr 1, tupleExpr (strExpr "hello") (floatExpr 3.14), recordExpr [ ( "d", intExpr 2 ) ], intExpr 3, strExpr "world" ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`allTuples ( a, b ) ( c, d ) ( e, f ) = a` and
`testValue = allTuples ( 1, "hello" ) ( 3.14, 2 ) ( "world", 3 )`.
-}
allSamePatternType : (Src.Module -> Expectation) -> (() -> Expectation)
allSamePatternType expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "allTuples"
                  , [ pTuple (pVar "a") (pVar "b")
                    , pTuple (pVar "c") (pVar "d")
                    , pTuple (pVar "e") (pVar "f")
                    ]
                  , varExpr "a"
                  )
                , ( "testValue", [], callExpr (varExpr "allTuples") [ tupleExpr (intExpr 1) (strExpr "hello"), tupleExpr (floatExpr 3.14) (intExpr 2), tupleExpr (strExpr "world") (intExpr 3) ] )
                ]
    in
    expectFn modul


{-| Returns `expectFn` applied to a module defining
`alternate a _ b _ c = [ a, b, c ]` and
`testValue = alternate 1 "hello" 2 3.14 3`.
-}
alternatingPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
alternatingPatterns expectFn _ =
    let
        modul =
            makeModuleWithDefs "Test"
                [ ( "alternate"
                  , [ pVar "a", pAnything, pVar "b", pAnything, pVar "c" ]
                  , listExpr [ varExpr "a", varExpr "b", varExpr "c" ]
                  )
                , ( "testValue", [], callExpr (varExpr "alternate") [ intExpr 1, strExpr "hello", intExpr 2, floatExpr 3.14, intExpr 3 ] )
                ]
    in
    expectFn modul



-- ============================================================================
-- CUSTOM TYPE PATTERNS
-- ============================================================================


{-| Returns the labelled custom-type cases for `expectFn`.
-}
customTypePatternCases : (Src.Module -> Expectation) -> List TestCase
customTypePatternCases expectFn =
    [ { label = "Custom type pattern in function argument", run = customTypePatternInFunctionArg expectFn }
    , { label = "Custom type pattern with multiple extractors", run = customTypePatternMultipleExtractors expectFn }
    ]


{-| Returns `expectFn` applied to a module containing

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

-}
customTypePatternInFunctionArg : (Src.Module -> Expectation) -> (() -> Expectation)
customTypePatternInFunctionArg expectFn _ =
    let
        personUnion : UnionDef
        personUnion =
            { name = "Person"
            , args = []
            , ctors =
                [ { name = "Person", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        getIdFn : TypedDef
        getIdFn =
            { name = "getId"
            , args = [ pCtor "Person" [ pVar "id", pAnything ] ]
            , tipe = tLambda (tType "Person" []) (tType "Int" [])
            , body = varExpr "id"
            }

        getAgeFn : TypedDef
        getAgeFn =
            { name = "getAge"
            , args = [ pCtor "Person" [ pAnything, pVar "age" ] ]
            , tipe = tLambda (tType "Person" []) (tType "Int" [])
            , body = varExpr "age"
            }

        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                tupleExpr
                    (callExpr (varExpr "getId") [ callExpr (ctorExpr "Person") [ intExpr 30, intExpr 25 ] ])
                    (callExpr (varExpr "getAge") [ callExpr (ctorExpr "Person") [ intExpr 30, intExpr 25 ] ])
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getIdFn, getAgeFn, testValueFn ] [ personUnion ] []
    in
    expectFn modul


{-| Returns `expectFn` applied to a module containing

    type Box
        = Box Int

    unbox : Box -> Int
    unbox (Box x) =
        x

    testValue : Int
    testValue =
        unbox (Box 42)

-}
customTypePatternMultipleExtractors : (Src.Module -> Expectation) -> (() -> Expectation)
customTypePatternMultipleExtractors expectFn _ =
    let
        boxUnion : UnionDef
        boxUnion =
            { name = "Box"
            , args = []
            , ctors =
                [ { name = "Box", args = [ tType "Int" [] ] }
                ]
            }

        unboxFn : TypedDef
        unboxFn =
            { name = "unbox"
            , args = [ pCtor "Box" [ pVar "x" ] ]
            , tipe = tLambda (tType "Box" []) (tType "Int" [])
            , body = varExpr "x"
            }

        testValueFn : TypedDef
        testValueFn =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unbox") [ callExpr (ctorExpr "Box") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ unboxFn, testValueFn ] [ boxUnion ] []
    in
    expectFn modul
