module Compiler.Type.AnnotationEnforcementTest exposing (suite)

{-| Test suite for invariant TYPE_006: Annotations are enforced, not ignored.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Type.AnnotationEnforcement exposing
    ( expectAnnotationMismatchError
    , expectMatchingAnnotationSucceeds
    )
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Annotations are enforced, not ignored (TYPE_006)"
        [ matchingAnnotationTests
        , mismatchedAnnotationTests
        ]


matchingAnnotationTests : Test
matchingAnnotationTests =
    Test.describe "Matching annotations succeed"
        [ Test.test "Int annotation on Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchInt"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType ("Int") []
                              , body = SB.intExpr 42
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "String annotation on String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchString"
                            [ { name = "s"
                              , args = []
                              , tipe = SB.tType ("String") []
                              , body = SB.strExpr "hello"
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "function annotation on function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchFunc"
                            [ { name = "f"
                              , args = [ SB.pVar "x" ]
                              , tipe =
                                    SB.tLambda
                                        (SB.tType ("Int") [])
                                        (SB.tType ("Int") [])
                              , body = SB.varExpr "x"
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "List Int annotation on list of ints" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchList"
                            [ { name = "xs"
                              , args = []
                              , tipe =
                                    SB.tType ("List")
                                        [ SB.tType ("Int") [] ]
                              , body = SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ]
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        , Test.test "tuple annotation on tuple" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MatchTuple"
                            [ { name = "pair"
                              , args = []
                              , tipe =
                                    SB.tTuple
                                        (SB.tType ("Int") [])
                                        (SB.tType ("String") [])
                              , body = SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a")
                              }
                            ]
                in
                expectMatchingAnnotationSucceeds modul
        ]


mismatchedAnnotationTests : Test
mismatchedAnnotationTests =
    Test.describe "Mismatched annotations produce errors"
        [ Test.test "Int annotation on String value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchIntStr"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType ("Int") []
                              , body = SB.strExpr "hello"
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "String annotation on Int value" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchStrInt"
                            [ { name = "x"
                              , args = []
                              , tipe = SB.tType ("String") []
                              , body = SB.intExpr 42
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong function return type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchFuncReturn"
                            [ { name = "f"
                              , args = [ SB.pVar "x" ]
                              , tipe =
                                    SB.tLambda
                                        (SB.tType ("Int") [])
                                        (SB.tType ("String") [])
                              , body = SB.varExpr "x" -- Returns Int, not String
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong list element type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchListElem"
                            [ { name = "xs"
                              , args = []
                              , tipe =
                                    SB.tType ("List")
                                        [ SB.tType ("String") [] ]
                              , body = SB.listExpr [ SB.intExpr 1 ] -- List Int, not List String
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        , Test.test "wrong tuple element type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithTypedDefs "MismatchTupleElem"
                            [ { name = "pair"
                              , args = []
                              , tipe =
                                    SB.tTuple
                                        (SB.tType ("String") [])
                                        (SB.tType ("Int") [])
                              , body = SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a") -- Swapped
                              }
                            ]
                in
                expectAnnotationMismatchError modul
        ]
