module TestLogic.Generate.CodeGen.CaseTagsCount exposing (expectCaseTagsCount, checkCaseTagsCount)

{-| Test logic for CGEN\_029: Case Tags Count invariant.

The `eco.case` `tags` array length must equal the number of alternative regions.

@docs expectCaseTagsCount, checkCaseTagsCount

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that case tags count invariants hold for a source module.
-}
expectCaseTagsCount : Src.Module -> Expectation
expectCaseTagsCount srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTagsCount mlirModule)


{-| Check case tags count invariants.
-}
checkCaseTagsCount : MlirModule -> List Violation
checkCaseTagsCount mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseTagsMatch caseOps
    in
    violations


checkCaseTagsMatch : MlirOp -> Maybe Violation
checkCaseTagsMatch op =
    let
        maybeTagsAttr =
            getArrayAttr "tags" op

        regionCount =
            List.length op.regions
    in
    case maybeTagsAttr of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.case missing tags attribute"
                }

        Just tags ->
            let
                tagCount =
                    List.length tags
            in
            if tagCount /= regionCount then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.case tags count ("
                            ++ String.fromInt tagCount
                            ++ ") != region count ("
                            ++ String.fromInt regionCount
                            ++ ")"
                    }

            else
                Nothing
