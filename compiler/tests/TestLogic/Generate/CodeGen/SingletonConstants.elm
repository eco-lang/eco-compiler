module TestLogic.Generate.CodeGen.SingletonConstants exposing (expectSingletonConstants, checkSingletonConstants)

{-| Test logic for CGEN\_019: Singleton Constants invariant.

Well-known singletons (Unit, True, False, Nil, Nothing, EmptyString, EmptyRec)
must always use `eco.constant`, never `eco.construct.custom`.

@docs expectSingletonConstants, checkSingletonConstants

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )


{-| Verify that singleton constants invariants hold for a source module.
-}
expectSingletonConstants : Src.Module -> Expectation
expectSingletonConstants srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSingletonConstants mlirModule)


{-| Known singleton kind values (from Ops.td):

  - Unit = 1
  - EmptyRec = 2
  - True = 3
  - False = 4
  - Nil = 5
  - Nothing = 6
  - EmptyString = 7

-}
knownSingletonKinds : List Int
knownSingletonKinds =
    [ 1, 2, 3, 4, 5, 6, 7 ]


{-| Check singleton constant invariants.
-}
checkSingletonConstants : MlirModule -> List Violation
checkSingletonConstants mlirModule =
    let
        constantOps =
            findOpsNamed "eco.constant" mlirModule

        constantViolations =
            List.filterMap checkConstantKind constantOps

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        customViolations =
            List.filterMap checkForSingletonMisuse customOps

        stringOps =
            findOpsNamed "eco.string_literal" mlirModule

        stringViolations =
            List.filterMap checkEmptyStringLiteral stringOps
    in
    constantViolations ++ customViolations ++ stringViolations


checkConstantKind : MlirOp -> Maybe Violation
checkConstantKind op =
    let
        maybeKind =
            getIntAttr "kind" op
    in
    case maybeKind of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.constant missing kind attribute"
                }

        Just kind ->
            if not (List.member kind knownSingletonKinds) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.constant with unknown kind " ++ String.fromInt kind
                    }

            else
                Nothing


checkForSingletonMisuse : MlirOp -> Maybe Violation
checkForSingletonMisuse op =
    let
        maybeConstructorName =
            getStringAttr "constructor" op
    in
    case maybeConstructorName of
        Just name ->
            if List.member name [ "True", "False", "Nothing", "Nil", "Unit" ] then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for singleton '" ++ name ++ "', should use eco.constant"
                    }

            else
                Nothing

        Nothing ->
            Nothing


checkEmptyStringLiteral : MlirOp -> Maybe Violation
checkEmptyStringLiteral op =
    let
        maybeValue =
            getStringAttr "value" op
    in
    case maybeValue of
        Just "" ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "Empty string should use eco.constant EmptyString, not eco.string_literal"
                }

        _ ->
            Nothing
