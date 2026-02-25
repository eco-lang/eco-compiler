module TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction)

{-| Test logic for CGEN\_016: List Construction invariant.

List values must use `eco.construct.list` for cons cells and `eco.constant Nil`
for empty lists; never `eco.construct.custom`.

@docs expectListConstruction

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that list construction invariants hold for a source module.

This compiles the module to MLIR and checks that list construction uses
proper operations (eco.construct.list, eco.constant Nil) instead of
eco.construct.custom.

-}
expectListConstruction : Src.Module -> Expectation
expectListConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListConstruction mlirModule)


{-| Check that list construction uses proper operations.
-}
checkListConstruction : MlirModule -> List Violation
checkListConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.filterMap checkForListConstructorMisuse customOps


{-| Check if an eco.construct.custom op is incorrectly used for list construction.
-}
checkForListConstructorMisuse : MlirOp -> Maybe Violation
checkForListConstructorMisuse op =
    let
        constructorName =
            getStringAttr "constructor" op
    in
    case constructorName of
        Just name ->
            if isListConstructorName name then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for list constructor '" ++ name ++ "', should use eco.construct.list or eco.constant Nil"
                    }

            else
                Nothing

        Nothing ->
            Nothing


isListConstructorName : String -> Bool
isListConstructorName name =
    List.member name [ "Cons", "Nil", "List.Cons", "List.Nil", "::" ]
