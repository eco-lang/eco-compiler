module SourceIR.CaseCases exposing (expectSuite)

{-| Elm programs built around `case` expressions, for a test to put through a
compiler stage. Without them, a stage could mishandle a kind of pattern that no
other test program happens to use.

This module asserts nothing itself. `expectSuite` gives each program, as a
`Src.Module`, to the expectation function its caller passes, and that function
decides which stage the program goes through and what counts as passing. All
the cases run inside one elm-test test, through `Compiler.BulkCheck.bulkCheck`,
which stops at the first failing case and reports it under its label.

Every program is built with `Compiler.AST.SourceBuilder`, and each defines a
top-level `testValue`. Most are built with `makeModule`, which makes a module
`Test` holding `testValue` alone and importing only `Basics` and `List`. The
custom type and single-constructor cases use
`makeModuleWithTypedDefsUnionsAliases`, which annotates every value and also
imports `Maybe`, `Elm.JsArray`, `String` and `Char`. The string comparison case
uses `makeModuleWithDefs`, which annotates nothing and imports `Basics` and
`List`.

The cases, in the order they run:

  - Five cases on a let-bound `Int`: a single wildcard branch, a single
    variable branch, two and three branches of `Int` literals ending in a
    wildcard, and a variable branch whose body is a tuple holding a list.
  - Five cases on literal patterns: `Int` literals, string literals, ten `Int`
    literals and a wildcard, the empty string and a variable, and negative
    `Int` literals.
  - Three cases on tuples: variable patterns, literal patterns mixed with
    variables, and a pair nested in a pair.
  - Four cases on lists: the empty list, a cons, a fixed-length list, and a
    cons nested in a cons.
  - Three cases on record patterns: one field, two fields, and two of a
    record's three fields.
  - Three cases on `as` patterns, around a variable, a tuple and a cons.
  - Two cases with a `case` inside a branch of another.
  - Two cases on custom types: a two-constructor type whose constructors carry
    one and two fields, and a one-constructor type.
  - One case that compares strings in one function both through string
    patterns and through `==`.
  - Nine cases on pairs of single-constructor types, described below.

Each of the nine single-constructor cases declares two custom types, each with
one constructor of one field, named after the field's type (`WrapBool`,
`WrapInt`, `WrapChar`, `WrapFloat`, `WrapString`), and a function matching on
each. A pattern on a one-constructor type is matched without a tag test: the
typed optimizer reaches the field through a `TypedPath.Unbox` step
(`Compiler.LocalOpt.Typed.DecisionTree`). Code generation stores such a field
unboxed when it is an `Int`, `Float` or `Char`, and boxed otherwise, `Bool` and
`String` included (`Compiler.Generate.MLIR.Types`). Each pair puts two such
types with different field types in one module: in five pairs one field is
stored unboxed and the other boxed, in three both are unboxed, and in the
`String`/`Bool` pair both are boxed. Only one of the two functions is called
from `testValue`; the other is defined and never called.

Among what is not tested: `Char` patterns, the unit pattern, three-element
tuple patterns, and constructor patterns on a custom type with type parameters.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , listExpr
        , makeModule
        , makeModuleWithDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pCons
        , pCtor
        , pInt
        , pList
        , pRecord
        , pStr
        , pTuple
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Case expressions "` followed by `condStr`, that
runs every case in this module through `bulkCheck`, giving each program to
`expectFn`.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Case expressions " ++ condStr) (\() -> bulkCheck (testCases expectFn))


