module TestLogic.Type.UnificationErrorsTest exposing (suite)

{-| Test suite for invariant TYPE\_002: Unification failures become type errors.

This module tests that type mismatches are properly reported as errors.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.UnificationErrors
    exposing
        ( expectNoTypeErrors
        , expectTypeMismatchError
        )


suite : Test
suite =
    Test.describe "Unification failures become type errors (TYPE_002)"
        [ typeMismatchTests
        , validTypeTests
        ]


typeMismatchTests : Test
typeMismatchTests =
    Test.describe "Type mismatch detection"
        [ Test.test "Int vs String in function argument" <|
            \_ ->
                let
                    -- f : String -> String
                    -- f s = s
                    -- x = f 42  -- Error: Int given where String expected
                    modul =
                        SB.makeModuleWithDefs "TypeMismatch"
                            [ ( "f"
                              , [ SB.pVar "s" ]
                              , SB.varExpr "s"
                              )
                            , ( "x"
                              , []
                              , SB.callExpr (SB.varExpr "f") [ SB.intExpr 42 ]
                              )
                            ]
                in
                -- This should produce a type error (if f is constrained to String)
                -- For now, this may pass since f is polymorphic
                expectNoTypeErrors modul
        , Test.test "Int in if condition" <|
            \_ ->
                let
                    -- x = if 42 then 1 else 2  -- Error: Int where Bool expected
                    modul =
                        SB.makeModuleWithDefs "IfMismatch"
                            [ ( "x"
                              , []
                              , SB.ifExpr
                                    (SB.intExpr 42)
                                    (SB.intExpr 1)
                                    (SB.intExpr 2)
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "mismatched if branches" <|
            \_ ->
                let
                    -- x = if True then 1 else "hello"  -- Error: Int vs String
                    modul =
                        SB.makeModuleWithDefs "BranchMismatch"
                            [ ( "x"
                              , []
                              , SB.ifExpr
                                    (SB.boolExpr True)
                                    (SB.intExpr 1)
                                    (SB.strExpr "hello")
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "mismatched list elements" <|
            \_ ->
                let
                    -- x = [1, "hello"]  -- Error: Int vs String
                    modul =
                        SB.makeModuleWithDefs "ListMismatch"
                            [ ( "x"
                              , []
                              , SB.listExpr [ SB.intExpr 1, SB.strExpr "hello" ]
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "mismatched case branches" <|
            \_ ->
                let
                    -- x n = case n of
                    --   0 -> 1
                    --   _ -> "hello"  -- Error: Int vs String
                    modul =
                        SB.makeModuleWithDefs "CaseMismatch"
                            [ ( "x"
                              , [ SB.pVar "n" ]
                              , SB.caseExpr
                                    (SB.varExpr "n")
                                    [ ( SB.pInt 0, SB.intExpr 1 )
                                    , ( SB.pAnything, SB.strExpr "hello" )
                                    ]
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "operator type mismatch" <|
            \_ ->
                let
                    -- x = 1 + "hello"  -- Error: String where number expected
                    modul =
                        SB.makeModuleWithDefs "OpMismatch"
                            [ ( "x"
                              , []
                              , SB.binopsExpr [ ( SB.intExpr 1, "+" ) ] (SB.strExpr "hello")
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "comparable 2-tuple with non-comparable first element" <|
            \_ ->
                let
                    -- x = (\z -> z, 1) < (\w -> w, 2)
                    -- First tuple element is a function (not comparable); last is Int.
                    -- Must be rejected. Eco currently accepts it: Unify.elm:540 only
                    -- unifies the LAST tuple element against comparable.
                    modul =
                        SB.makeModuleWithDefs "TupleCompFirst"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tupleExpr (SB.lambdaExpr [ SB.pVar "z" ] (SB.varExpr "z")) (SB.intExpr 1), "<" ) ]
                                    (SB.tupleExpr (SB.lambdaExpr [ SB.pVar "w" ] (SB.varExpr "w")) (SB.intExpr 2))
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "comparable 3-tuple with non-comparable middle element" <|
            \_ ->
                let
                    -- x = (1, \z -> z, 2) < (3, \w -> w, 4)
                    -- Middle element is a function; exercises the n-ary tuple tail (cs).
                    modul =
                        SB.makeModuleWithDefs "TupleCompMiddle"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tuple3Expr (SB.intExpr 1) (SB.lambdaExpr [ SB.pVar "z" ] (SB.varExpr "z")) (SB.intExpr 2), "<" ) ]
                                    (SB.tuple3Expr (SB.intExpr 3) (SB.lambdaExpr [ SB.pVar "w" ] (SB.varExpr "w")) (SB.intExpr 4))
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "comparable 3-tuple with non-comparable first element" <|
            \_ ->
                let
                    -- x = (\z -> z, 1, 2) < (\w -> w, 3, 4)
                    modul =
                        SB.makeModuleWithDefs "TupleComp3First"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tuple3Expr (SB.lambdaExpr [ SB.pVar "z" ] (SB.varExpr "z")) (SB.intExpr 1) (SB.intExpr 2), "<" ) ]
                                    (SB.tuple3Expr (SB.lambdaExpr [ SB.pVar "w" ] (SB.varExpr "w")) (SB.intExpr 3) (SB.intExpr 4))
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "comparable tuple with non-comparable LAST element (control)" <|
            \_ ->
                let
                    -- x = (1, \z -> z) < (2, \w -> w)
                    -- Non-comparable element is LAST, which eco already checks, so this
                    -- is rejected today too. Guards that a fix does not regress it.
                    modul =
                        SB.makeModuleWithDefs "TupleCompLast"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tupleExpr (SB.intExpr 1) (SB.lambdaExpr [ SB.pVar "z" ] (SB.varExpr "z")), "<" ) ]
                                    (SB.tupleExpr (SB.intExpr 2) (SB.lambdaExpr [ SB.pVar "w" ] (SB.varExpr "w")))
                              )
                            ]
                in
                expectTypeMismatchError modul
        ]


validTypeTests : Test
validTypeTests =
    Test.describe "Valid types succeed"
        [ Test.test "homogeneous list" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ValidList"
                            [ ( "x", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] ) ]
                in
                expectNoTypeErrors modul
        , Test.test "valid if expression" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ValidIf"
                            [ ( "x"
                              , []
                              , SB.ifExpr
                                    (SB.boolExpr True)
                                    (SB.intExpr 1)
                                    (SB.intExpr 2)
                              )
                            ]
                in
                expectNoTypeErrors modul
        , Test.test "valid function application" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ValidApp"
                            [ ( "f", [ SB.pVar "x" ], SB.varExpr "x" )
                            , ( "y", [], SB.callExpr (SB.varExpr "f") [ SB.intExpr 42 ] )
                            ]
                in
                expectNoTypeErrors modul
        , Test.test "comparable tuple with all comparable elements" <|
            \_ ->
                let
                    -- x = (1, 2) < (3, 4)   -- both elements comparable -> accepted
                    modul =
                        SB.makeModuleWithDefs "TupleCompValid"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tupleExpr (SB.intExpr 1) (SB.intExpr 2), "<" ) ]
                                    (SB.tupleExpr (SB.intExpr 3) (SB.intExpr 4))
                              )
                            ]
                in
                expectNoTypeErrors modul
        , Test.test "comparable tuple with mixed comparable elements" <|
            \_ ->
                let
                    -- x = ("a", 1) < ("b", 2)   -- String + Int both comparable -> accepted
                    modul =
                        SB.makeModuleWithDefs "TupleCompMixedValid"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.tupleExpr (SB.strExpr "a") (SB.intExpr 1), "<" ) ]
                                    (SB.tupleExpr (SB.strExpr "b") (SB.intExpr 2))
                              )
                            ]
                in
                expectNoTypeErrors modul
        ]
