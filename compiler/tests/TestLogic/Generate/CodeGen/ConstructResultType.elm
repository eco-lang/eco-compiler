module TestLogic.Generate.CodeGen.ConstructResultType exposing (expectConstructResultType, checkConstructResultTypes)

{-| Test logic for CGEN\_025: Construct Result Types invariant.

All `eco.construct.*` ops must produce `!eco.value` result type.

@docs expectConstructResultType, checkConstructResultTypes

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsWithPrefix
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that construct result type invariants hold for a source module.
-}
expectConstructResultType : Src.Module -> Expectation
expectConstructResultType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkConstructResultTypes mlirModule)


{-| Check that all construct ops produce !eco.value result.
-}
checkConstructResultTypes : MlirModule -> List Violation
checkConstructResultTypes mlirModule =
    let
        constructOps =
            findOpsWithPrefix "eco.construct." mlirModule

        violations =
            List.filterMap checkConstructResultTypeSingle constructOps
    in
    violations


checkConstructResultTypeSingle : MlirOp -> Maybe Violation
checkConstructResultTypeSingle op =
    let
        resultCount =
            List.length op.results
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                op.name
                    ++ " should have exactly 1 result, has "
                    ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Just ( _, resultType ) ->
                if not (isEcoValueType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            op.name
                                ++ " result type should be !eco.value, got "
                                ++ typeToString resultType
                        }

                else
                    Nothing

            Nothing ->
                Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"
