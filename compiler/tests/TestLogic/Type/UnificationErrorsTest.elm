module TestLogic.Type.UnificationErrorsTest exposing (suite)

{-| Checks that the type checker turns a failed unification into a type error,
and reports none for a well-typed module. A solver that let a failed
unification pass would accept an ill-typed program, and one that reported a
mismatch where there is none would reject a correct one; these tests are built
to catch either.

Each test builds a small module with
`Compiler.AST.SourceBuilder.makeModuleWithDefs`, unannotated top-level values,
or, for the first test, `makeModuleWithTypedDefs`, annotated ones, in a module
that imports `Basics` and `List`. It passes the module to
`expectTypeMismatchError` or `expectNoTypeErrors` from
`TestLogic.Type.UnificationErrors`, which describes how the module is checked
and which errors count as a mismatch. A comment inside each test of the
mismatch group sketches its program as Elm source.

Three facts about these programs matter. With nothing annotated, an integer
literal has the constrained type `number`, not `Int`. In the mock `Basics` of
`Compiler.Elm.Interface.Basic.testIfaces`, which the module is checked against,
`+` has type `number -> number -> number` and `<` has type
`comparable -> comparable -> Bool`. And the type checker accepts a tuple as
`comparable` only when each of its elements is `comparable`, which a function
never is.

The mismatch group expects a mismatch error for:

  - `f : String -> String` applied to `42`, in `x : String`;
  - an integer literal as the condition of an `if`;
  - an integer literal as the condition of an `if` whose `else` branch is
    another `if`;
  - an `if` whose `else` branch is another `if`, used as an operand of `++`
    while its branches are integer literals;
  - an `if` whose branches are an integer literal and a string;
  - a list of an integer literal and a string;
  - a `case` whose branches give an integer literal and a string;
  - `1 + "hello"`;
  - `<` between two tuples that hold a function: as the first element of a
    pair, as the middle and as the first element of a triple, and as the last
    element of a pair.

The two nested-`if` tests check the outer level of an `if` chain: its
condition and the tie between its type and its context. Both were once lost
under the JavaScript backend, where the stack-safe `if` walk in
`Compiler.Type.Constrain.Typed.Expression` built each level's constraint with
the innermost level's conditions and expectation.

The valid group expects no type errors for:

  - a list of three integer literals;
  - `if True then 1 else 2`;
  - `f x = x` applied to `42`;
  - `(1, 2) < (3, 4)` and `("a", 1) < ("b", 2)`.

Among what is not tested: where a mismatch is reported or which types
conflict, since only the kind of error is checked; annotated definitions; and
comparison with `>`, `<=` or `>=`, or of lists.

-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.UnificationErrors
    exposing
        ( expectNoTypeErrors
        , expectTypeMismatchError
        )


{-| Every test of this module: the mismatch group and the valid group.
-}
suite : Test
suite =
    Test.describe "Unification failures become type errors (TYPE_002)"
        [ typeMismatchTests
        , validTypeTests
        ]


{-| The mismatch group: tests that build an ill-typed module and expect a
mismatch error.
-}
typeMismatchTests : Test
typeMismatchTests =
    Test.describe "Type mismatch detection"
        [ Test.test "Int vs String in function argument" <|
            \_ ->
                let
                    -- f : String -> String
                    -- f s = s
                    -- x : String
                    -- x = f 42
                    modul =
                        SB.makeModuleWithTypedDefs "TypeMismatch"
                            [ { name = "f"
                              , args = [ SB.pVar "s" ]
                              , tipe = SB.tLambda (SB.tType "String" []) (SB.tType "String" [])
                              , body = SB.varExpr "s"
                              }
                            , { name = "x"
                              , args = []
                              , tipe = SB.tType "String" []
                              , body = SB.callExpr (SB.varExpr "f") [ SB.intExpr 42 ]
                              }
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "Int in if condition" <|
            \_ ->
                let
                    -- x = if 42 then 1 else 2
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
        , Test.test "Int in the outer condition of an if chain" <|
            \_ ->
                let
                    -- x = if 42 then 1 else if True then 2 else 3
                    modul =
                        SB.makeModuleWithDefs "IfChainCondMismatch"
                            [ ( "x"
                              , []
                              , SB.ifExpr
                                    (SB.intExpr 42)
                                    (SB.intExpr 1)
                                    (SB.ifExpr (SB.boolExpr True) (SB.intExpr 2) (SB.intExpr 3))
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "if chain of numbers used as a String" <|
            \_ ->
                let
                    -- x = (if True then 1 else if False then 2 else 3) ++ "a"
                    modul =
                        SB.makeModuleWithDefs "IfChainResultMismatch"
                            [ ( "x"
                              , []
                              , SB.binopsExpr
                                    [ ( SB.parensExpr
                                            (SB.ifExpr
                                                (SB.boolExpr True)
                                                (SB.intExpr 1)
                                                (SB.ifExpr (SB.boolExpr False) (SB.intExpr 2) (SB.intExpr 3))
                                            )
                                      , "++"
                                      )
                                    ]
                                    (SB.strExpr "a")
                              )
                            ]
                in
                expectTypeMismatchError modul
        , Test.test "mismatched if branches" <|
            \_ ->
                let
                    -- x = if True then 1 else "hello"
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
                    -- x = [1, "hello"]
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
                    --   _ -> "hello"
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
                    -- x = 1 + "hello"
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


{-| The valid group: tests that build a well-typed module and expect no type
errors.
-}
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
