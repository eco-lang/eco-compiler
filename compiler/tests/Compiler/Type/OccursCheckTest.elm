module Compiler.Type.OccursCheckTest exposing (suite)

{-| Test suite for invariant TYPE_004: Occurs check forbids infinite types.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.Type.OccursCheck exposing (expectInfiniteTypeDetected, expectNoInfiniteTypes)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Occurs check forbids infinite types (TYPE_004)"
        [ infiniteTypeTests
        , validTypeTests
        ]


infiniteTypeTests : Test
infiniteTypeTests =
    Test.describe "Infinite type detection"
        [ -- Note: Most infinite type scenarios are prevented by Elm's syntax
          -- and type system design. These tests verify the occurs check works
          -- for edge cases that might slip through.
          Test.test "self-referential through function application" <|
            \_ ->
                -- f x = f creates an infinite type: f : a -> ∞
                -- The type of f would need to satisfy: f : a -> f_type where f_type = a -> f_type
                -- Elm correctly detects and rejects this as an infinite type.
                let
                    modul =
                        SB.makeModuleWithDefs "SelfRef"
                            [ ( "f"
                              , [ SB.pVar "x" ]
                              , SB.varExpr "f"
                              )
                            ]
                in
                expectInfiniteTypeDetected modul
        ]


validTypeTests : Test
validTypeTests =
    Test.describe "Valid types without cycles"
        [ Test.test "simple identity function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Identity"
                            [ ( "id", [ SB.pVar "x" ], SB.varExpr "x" ) ]
                in
                expectNoInfiniteTypes modul
        , Test.test "composition function" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Compose"
                            [ ( "compose"
                              , [ SB.pVar "f", SB.pVar "g", SB.pVar "x" ]
                              , SB.callExpr (SB.varExpr "f")
                                    [ SB.callExpr (SB.varExpr "g") [ SB.varExpr "x" ] ]
                              )
                            ]
                in
                expectNoInfiniteTypes modul
        , Test.test "nested data structures" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Nested"
                            [ ( "nested"
                              , []
                              , SB.listExpr
                                    [ SB.tupleExpr (SB.intExpr 1) (SB.strExpr "a")
                                    , SB.tupleExpr (SB.intExpr 2) (SB.strExpr "b")
                                    ]
                              )
                            ]
                in
                expectNoInfiniteTypes modul
        ]
