module TestLogic.Generate.CodeGen.TypeTableUniqueness exposing (expectTypeTableUniqueness)

{-| Test logic for CGEN\_035: Type Table Uniqueness invariant.

Each module must have at most one `eco.type_table` op at module scope.

@docs expectTypeTableUniqueness

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that type table uniqueness invariants hold for a source module.
-}
expectTypeTableUniqueness : Src.Module -> Expectation
expectTypeTableUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTypeTableUniqueness mlirModule)


{-| Check type table uniqueness invariants.
-}
checkTypeTableUniqueness : MlirModule -> List Violation
checkTypeTableUniqueness mlirModule =
    let
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        typeTableCount =
            List.length typeTableOps
    in
    if typeTableCount > 1 then
        [ { opId = "module"
          , opName = "module"
          , message =
                "Module has "
                    ++ String.fromInt typeTableCount
                    ++ " eco.type_table ops, expected at most 1"
          }
        ]

    else
        []