{-| Returns every case in this module, group by group, in the order they run.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    simpleCaseCases expectFn
        ++ literalPatternCases expectFn
        ++ tuplePatternCases expectFn
        ++ listPatternCases expectFn
        ++ recordPatternCases expectFn
        ++ aliasPatternCases expectFn
        ++ nestedCaseCases expectFn
        ++ customTypePatternCases expectFn
        ++ stringChainKernelAbiCases expectFn
        ++ singleCtorPairCases expectFn



-- ============================================================================
-- SIMPLE CASE
-- ============================================================================


{-| Returns the cases that match a let-bound `Int` with wildcard, variable and
`Int` literal patterns.
-}
simpleCaseCases : (Src.Module -> Expectation) -> List TestCase
simpleCaseCases expectFn =
    [ { label = "Case on variable with wildcard", run = caseOnVariableWithWildcard expectFn }
    , { label = "Case with single variable pattern", run = caseWithSingleVarPattern expectFn }
    , { label = "Case with two branches", run = caseWithTwoBranches expectFn }
    , { label = "Case with three branches", run = caseWithThreeBranches expectFn }
    , { label = "Case returning complex expression", run = caseReturningComplexExpr expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` binds `x = 42` in a `let` and
matches `x` against a single wildcard.
-}
caseOnVariableWithWildcard : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnVariableWithWildcard expectFn _ =
    let
        subject =
            intExpr 42

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x") [ ( pAnything, intExpr 0 ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` binds `x = 42` in a `let` and
matches `x` against a single variable pattern `y`, returning `y`.
-}
caseWithSingleVarPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithSingleVarPattern expectFn _ =
    let
        subject =
            intExpr 42

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x") [ ( pVar "y", varExpr "y" ) ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` binds `x = 1` in a `let` and
matches `x` against `0` and a wildcard.
-}
caseWithTwoBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithTwoBranches expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pInt 0, strExpr "zero" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` binds `x = 1` in a `let` and
matches `x` against `0`, `1` and a wildcard.
-}
caseWithThreeBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithThreeBranches expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pInt 0, strExpr "zero" )
                , ( pInt 1, strExpr "one" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` binds `x = 1` in a `let` and
matches `x` against a single variable `n`, returning `( n, [ n ] )`.
-}
caseReturningComplexExpr : (Src.Module -> Expectation) -> (() -> Expectation)
caseReturningComplexExpr expectFn _ =
    let
        subject =
            intExpr 1

        def =
            define "x" [] subject

        case_ =
            caseExpr (varExpr "x")
                [ ( pVar "n", tupleExpr (varExpr "n") (listExpr [ varExpr "n" ]) )
                ]

        modul =
            makeModule "testValue" (letExpr [ def ] case_)
    in
    expectFn modul



-- ============================================================================
-- LITERAL PATTERNS
-- ============================================================================


{-| Returns the cases that match `Int` and string literal patterns.
-}
literalPatternCases : (Src.Module -> Expectation) -> List TestCase
literalPatternCases expectFn =
    [ { label = "Case on int literals", run = caseOnIntLiterals expectFn }
    , { label = "Case on string literals", run = caseOnStringLiterals expectFn }
    , { label = "Case with many int branches", run = caseWithManyIntBranches expectFn }
    , { label = "Case on string", run = caseOnString expectFn }
    , { label = "Case with negative int patterns", run = caseWithNegativeIntPatterns expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches the literal `5` against
`0`, `1`, `5` and a wildcard.
-}
caseOnIntLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnIntLiterals expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr 5)
                    [ ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pInt 5, strExpr "five" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches the literal `"hello"`
against `"hello"`, `"world"` and a wildcard.
-}
caseOnStringLiterals : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnStringLiterals expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (strExpr "hello")
                    [ ( pStr "hello", intExpr 1 )
                    , ( pStr "world", intExpr 2 )
                    , ( pAnything, intExpr 0 )
                    ]
                )
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches the literal `5` against
the ten literals `0` to `9`, each returning ten times itself, and a wildcard
returning `-1`.
-}
caseWithManyIntBranches : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithManyIntBranches expectFn _ =
    let
        branches =
            List.map (\i -> ( pInt i, intExpr (i * 10) )) (List.range 0 9)
                ++ [ ( pAnything, intExpr -1 ) ]

        modul =
            makeModule "testValue" (caseExpr (intExpr 5) branches)
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches the literal `"hello"`
against the empty string and a variable.
-}
caseOnString : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnString expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (strExpr "hello")
                    [ ( pStr "", intExpr 0 )
                    , ( pVar "x", intExpr 1 )
                    ]
                )
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `-5` against `-1`, `0`,
`1` and a wildcard. The subject and the pattern `-1` are built as negative
`Int` literals, not as negations.
-}
caseWithNegativeIntPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNegativeIntPatterns expectFn _ =
    let
        modul =
            makeModule "testValue"
                (caseExpr (intExpr -5)
                    [ ( pInt -1, strExpr "minus one" )
                    , ( pInt 0, strExpr "zero" )
                    , ( pInt 1, strExpr "one" )
                    , ( pAnything, strExpr "other" )
                    ]
                )
    in
    expectFn modul



-- ============================================================================
-- TUPLE PATTERNS
-- ============================================================================


