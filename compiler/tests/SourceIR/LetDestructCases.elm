module SourceIR.LetDestructCases exposing (expectSuite)

{-| Source programs whose `let` binds names by destructuring a value, so that a
compiler stage can be checked on a `let` definition that is a pattern (a
`Src.Destruct`) rather than a name.

This module asserts nothing itself. `expectSuite` applies the caller's
expectation function to each program, so what is checked, and at which stage,
is decided by the caller.

Each program is built with `makeModule`: a module named `Test` that imports
`Basics` and `List`, whose one top-level value, `testValue`, is a `let`. The
`let` (in one complex case, a `let` nested in its body) destructures one or more
values and its body uses some of the names they bind. Every literal in these
programs is an `Int`. The cases fall into six groups:

  - Tuples: a pair and a triple destructured into variables, a pair with `_`
    in second position, and two pair destructures in one `let`.
  - Records: record patterns taking the one field of a record, both fields of
    a two-field record, two fields of a three-field record, and two
    single-field destructures in one `let`.
  - Lists: `head :: tail` on a three-element list, `[ a, b ]` on a
    two-element list, and `a :: b :: rest` on a three-element list.
  - Nested: a pair of pairs, a pair of a record and an `Int`, a pair whose
    first element is a pair holding a pair, and a triple of pairs.
  - Aliases: `as` naming a whole pair, and `as` naming the inner pair of a
    pair.
  - Complex: a destructure between two plain definitions; a destructure in a
    `let` that is the body of an outer `let` defining the pair it matches; a
    destructure of a name bound by an earlier destructure in the same `let`;
    and a destructure of a call to a `let`-defined value.

Not every program is valid Elm. The three list patterns do not match every
list, and the pattern-match checker (`Compiler.Nitpick.PatternMatches`) reports
a `let` destructure whose pattern can fail. In the last complex case `makePair`
is defined with no arguments, so it is a pair rather than a function, and the
call to it has no arguments, which is a `Src.Call` the parser never produces.

Among what is not tested: constructor, literal and unit patterns; destructuring
in a function argument or a `case`; and values holding anything but `Int`s.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , define
        , destruct
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , pAlias
        , pAnything
        , pCons
        , pList
        , pRecord
        , pTuple
        , pTuple3
        , pVar
        , recordExpr
        , tuple3Expr
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Let destruct expressions "` followed by `condStr`,
that applies `expectFn` to the programs of this module in turn. The cases are
run with `Compiler.BulkCheck.bulkCheck`: the first case whose expectation fails
ends the run, and the failure is reported under that case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let destruct expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the cases of all six groups, in the order tuples, records, lists,
nested, aliases, complex.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    tupleDestructCases expectFn
        ++ recordDestructCases expectFn
        ++ listDestructCases expectFn
        ++ nestedDestructCases expectFn
        ++ aliasDestructCases expectFn
        ++ complexDestructCases expectFn



-- ============================================================================
-- TUPLE DESTRUCTURING
-- ============================================================================


{-| Returns the four cases that destructure tuples.
-}
tupleDestructCases : (Src.Module -> Expectation) -> List TestCase
tupleDestructCases expectFn =
    [ { label = "Destruct 2-tuple", run = destruct2Tuple expectFn }
    , { label = "Destruct 3-tuple", run = destruct3Tuple expectFn }
    , { label = "Destruct tuple with wildcard", run = destructTupleWithWildcard expectFn }
    , { label = "Multiple tuple destructs", run = multipleTupleDestructs expectFn }
    ]


{-| Applies `expectFn` to a program that destructures `( 1, 2 )` as `( a, b )` and
returns `a`.
-}
destruct2Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
destruct2Tuple expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pTuple (pVar "a") (pVar "b")) pair

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "a"))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `( 1, 2, 3 )` as
`( a, b, c )` and returns `b`.
-}
destruct3Tuple : (Src.Module -> Expectation) -> (() -> Expectation)
destruct3Tuple expectFn _ =
    let
        triple =
            tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)

        def =
            destruct (pTuple3 (pVar "a") (pVar "b") (pVar "c")) triple

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "b"))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `( 1, 2 )` as `( x, _ )` and
returns `x`.
-}
destructTupleWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleWithWildcard expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pTuple (pVar "x") pAnything) pair

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `let` destructures `( 1, 2 )` as
`( a, b )` and `( 3, 4 )` as `( c, d )`, and returns `[ a, b, c, d ]`.
-}
multipleTupleDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleTupleDestructs expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 1) (intExpr 2))

        def2 =
            destruct (pTuple (pVar "c") (pVar "d")) (tupleExpr (intExpr 3) (intExpr 4))

        modul =
            makeModule "testValue"
                (letExpr [ def1, def2 ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ])
                )
    in
    expectFn modul



