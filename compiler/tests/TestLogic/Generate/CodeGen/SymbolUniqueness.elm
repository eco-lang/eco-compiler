module TestLogic.Generate.CodeGen.SymbolUniqueness exposing (expectSymbolUniqueness)

{-| An MLIR op such as a function can define a name, its `sym_name`
attribute, by which other ops refer to it, and this module checks that no two
top-level ops of generated MLIR define the same name.

`expectSymbolUniqueness` compiles a source module to MLIR and fails if
compilation fails or if two or more of the module's top-level ops carry the
same `sym_name`, whatever kind of op they are. For each name defined more than
once, every definition but one is a violation, and a failure shows only the
first violation, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not checked: ops nested in another op's regions are not searched,
and whether every name that is referred to is defined somewhere is not checked.

@docs expectSymbolUniqueness

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findSymbolOps
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR with
no `sym_name` defined twice among the top-level ops, and fails with
`Compilation failed:` and the error when compilation fails.
-}
expectSymbolUniqueness : Src.Module -> Expectation
expectSymbolUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSymbolUniqueness mlirModule)


{-| Returns a violation for every top-level op whose `sym_name` another
top-level op also carries, except the last op of each name in module order,
whose id every other op's message gives as where the name is already defined.
Violations are ordered by name.
-}
checkSymbolUniqueness : MlirModule -> List Violation
checkSymbolUniqueness mlirModule =
    let
        symbolOps =
            findSymbolOps mlirModule

        -- Prepending leaves each name's ops in reverse module order.
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
    in
    Dict.toList grouped
        |> List.concatMap checkDuplicates


{-| Returns a violation for every op in `ops` after the first, each naming
`symName` and the first op's id. A list of fewer than two ops gives none.
-}
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