{-| Returns the cases that match pairs.
-}
tuplePatternCases : (Src.Module -> Expectation) -> List TestCase
tuplePatternCases expectFn =
    [ { label = "Case on tuple with var patterns", run = caseOnTupleWithVarPatterns expectFn }
    , { label = "Case on tuple with literal patterns", run = caseOnTupleWithLiteralPatterns expectFn }
    , { label = "Case on nested tuples", run = caseOnNestedTuples expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches `( 1, 2 )` against
`( a, b )` and returns `( b, a )`.
-}
caseOnTupleWithVarPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnTupleWithVarPatterns expectFn _ =
    let
        subject =
            tupleExpr (intExpr 1) (intExpr 2)

        case_ =
            caseExpr subject
                [ ( pTuple (pVar "a") (pVar "b"), tupleExpr (varExpr "b") (varExpr "a") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `( 0, 1 )` against
`( 0, 0 )`, `( 0, y )`, `( x, 0 )` and a wildcard.
-}
caseOnTupleWithLiteralPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnTupleWithLiteralPatterns expectFn _ =
    let
        subject =
            tupleExpr (intExpr 0) (intExpr 1)

        case_ =
            caseExpr subject
                [ ( pTuple (pInt 0) (pInt 0), strExpr "both zero" )
                , ( pTuple (pInt 0) (pVar "y"), strExpr "first zero" )
                , ( pTuple (pVar "x") (pInt 0), strExpr "second zero" )
                , ( pAnything, strExpr "neither" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `( ( 1, 2 ), 3 )`
against `( ( a, b ), c )` and returns `a`.
-}
caseOnNestedTuples : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnNestedTuples expectFn _ =
    let
        subject =
            tupleExpr (tupleExpr (intExpr 1) (intExpr 2)) (intExpr 3)

        case_ =
            caseExpr subject
                [ ( pTuple (pTuple (pVar "a") (pVar "b")) (pVar "c"), varExpr "a" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- LIST PATTERNS
-- ============================================================================


{-| Returns the cases that match list patterns.
-}
listPatternCases : (Src.Module -> Expectation) -> List TestCase
listPatternCases expectFn =
    [ { label = "Case on empty list pattern", run = caseOnEmptyListPattern expectFn }
    , { label = "Case on cons pattern", run = caseOnConsPattern expectFn }
    , { label = "Case on fixed-length list pattern", run = caseOnFixedLengthListPattern expectFn }
    , { label = "Case with nested cons patterns", run = caseWithNestedConsPatterns expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches the empty list against
`[]` and a wildcard.
-}
caseOnEmptyListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnEmptyListPattern expectFn _ =
    let
        subject =
            listExpr []

        case_ =
            caseExpr subject
                [ ( pList [], strExpr "empty" )
                , ( pAnything, strExpr "not empty" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `[ 1, 2 ]` against
`head :: tail`, returning `head`, and `[]`.
-}
caseOnConsPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnConsPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2 ]

        case_ =
            caseExpr subject
                [ ( pCons (pVar "head") (pVar "tail"), varExpr "head" )
                , ( pList [], intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `[ 1, 2, 3 ]` against
`[ a, b, c ]`, returning `b`, and a wildcard.
-}
caseOnFixedLengthListPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnFixedLengthListPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        case_ =
            caseExpr subject
                [ ( pList [ pVar "a", pVar "b", pVar "c" ], varExpr "b" )
                , ( pAnything, intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `[ 1, 2, 3 ]` against
`a :: b :: rest`, returning `b`, and a wildcard.
-}
caseWithNestedConsPatterns : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithNestedConsPatterns expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2, intExpr 3 ]

        case_ =
            caseExpr subject
                [ ( pCons (pVar "a") (pCons (pVar "b") (pVar "rest")), varExpr "b" )
                , ( pAnything, intExpr 0 )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- RECORD PATTERNS
-- ============================================================================


{-| Returns the cases that match record patterns.
-}
recordPatternCases : (Src.Module -> Expectation) -> List TestCase
recordPatternCases expectFn =
    [ { label = "Case on single-field record pattern", run = caseOnSingleFieldRecordPattern expectFn }
    , { label = "Case on multi-field record pattern", run = caseOnMultiFieldRecordPattern expectFn }
    , { label = "Case on partial record pattern", run = caseOnPartialRecordPattern expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches `{ x = 10 }` against
`{ x }` and returns `x`.
-}
caseOnSingleFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnSingleFieldRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "x", intExpr 10 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "x" ], varExpr "x" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `{ x = 10, y = 20 }`
against `{ x, y }` and returns `( x, y )`.
-}
caseOnMultiFieldRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnMultiFieldRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "x", intExpr 10 ), ( "y", intExpr 20 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "x", "y" ], tupleExpr (varExpr "x") (varExpr "y") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches
`{ a = 1, b = 2, c = 3 }` against `{ a, c }`, which leaves `b` out, and
returns `( a, c )`.
-}
caseOnPartialRecordPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnPartialRecordPattern expectFn _ =
    let
        subject =
            recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ), ( "c", intExpr 3 ) ]

        case_ =
            caseExpr subject
                [ ( pRecord [ "a", "c" ], tupleExpr (varExpr "a") (varExpr "c") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- ALIAS PATTERNS
-- ============================================================================


{-| Returns the cases that match `as` patterns.
-}
aliasPatternCases : (Src.Module -> Expectation) -> List TestCase
aliasPatternCases expectFn =
    [ { label = "Case with simple alias pattern", run = caseWithSimpleAliasPattern expectFn }
    , { label = "Case with tuple alias pattern", run = caseWithTupleAliasPattern expectFn }
    , { label = "Case with list alias pattern", run = caseWithListAliasPattern expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches `42` against
`x as whole` and returns `( x, whole )`.
-}
caseWithSimpleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithSimpleAliasPattern expectFn _ =
    let
        subject =
            intExpr 42

        case_ =
            caseExpr subject
                [ ( pAlias (pVar "x") "whole", tupleExpr (varExpr "x") (varExpr "whole") )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `( 1, 2 )` against
`( a, b ) as pair` and returns `pair`.
-}
caseWithTupleAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithTupleAliasPattern expectFn _ =
    let
        subject =
            tupleExpr (intExpr 1) (intExpr 2)

        case_ =
            caseExpr subject
                [ ( pAlias (pTuple (pVar "a") (pVar "b")) "pair", varExpr "pair" )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `[ 1, 2 ]` against
`(h :: t) as list`, returning `list`, and `[]`.
-}
caseWithListAliasPattern : (Src.Module -> Expectation) -> (() -> Expectation)
caseWithListAliasPattern expectFn _ =
    let
        subject =
            listExpr [ intExpr 1, intExpr 2 ]

        case_ =
            caseExpr subject
                [ ( pAlias (pCons (pVar "h") (pVar "t")) "list", varExpr "list" )
                , ( pList [], listExpr [] )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- NESTED CASE
-- ============================================================================


{-| Returns the cases with a `case` inside a branch of another.
-}
nestedCaseCases : (Src.Module -> Expectation) -> List TestCase
nestedCaseCases expectFn =
    [ { label = "Case inside case", run = caseInsideCase expectFn }
    , { label = "Case in branch body", run = caseInBranchBody expectFn }
    ]


{-| Gives `expectFn` a module whose `testValue` matches `2` against `0` and a
wildcard, and in the wildcard branch matches `1` against `0` and a wildcard.
-}
caseInsideCase : (Src.Module -> Expectation) -> (() -> Expectation)
caseInsideCase expectFn _ =
    let
        innerCase =
            caseExpr (intExpr 1)
                [ ( pInt 0, strExpr "zero" )
                , ( pAnything, strExpr "other" )
                ]

        outerCase =
            caseExpr (intExpr 2)
                [ ( pInt 0, strExpr "outer zero" )
                , ( pAnything, innerCase )
                ]

        modul =
            makeModule "testValue" outerCase
    in
    expectFn modul


{-| Gives `expectFn` a module whose `testValue` matches `( 1, 2 )` against
`( a, b )`, and in that branch matches `a` against `0`, returning `b`, and a
wildcard, returning `a`.
-}
caseInBranchBody : (Src.Module -> Expectation) -> (() -> Expectation)
caseInBranchBody expectFn _ =
    let
        case_ =
            caseExpr (tupleExpr (intExpr 1) (intExpr 2))
                [ ( pTuple (pVar "a") (pVar "b")
                  , caseExpr (varExpr "a")
                        [ ( pInt 0, varExpr "b" )
                        , ( pAnything, varExpr "a" )
                        ]
                  )
                ]

        modul =
            makeModule "testValue" case_
    in
    expectFn modul



-- ============================================================================
-- CUSTOM TYPE PATTERNS
-- ============================================================================


{-| Returns the cases that match constructors of custom types declared in the
built module.
-}
customTypePatternCases : (Src.Module -> Expectation) -> List TestCase
customTypePatternCases expectFn =
    [ { label = "Case on custom type with multiple constructors", run = caseOnCustomTypeMultipleConstructors expectFn }
    , { label = "Case on custom type with payload extraction", run = caseOnCustomTypePayloadExtraction expectFn }
    ]


{-| Gives `expectFn` a module that declares a two-constructor type and
matches on it, with every value annotated:

    type Shape
        = Circle Int
        | Rectangle Int Int

    area : Shape -> Int
    area shape =
        case shape of
            Circle r ->
                r * r

            Rectangle w h ->
                w * h

    testValue : Int
    testValue =
        area (Circle 5)

-}
caseOnCustomTypeMultipleConstructors : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnCustomTypeMultipleConstructors expectFn _ =
    let
        shapeUnion : UnionDef
        shapeUnion =
            { name = "Shape"
            , args = []
            , ctors =
                [ { name = "Circle", args = [ tType "Int" [] ] }
                , { name = "Rectangle", args = [ tType "Int" [], tType "Int" [] ] }
                ]
            }

        areaFn : TypedDef
        areaFn =
            { name = "area"
            , args = [ pVar "shape" ]
            , tipe = tLambda (tType "Shape" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "shape")
                    [ ( pCtor "Circle" [ pVar "r" ]
                      , binopsExpr [ ( varExpr "r", "*" ) ] (varExpr "r")
                      )
                    , ( pCtor "Rectangle" [ pVar "w", pVar "h" ]
                      , binopsExpr [ ( varExpr "w", "*" ) ] (varExpr "h")
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "area") [ callExpr (ctorExpr "Circle") [ intExpr 5 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ areaFn, testValueDef ] [ shapeUnion ] []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares a one-constructor type and takes
its field out with a `case`, with every value annotated:

    type Wrapper
        = Wrap Int

    unwrap : Wrapper -> Int
    unwrap w =
        case w of
            Wrap x ->
                x

    testValue : Int
    testValue =
        unwrap (Wrap 99)

-}
caseOnCustomTypePayloadExtraction : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnCustomTypePayloadExtraction expectFn _ =
    let
        wrapperUnion : UnionDef
        wrapperUnion =
            { name = "Wrapper"
            , args = []
            , ctors =
                [ { name = "Wrap", args = [ tType "Int" [] ] }
                ]
            }

        unwrapFn : TypedDef
        unwrapFn =
            { name = "unwrap"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wrapper" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wrap" [ pVar "x" ], varExpr "x" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unwrap") [ callExpr (ctorExpr "Wrap") [ intExpr 99 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ unwrapFn, testValueDef ] [ wrapperUnion ] []
    in
    expectFn modul



-- ============================================================================
-- STRING PATTERNS WITH STRING EQUALITY
-- ============================================================================


{-| Returns the one case that compares strings both with `==` and with string
patterns.
-}
stringChainKernelAbiCases : (Src.Module -> Expectation) -> List TestCase
stringChainKernelAbiCases expectFn =
    [ { label = "String chain in tuple case with string equality (CGEN_038)", run = stringChainWithStringEquality expectFn }
    ]


{-| Gives `expectFn` a module whose function `testFn` compares its string
argument both with `==` and with string patterns, the patterns sitting in a
tuple beside a `Bool`. No value is annotated:

    testFn x =
        let
            eq =
                x == "world"

            r =
                case ( x, Basics.True ) of
                    ( "foo", True ) ->
                        1

                    ( "bar", False ) ->
                        2

                    _ ->
                        0
        in
        if eq then
            r

        else
            0

    testValue =
        testFn "hello"

-}
stringChainWithStringEquality : (Src.Module -> Expectation) -> (() -> Expectation)
stringChainWithStringEquality expectFn _ =
    let
        eqDef =
            define "eq"
                []
                (binopsExpr [ ( varExpr "x", "==" ) ] (strExpr "world"))

        rDef =
            define "r"
                []
                (caseExpr (tupleExpr (varExpr "x") (boolExpr True))
                    [ ( pTuple (pStr "foo") (pCtor "True" []), intExpr 1 )
                    , ( pTuple (pStr "bar") (pCtor "False" []), intExpr 2 )
                    , ( pAnything, intExpr 0 )
                    ]
                )

        body =
            ifExpr (varExpr "eq") (varExpr "r") (intExpr 0)

        modul =
            makeModuleWithDefs "Test"
                [ ( "testFn"
                  , [ pVar "x" ]
                  , letExpr [ eqDef, rDef ] body
                  )
                , ( "testValue"
                  , []
                  , callExpr (varExpr "testFn") [ strExpr "hello" ]
                  )
                ]
    in
    expectFn modul



-- ============================================================================
-- SINGLE-CONSTRUCTOR TYPE PAIR CASES
-- ============================================================================


{-| Returns the nine cases that each declare two single-constructor types with
fields of different types, as the module docstring describes.
-}
singleCtorPairCases : (Src.Module -> Expectation) -> List TestCase
singleCtorPairCases expectFn =
    [ { label = "Single-ctor pair: Bool/Int (Bool matched, Int pollutant)", run = singleCtorPairBoolInt expectFn }
    , { label = "Single-ctor pair: Bool/Char (Bool matched, Char pollutant)", run = singleCtorPairBoolChar expectFn }
    , { label = "Single-ctor pair: Bool/Float (Bool matched, Float pollutant)", run = singleCtorPairBoolFloat expectFn }
    , { label = "Single-ctor pair: Int/Float (both unboxed, different types)", run = singleCtorPairIntFloat expectFn }
    , { label = "Single-ctor pair: String/Int (String boxed, Int unboxed)", run = singleCtorPairStringInt expectFn }
    , { label = "Single-ctor pair: String/Bool (both boxed)", run = singleCtorPairStringBool expectFn }
    , { label = "Single-ctor pair: Char/Int (both unboxed, different widths)", run = singleCtorPairCharInt expectFn }
    , { label = "Single-ctor pair: Char/Float (both unboxed, different types)", run = singleCtorPairCharFloat expectFn }
    , { label = "Single-ctor pair: Float/Bool (Float unboxed, Bool boxed)", run = singleCtorPairFloatBool expectFn }
    ]


{-| Gives `expectFn` a module that declares `WrapBool`, holding a `Bool`, and
`WrapInt`, holding an `Int`. `matchBool b` wraps `b` in a `WrapBool` and matches
it against `WrapBool True` and `WrapBool False`, and `unwrapInt` takes the `Int`
out of a `WrapInt`. `testValue` is `matchBool True`, so `unwrapInt` is never
called.
-}
singleCtorPairBoolInt : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairBoolInt expectFn _ =
    let
        wrapBool =
            { name = "WrapBool", args = [], ctors = [ { name = "WrapBool", args = [ tType "Bool" [] ] } ] }

        wrapInt =
            { name = "WrapInt", args = [], ctors = [ { name = "WrapInt", args = [ tType "Int" [] ] } ] }

        matchBoolFn : TypedDef
        matchBoolFn =
            { name = "matchBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "String" [])
            , body =
                letExpr
                    [ define "w" [] (callExpr (ctorExpr "WrapBool") [ varExpr "b" ]) ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "WrapBool" [ pCtor "True" [] ], strExpr "yes" )
                        , ( pCtor "WrapBool" [ pCtor "False" [] ], strExpr "no" )
                        ]
                    )
            }

        unwrapIntFn : TypedDef
        unwrapIntFn =
            { name = "unwrapInt"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapInt" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapInt" [ pVar "n" ], varExpr "n" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "matchBool") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ matchBoolFn, unwrapIntFn, testValueDef ]
                [ wrapBool, wrapInt ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapBool`, holding a `Bool`, and
`WrapChar`, holding a `Char`. `matchBool b` wraps `b` in a `WrapBool` and
matches it against `WrapBool True` and `WrapBool False`, and `unwrapChar` takes
the `Char` out of a `WrapChar`. `testValue` is `matchBool True`, so `unwrapChar`
is never called.
-}
singleCtorPairBoolChar : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairBoolChar expectFn _ =
    let
        wrapBool =
            { name = "WrapBool", args = [], ctors = [ { name = "WrapBool", args = [ tType "Bool" [] ] } ] }

        wrapChar =
            { name = "WrapChar", args = [], ctors = [ { name = "WrapChar", args = [ tType "Char" [] ] } ] }

        matchBoolFn : TypedDef
        matchBoolFn =
            { name = "matchBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "String" [])
            , body =
                letExpr
                    [ define "w" [] (callExpr (ctorExpr "WrapBool") [ varExpr "b" ]) ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "WrapBool" [ pCtor "True" [] ], strExpr "yes" )
                        , ( pCtor "WrapBool" [ pCtor "False" [] ], strExpr "no" )
                        ]
                    )
            }

        unwrapCharFn : TypedDef
        unwrapCharFn =
            { name = "unwrapChar"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapChar" []) (tType "Char" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapChar" [ pVar "c" ], varExpr "c" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "matchBool") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ matchBoolFn, unwrapCharFn, testValueDef ]
                [ wrapBool, wrapChar ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapBool`, holding a `Bool`, and
`WrapFloat`, holding a `Float`. `matchBool b` wraps `b` in a `WrapBool` and
matches it against `WrapBool True` and `WrapBool False`, and `unwrapFloat` takes
the `Float` out of a `WrapFloat`. `testValue` is `matchBool True`, so
`unwrapFloat` is never called.
-}
singleCtorPairBoolFloat : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairBoolFloat expectFn _ =
    let
        wrapBool =
            { name = "WrapBool", args = [], ctors = [ { name = "WrapBool", args = [ tType "Bool" [] ] } ] }

        wrapFloat =
            { name = "WrapFloat", args = [], ctors = [ { name = "WrapFloat", args = [ tType "Float" [] ] } ] }

        matchBoolFn : TypedDef
        matchBoolFn =
            { name = "matchBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "String" [])
            , body =
                letExpr
                    [ define "w" [] (callExpr (ctorExpr "WrapBool") [ varExpr "b" ]) ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "WrapBool" [ pCtor "True" [] ], strExpr "yes" )
                        , ( pCtor "WrapBool" [ pCtor "False" [] ], strExpr "no" )
                        ]
                    )
            }

        unwrapFloatFn : TypedDef
        unwrapFloatFn =
            { name = "unwrapFloat"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapFloat" []) (tType "Float" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapFloat" [ pVar "f" ], varExpr "f" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "matchBool") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ matchBoolFn, unwrapFloatFn, testValueDef ]
                [ wrapBool, wrapFloat ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapInt`, holding an `Int`, and
`WrapFloat`, holding a `Float`, with `unwrapInt` and `unwrapFloat` taking each
field out. `testValue` is `unwrapInt (WrapInt 42)`, so `unwrapFloat` is never
called.
-}
singleCtorPairIntFloat : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairIntFloat expectFn _ =
    let
        wrapInt =
            { name = "WrapInt", args = [], ctors = [ { name = "WrapInt", args = [ tType "Int" [] ] } ] }

        wrapFloat =
            { name = "WrapFloat", args = [], ctors = [ { name = "WrapFloat", args = [ tType "Float" [] ] } ] }

        unwrapIntFn : TypedDef
        unwrapIntFn =
            { name = "unwrapInt"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapInt" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapInt" [ pVar "n" ], varExpr "n" ) ]
            }

        unwrapFloatFn : TypedDef
        unwrapFloatFn =
            { name = "unwrapFloat"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapFloat" []) (tType "Float" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapFloat" [ pVar "f" ], varExpr "f" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body = callExpr (varExpr "unwrapInt") [ callExpr (ctorExpr "WrapInt") [ intExpr 42 ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapIntFn, unwrapFloatFn, testValueDef ]
                [ wrapInt, wrapFloat ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapString`, holding a `String`,
and `WrapInt`, holding an `Int`, with `unwrapString` and `unwrapInt` taking
each field out. `testValue` is `unwrapString (WrapString "hello")`, so
`unwrapInt` is never called.
-}
singleCtorPairStringInt : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairStringInt expectFn _ =
    let
        wrapString =
            { name = "WrapString", args = [], ctors = [ { name = "WrapString", args = [ tType "String" [] ] } ] }

        wrapInt =
            { name = "WrapInt", args = [], ctors = [ { name = "WrapInt", args = [ tType "Int" [] ] } ] }

        unwrapStringFn : TypedDef
        unwrapStringFn =
            { name = "unwrapString"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapString" []) (tType "String" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapString" [ pVar "s" ], varExpr "s" ) ]
            }

        unwrapIntFn : TypedDef
        unwrapIntFn =
            { name = "unwrapInt"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapInt" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapInt" [ pVar "n" ], varExpr "n" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "unwrapString") [ callExpr (ctorExpr "WrapString") [ strExpr "hello" ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapStringFn, unwrapIntFn, testValueDef ]
                [ wrapString, wrapInt ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapString`, holding a `String`,
and `WrapBool`, holding a `Bool`. `unwrapString` takes the `String` out of a
`WrapString`, and `matchBool b` wraps `b` in a `WrapBool` and matches it
against `WrapBool True` and `WrapBool False`. `testValue` is `matchBool True`,
so `unwrapString` is never called.
-}
singleCtorPairStringBool : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairStringBool expectFn _ =
    let
        wrapString =
            { name = "WrapString", args = [], ctors = [ { name = "WrapString", args = [ tType "String" [] ] } ] }

        wrapBool =
            { name = "WrapBool", args = [], ctors = [ { name = "WrapBool", args = [ tType "Bool" [] ] } ] }

        unwrapStringFn : TypedDef
        unwrapStringFn =
            { name = "unwrapString"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapString" []) (tType "String" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapString" [ pVar "s" ], varExpr "s" ) ]
            }

        matchBoolFn : TypedDef
        matchBoolFn =
            { name = "matchBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "String" [])
            , body =
                letExpr
                    [ define "w" [] (callExpr (ctorExpr "WrapBool") [ varExpr "b" ]) ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "WrapBool" [ pCtor "True" [] ], strExpr "yes" )
                        , ( pCtor "WrapBool" [ pCtor "False" [] ], strExpr "no" )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "matchBool") [ boolExpr True ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapStringFn, matchBoolFn, testValueDef ]
                [ wrapString, wrapBool ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapChar`, holding a `Char`, and
`WrapInt`, holding an `Int`, with `unwrapChar` and `unwrapInt` taking each
field out. `testValue` is `unwrapChar (WrapChar 'A')`, so `unwrapInt` is never
called.
-}
singleCtorPairCharInt : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairCharInt expectFn _ =
    let
        wrapChar =
            { name = "WrapChar", args = [], ctors = [ { name = "WrapChar", args = [ tType "Char" [] ] } ] }

        wrapInt =
            { name = "WrapInt", args = [], ctors = [ { name = "WrapInt", args = [ tType "Int" [] ] } ] }

        unwrapCharFn : TypedDef
        unwrapCharFn =
            { name = "unwrapChar"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapChar" []) (tType "Char" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapChar" [ pVar "c" ], varExpr "c" ) ]
            }

        unwrapIntFn : TypedDef
        unwrapIntFn =
            { name = "unwrapInt"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapInt" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapInt" [ pVar "n" ], varExpr "n" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Char" []
            , body = callExpr (varExpr "unwrapChar") [ callExpr (ctorExpr "WrapChar") [ chrExpr "A" ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapCharFn, unwrapIntFn, testValueDef ]
                [ wrapChar, wrapInt ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapChar`, holding a `Char`, and
`WrapFloat`, holding a `Float`, with `unwrapChar` and `unwrapFloat` taking each
field out. `testValue` is `unwrapChar (WrapChar 'Z')`, so `unwrapFloat` is
never called.
-}
singleCtorPairCharFloat : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairCharFloat expectFn _ =
    let
        wrapChar =
            { name = "WrapChar", args = [], ctors = [ { name = "WrapChar", args = [ tType "Char" [] ] } ] }

        wrapFloat =
            { name = "WrapFloat", args = [], ctors = [ { name = "WrapFloat", args = [ tType "Float" [] ] } ] }

        unwrapCharFn : TypedDef
        unwrapCharFn =
            { name = "unwrapChar"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapChar" []) (tType "Char" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapChar" [ pVar "c" ], varExpr "c" ) ]
            }

        unwrapFloatFn : TypedDef
        unwrapFloatFn =
            { name = "unwrapFloat"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapFloat" []) (tType "Float" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapFloat" [ pVar "f" ], varExpr "f" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Char" []
            , body = callExpr (varExpr "unwrapChar") [ callExpr (ctorExpr "WrapChar") [ chrExpr "Z" ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapCharFn, unwrapFloatFn, testValueDef ]
                [ wrapChar, wrapFloat ]
                []
    in
    expectFn modul


{-| Gives `expectFn` a module that declares `WrapFloat`, holding a `Float`,
and `WrapBool`, holding a `Bool`. `unwrapFloat` takes the `Float` out of a
`WrapFloat`, and `matchBool b` wraps `b` in a `WrapBool` and matches it
against `WrapBool True` and `WrapBool False`. `testValue` is
`matchBool False`, so `unwrapFloat` is never called.
-}
singleCtorPairFloatBool : (Src.Module -> Expectation) -> (() -> Expectation)
singleCtorPairFloatBool expectFn _ =
    let
        wrapFloat =
            { name = "WrapFloat", args = [], ctors = [ { name = "WrapFloat", args = [ tType "Float" [] ] } ] }

        wrapBool =
            { name = "WrapBool", args = [], ctors = [ { name = "WrapBool", args = [ tType "Bool" [] ] } ] }

        unwrapFloatFn : TypedDef
        unwrapFloatFn =
            { name = "unwrapFloat"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "WrapFloat" []) (tType "Float" [])
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "WrapFloat" [ pVar "f" ], varExpr "f" ) ]
            }

        matchBoolFn : TypedDef
        matchBoolFn =
            { name = "matchBool"
            , args = [ pVar "b" ]
            , tipe = tLambda (tType "Bool" []) (tType "String" [])
            , body =
                letExpr
                    [ define "w" [] (callExpr (ctorExpr "WrapBool") [ varExpr "b" ]) ]
                    (caseExpr (varExpr "w")
                        [ ( pCtor "WrapBool" [ pCtor "True" [] ], strExpr "yes" )
                        , ( pCtor "WrapBool" [ pCtor "False" [] ], strExpr "no" )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "String" []
            , body = callExpr (varExpr "matchBool") [ boolExpr False ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ unwrapFloatFn, matchBoolFn, testValueDef ]
                [ wrapFloat, wrapBool ]
                []
    in
    expectFn modul
