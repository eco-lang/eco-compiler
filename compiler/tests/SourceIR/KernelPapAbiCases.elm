module SourceIR.KernelPapAbiCases exposing (expectSuite)

{-| Tests for kernel function usage patterns that exercise ABI consistency.

These test equality and comparison operators used in various contexts
to ensure kernel ABI types are consistent across call sites.
Exercises CGEN\_038 and KERN\_006.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pAnything
        , pStr
        , pVar
        , qualVarExpr
        , strExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Kernel PAP ABI consistency " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Equality on Int with string case", run = equalityOnIntWithStringCase expectFn }
    , { label = "Equality on multiple types", run = equalityOnMultipleTypes expectFn }
    , { label = "Equality lambda passed to map", run = equalityLambdaPassedToMap expectFn }
    , { label = "Append on lists", run = appendOnLists expectFn }
    ]


{-| Int equality binop in same module as string case pattern.
Both paths register Elm\_Kernel\_Utils\_equal — must not conflict.
-}
equalityOnIntWithStringCase : (Src.Module -> Expectation) -> (() -> Expectation)
equalityOnIntWithStringCase expectFn _ =
    let
        classifyBody =
            caseExpr (varExpr "s")
                [ ( pStr "foo", strExpr "matched" )
                , ( pAnything, strExpr "other" )
                ]

        modul =
            makeModule "testValue"
                (letExpr
                    [ define "classify" [ pVar "s" ] classifyBody
                    , define "result"
                        []
                        (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 2))
                    ]
                    (callExpr (varExpr "classify") [ strExpr "foo" ])
                )
    in
    expectFn modul


{-| Equality used on both Int and String in the same module.
-}
equalityOnMultipleTypes : (Src.Module -> Expectation) -> (() -> Expectation)
equalityOnMultipleTypes expectFn _ =
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "intEq" [] (binopsExpr [ ( intExpr 1, "==" ) ] (intExpr 2))
                    , define "strEq" [] (binopsExpr [ ( strExpr "a", "==" ) ] (strExpr "b"))
                    ]
                    (varExpr "intEq")
                )
    in
    expectFn modul


{-| Lambda wrapping equality passed to List.map.
Creates a closure that calls the equality kernel.
-}
equalityLambdaPassedToMap : (Src.Module -> Expectation) -> (() -> Expectation)
equalityLambdaPassedToMap expectFn _ =
    let
        eqLambda =
            lambdaExpr [ pVar "x" ]
                (binopsExpr [ ( varExpr "x", "==" ) ] (intExpr 5))

        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "map")
                    [ eqLambda
                    , listExpr [ intExpr 1, intExpr 5, intExpr 3 ]
                    ]
                )
    in
    expectFn modul


{-| (++) on lists.
-}
appendOnLists : (Src.Module -> Expectation) -> (() -> Expectation)
appendOnLists expectFn _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( listExpr [ intExpr 1 ], "++" ) ]
                    (listExpr [ intExpr 2, intExpr 3 ])
                )
    in
    expectFn modul
