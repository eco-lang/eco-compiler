module Compiler.Generate.CodeGen.PapExtendResult exposing
    ( expectPapExtendResult
    , checkPapExtendResult
    )

{-| Test logic for CGEN_034: PapExtend Result Type invariant.

`eco.papExtend` must produce a valid result type:

  - `!eco.value` (boxed result)
  - `i1` (typed primitive result - Bool)
  - `i64` (typed primitive result)
  - `f64` (typed primitive result)

@docs expectPapExtendResult, checkPapExtendResult

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))


{-| Verify that papExtend result type invariants hold for a source module.
-}
expectPapExtendResult : Src.Module -> Expectation
expectPapExtendResult srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendResult mlirModule)


{-| Check papExtend result type invariants.
-}
checkPapExtendResult : MlirModule -> List Violation
checkPapExtendResult mlirModule =
    let
        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        violations =
            List.filterMap checkPapExtendOp papExtendOps
    in
    violations


checkPapExtendOp : MlirOp -> Maybe Violation
checkPapExtendOp op =
    let
        resultCount =
            List.length op.results

        maybeRemainingArity =
            getIntAttr "remaining_arity" op
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.papExtend should have exactly 1 result, got " ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Nothing ->
                Nothing

            Just ( _, resultType ) ->
                if not (isValidPapExtendResultType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.papExtend result should be !eco.value, i1, i64, or f64, got " ++ typeToString resultType
                        }

                else
                    case maybeRemainingArity of
                        Nothing ->
                            Just
                                { opId = op.id
                                , opName = op.name
                                , message = "eco.papExtend missing remaining_arity attribute"
                                }

                        Just _ ->
                            Nothing


{-| Check if the type is a valid result type for eco.papExtend.
Valid types are: !eco.value, i1, i64, f64
-}
isValidPapExtendResultType : MlirType -> Bool
isValidPapExtendResultType t =
    case t of
        NamedStruct name ->
            name == "eco.value"

        I1 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


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
