module TestLogic.Type.PostSolve.KernelTypesTest exposing (suite)

{-| Test suite for invariant POST\_002: Kernel types are correctly resolved.
-}

import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)


suite : Test
suite =
    Test.describe "Kernel types are correctly resolved (POST_002)"
        [ kernelTypeTests
        ]


kernelTypeTests : Test
kernelTypeTests =
    Test.describe "Kernel type resolution"
        [ Test.test "Int literals have Int type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "IntLit"
                            [ ( "x", [], SB.intExpr 42 ) ]
                in
                expectKernelTypesValid modul
        , Test.test "Float literals have Float type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "FloatLit"
                            [ ( "x", [], SB.floatExpr 3.14 ) ]
                in
                expectKernelTypesValid modul
        , Test.test "String literals have String type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "StrLit"
                            [ ( "x", [], SB.strExpr "hello" ) ]
                in
                expectKernelTypesValid modul
        , Test.test "List of Ints has List Int type" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ListInt"
                            [ ( "xs", [], SB.listExpr [ SB.intExpr 1, SB.intExpr 2, SB.intExpr 3 ] ) ]
                in
                expectKernelTypesValid modul
        ]