-- ============================================================================
-- RECORD DESTRUCTURING
-- ============================================================================


{-| Returns the four cases that destructure records.
-}
recordDestructCases : (Src.Module -> Expectation) -> List TestCase
recordDestructCases expectFn =
    [ { label = "Destruct single field record", run = destructSingleFieldRecord expectFn }
    , { label = "Destruct multi-field record", run = destructMultiFieldRecord expectFn }
    , { label = "Destruct partial record", run = destructPartialRecord expectFn }
    , { label = "Multiple record destructs", run = multipleRecordDestructs expectFn }
    ]


{-| Applies `expectFn` to a program that destructures `{ x = 42 }` as `{ x }` and
returns `x`.
-}
destructSingleFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructSingleFieldRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 42 ) ]

        def =
            destruct (pRecord [ "x" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "x"))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `{ x = 1, y = 2 }` as
`{ x, y }` and returns `( x, y )`.
-}
destructMultiFieldRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructMultiFieldRecord expectFn _ =
    let
        record =
            recordExpr [ ( "x", intExpr 1 ), ( "y", intExpr 2 ) ]

        def =
            destruct (pRecord [ "x", "y" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `{ a = 1, b = 2, c = 3 }`
as `{ a, c }`, leaving `b` unbound, and returns `( a, c )`.
-}
destructPartialRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructPartialRecord expectFn _ =
    let
        record =
            recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]

        def =
            destruct (pRecord [ "a", "c" ]) record

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "c")))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `let` destructures `{ x = 1 }` as `{ x }`
and `{ y = 2 }` as `{ y }`, and returns `( x, y )`.
-}
multipleRecordDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
multipleRecordDestructs expectFn _ =
    let
        def1 =
            destruct (pRecord [ "x" ]) (recordExpr [ ( "x", intExpr 1 ) ])

        def2 =
            destruct (pRecord [ "y" ]) (recordExpr [ ( "y", intExpr 2 ) ])

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul



-- ============================================================================
-- LIST DESTRUCTURING
-- ============================================================================


{-| Returns the three cases that destructure lists. Each pattern can fail on some
list, though not on the list it is given.
-}
listDestructCases : (Src.Module -> Expectation) -> List TestCase
listDestructCases expectFn =
    [ { label = "Destruct cons pattern", run = destructConsPattern expectFn }
    , { label = "Destruct fixed list pattern", run = destructFixedListPattern expectFn }
    , { label = "Destruct nested cons", run = destructNestedCons expectFn }
    ]


{-| Applies `expectFn` to a program that destructures `[ 1, 2, 3 ]` as
`head :: tail` and returns `head`.
-}
destructConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
destructConsPattern expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        def =
            destruct (pCons (pVar "head") (pVar "tail")) list

        modul =
            makeModule "testValue" (letExpr [ def ] (varExpr "head"))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `[ 1, 2 ]` as `[ a, b ]`
and returns `( a, b )`.
-}
destructFixedListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
destructFixedListPattern expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2 ]

        def =
            destruct (pList [ pVar "a", pVar "b" ]) list

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `[ 1, 2, 3 ]` as
`a :: b :: rest` and returns `( a, b )`.
-}
destructNestedCons : (Src.Module -> Expectation) -> (() -> Expectation)
destructNestedCons expectFn _ =
    let
        list =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        def =
            destruct (pCons (pVar "a") (pCons (pVar "b") (pVar "rest"))) list

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul



-- ============================================================================
-- NESTED DESTRUCTURING
-- ============================================================================


