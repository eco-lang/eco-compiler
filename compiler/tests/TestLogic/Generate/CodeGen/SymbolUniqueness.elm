module TestLogic.Generate.CodeGen.SymbolUniqueness exposing (expectSymbolUniqueness, checkSymbolUniqueness)

{-| Test logic for CGEN\_041: Symbol Uniqueness invariant.

Within a module, all symbol definitions must be unique: no two `func.func`
operations may have the same `sym_name`.

@docs expectSymbolUniqueness, checkSymbolUniqueness

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findSymbolOps
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that symbol uniqueness invariants hold for a source module.
-}
expectSymbolUniqueness : Src.Module -> Expectation
expectSymbolUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSymbolUniqueness mlirModule)


{-| Check symbol uniqueness invariants.
-}
checkSymbolUniqueness : MlirModule -> List Violation
checkSymbolUniqueness mlirModule =
    let
        symbolOps =
            findSymbolOps mlirModule

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
            []

        first :: rest ->
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
