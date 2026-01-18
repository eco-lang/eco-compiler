module Compiler.Generate.CodeGen.SymbolUniquenessTest exposing (suite)

{-| Tests for CGEN_041: Symbol Uniqueness invariant.

Within a module, all symbol definitions must be unique: no two `func.func`
operations may have the same `sym_name`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , define
        , listExpr
        , makeModule
        , pVar
        , qualVarExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findSymbolOps
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_041: Symbol Uniqueness"
        [ Test.test "Simple value bindings have unique names" simpleValuesTest
        , Test.test "Multiple lambdas have unique names" multipleLambdasTest
        , Test.test "Nested lets generate unique symbols" nestedLetsTest
        , Test.test "Functions with negate have unique names" negateTest
        ]



-- INVARIANT CHECKER


{-| Check symbol uniqueness invariants.
-}
checkSymbolUniqueness : MlirModule -> List Violation
checkSymbolUniqueness mlirModule =
    let
        symbolOps =
            findSymbolOps mlirModule

        -- Group by symbol name
        grouped =
            List.foldl
                (\( name, op ) acc ->
                    Dict.update name
                        (\existing ->
                            case existing of
                                Nothing ->
                                    Just [ op ]

                                Just ops ->
                                    Just (op :: ops)
                        )
                        acc
                )
                Dict.empty
                symbolOps

        -- Find duplicates
        violations =
            Dict.toList grouped
                |> List.concatMap checkDuplicates
    in
    violations


checkDuplicates : ( String, List MlirOp ) -> List Violation
checkDuplicates ( symName, ops ) =
    case ops of
        [] ->
            []

        [ _ ] ->
            -- Single definition, OK
            []

        first :: rest ->
            -- Multiple definitions - report all but first as duplicates
            List.map
                (\op ->
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Duplicate symbol '"
                            ++ symName
                            ++ "': already defined at "
                            ++ first.id
                    }
                )
                rest



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSymbolUniqueness mlirModule)



-- TEST CASES


simpleValuesTest : () -> Expectation
simpleValuesTest _ =
    -- Multiple distinct value bindings (no parameters)
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" [] (intExpr 1)
                    , define "b" [] (intExpr 2)
                    , define "c" [] (intExpr 3)
                    ]
                    (varExpr "a")
                )
    in
    runInvariantTest modul


multipleLambdasTest : () -> Expectation
multipleLambdasTest _ =
    -- Multiple anonymous functions should each get unique names
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" []
                        (callExpr
                            (callExpr (qualVarExpr "List" "map")
                                [ lambdaExpr [ pVar "x" ] (varExpr "x") ]
                            )
                            [ listExpr [ intExpr 1, intExpr 2 ] ]
                        )
                    , define "b" []
                        (callExpr
                            (callExpr (qualVarExpr "List" "map")
                                [ lambdaExpr [ pVar "y" ] (varExpr "y") ]
                            )
                            [ listExpr [ intExpr 3, intExpr 4 ] ]
                        )
                    ]
                    (varExpr "a")
                )
    in
    runInvariantTest modul


nestedLetsTest : () -> Expectation
nestedLetsTest _ =
    -- Nested let expressions should all get unique symbols
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "outer" [] (intExpr 1) ]
                    (letExpr
                        [ define "inner" [] (intExpr 2) ]
                        (varExpr "inner")
                    )
                )
    in
    runInvariantTest modul


negateTest : () -> Expectation
negateTest _ =
    -- Multiple functions using negate should get unique names
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "negA" []
                        (callExpr (qualVarExpr "Basics" "negate") [ intExpr 1 ])
                    , define "negB" []
                        (callExpr (qualVarExpr "Basics" "negate") [ intExpr 2 ])
                    ]
                    (varExpr "negA")
                )
    in
    runInvariantTest modul