{-| Returns the four cases whose patterns nest one pattern inside another.
-}
nestedDestructCases : (Src.Module -> Expectation) -> List TestCase
nestedDestructCases expectFn =
    [ { label = "Destruct tuple of tuples", run = destructTupleOfTuples expectFn }
    , { label = "Destruct tuple with record", run = destructTupleWithRecord expectFn }
    , { label = "Deeply nested destruct", run = deeplyNestedDestruct expectFn }
    , { label = "Triple nested destruct", run = tripleNestedDestruct expectFn }
    ]


{-| Applies `expectFn` to a program that destructures `( ( 1, 2 ), ( 3, 4 ) )` as
`( ( a, b ), ( c, d ) )` and returns `[ a, b, c, d ]`.
-}
destructTupleOfTuples : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfTuples expectFn _ =
    let
        nested =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (tupleExpr (intExpr 3) (intExpr 4))

        def =
            destruct (pTuple (pTuple (pVar "a") (pVar "b")) (pTuple (pVar "c") (pVar "d"))) nested

        modul =
            makeModule "testValue" (letExpr [ def ] (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `( { x = 1 }, 2 )` as
`( { x }, y )` and returns `( x, y )`.
-}
destructTupleWithRecord : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleWithRecord expectFn _ =
    let
        nested =
            tupleExpr (recordExpr [ ( "x", intExpr 1 ) ]) (intExpr 2)

        def =
            destruct (pTuple (pRecord [ "x" ]) (pVar "y")) nested

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "x") (varExpr "y")))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `( ( 1, ( 2, 3 ) ), 4 )` as
`( ( a, ( b, c ) ), d )` and returns `[ a, b, c, d ]`.
-}
deeplyNestedDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
deeplyNestedDestruct expectFn _ =
    let
        deep =
            tupleExpr
                (tupleExpr (intExpr 1) (tupleExpr (intExpr 2) (intExpr 3)))
                (intExpr 4)

        def =
            destruct
                (pTuple
                    (pTuple (pVar "a") (pTuple (pVar "b") (pVar "c")))
                    (pVar "d")
                )
                deep

        modul =
            makeModule "testValue" (letExpr [ def ] (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d" ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures a triple of pairs,
`( ( 1, 2 ), ( 3, 4 ), ( 5, 6 ) )`, as `( ( a, b ), ( c, d ), ( e, f ) )` and
returns `[ a, b, c, d, e, f ]`.
-}
tripleNestedDestruct : (Src.Module -> Expectation) -> (() -> Expectation)
tripleNestedDestruct expectFn _ =
    let
        triple =
            tuple3Expr
                (tupleExpr (intExpr 1) (intExpr 2))
                (tupleExpr (intExpr 3) (intExpr 4))
                (tupleExpr (intExpr 5) (intExpr 6))

        def =
            destruct
                (pTuple3
                    (pTuple (pVar "a") (pVar "b"))
                    (pTuple (pVar "c") (pVar "d"))
                    (pTuple (pVar "e") (pVar "f"))
                )
                triple

        modul =
            makeModule "testValue"
                (letExpr [ def ]
                    (listExpr [ varExpr "a", varExpr "b", varExpr "c", varExpr "d", varExpr "e", varExpr "f" ])
                )
    in
    expectFn modul



-- ============================================================================
-- ALIAS DESTRUCTURING
-- ============================================================================


{-| Returns the two cases whose patterns use `as`.
-}
aliasDestructCases : (Src.Module -> Expectation) -> List TestCase
aliasDestructCases expectFn =
    [ { label = "Destruct with simple alias", run = destructWithSimpleAlias expectFn }
    , { label = "Destruct with nested alias", run = destructWithNestedAlias expectFn }
    ]


{-| Applies `expectFn` to a program that destructures `( 1, 2 )` as
`( a, b ) as whole` and returns `( whole, a )`.
-}
destructWithSimpleAlias : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithSimpleAlias expectFn _ =
    let
        pair =
            tupleExpr (intExpr 1) (intExpr 2)

        def =
            destruct (pAlias (pTuple (pVar "a") (pVar "b")) "whole") pair

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "whole") (varExpr "a")))
    in
    expectFn modul


{-| Applies `expectFn` to a program that destructures `( ( 1, 2 ), 3 )` as
`( ( a, b ) as inner, c )` and returns `( inner, a )`.
-}
destructWithNestedAlias : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithNestedAlias expectFn _ =
    let
        nested =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3)

        def =
            destruct
                (pTuple
                    (pAlias (pTuple (pVar "a") (pVar "b")) "inner")
                    (pVar "c")
                )
                nested

        modul =
            makeModule "testValue" (letExpr [ def ] (tupleExpr (varExpr "inner") (varExpr "a")))
    in
    expectFn modul



-- ============================================================================
-- COMPLEX DESTRUCTURING
-- ============================================================================


{-| Returns the four cases that combine a destructure with other definitions or
with another `let`.
-}
complexDestructCases : (Src.Module -> Expectation) -> List TestCase
complexDestructCases expectFn =
    [ { label = "Mixed destruct and define", run = mixedDestructAndDefine expectFn }
    , { label = "Destruct in nested let", run = destructInNestedLet expectFn }
    , { label = "Chain of destructs", run = chainOfDestructs expectFn }
    , { label = "Destruct with function call result", run = destructWithFunctionCallResult expectFn }
    ]


{-| Applies `expectFn` to a program whose `let` defines `x = 1`, destructures
`( 2, 3 )` as `( a, b )`, defines `y = 4`, in that order, and returns
`[ x, a, b, y ]`.
-}
mixedDestructAndDefine : (Src.Module -> Expectation) -> (() -> Expectation)
mixedDestructAndDefine expectFn _ =
    let
        def1 =
            define "x" [] (intExpr 1)

        def2 =
            destruct (pTuple (pVar "a") (pVar "b")) (tupleExpr (intExpr 2) (intExpr 3))

        def3 =
            define "y" [] (intExpr 4)

        modul =
            makeModule "testValue" (letExpr [ def1, def2, def3 ] (listExpr [ varExpr "x", varExpr "a", varExpr "b", varExpr "y" ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose outer `let` defines `pair = ( 1, 2 )` and
whose body is an inner `let` that destructures `pair` as `( a, b )` and returns
`( b, a )`.
-}
destructInNestedLet : (Src.Module -> Expectation) -> (() -> Expectation)
destructInNestedLet expectFn _ =
    let
        outerDef =
            define "pair" [] (tupleExpr (intExpr 1) (intExpr 2))

        innerLet =
            letExpr
                [ destruct (pTuple (pVar "a") (pVar "b")) (varExpr "pair") ]
                (tupleExpr (varExpr "b") (varExpr "a"))

        modul =
            makeModule "testValue" (letExpr [ outerDef ] innerLet)
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `let` destructures `( 1, ( 2, 3 ) )` as
`( a, rest1 )`, then destructures `rest1` as `( b, c )`, and returns
`[ a, b, c ]`.
-}
chainOfDestructs : (Src.Module -> Expectation) -> (() -> Expectation)
chainOfDestructs expectFn _ =
    let
        def1 =
            destruct (pTuple (pVar "a") (pVar "rest1")) (tupleExpr (intExpr 1) (tupleExpr (intExpr 2) (intExpr 3)))

        def2 =
            destruct (pTuple (pVar "b") (pVar "c")) (varExpr "rest1")

        modul =
            makeModule "testValue" (letExpr [ def1, def2 ] (listExpr [ varExpr "a", varExpr "b", varExpr "c" ]))
    in
    expectFn modul


{-| Applies `expectFn` to a program whose `let` defines `makePair = ( 1, 2 )` and
destructures a call of `makePair` with no arguments as `( a, b )`, returning
`( a, b )`.

`makePair` is a pair, not a function, and a call with no arguments is not
something the parser produces, so this program has no counterpart in Elm
source.

-}
destructWithFunctionCallResult : (Src.Module -> Expectation) -> (() -> Expectation)
destructWithFunctionCallResult expectFn _ =
    let
        fnDef =
            define "makePair" [] (tupleExpr (intExpr 1) (intExpr 2))

        destructDef =
            destruct (pTuple (pVar "a") (pVar "b")) (callExpr (varExpr "makePair") [])

        modul =
            makeModule "testValue" (letExpr [ fnDef, destructDef ] (tupleExpr (varExpr "a") (varExpr "b")))
    in
    expectFn modul
