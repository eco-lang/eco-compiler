module TestLogic.Generate.CodeGen.CaseTagsCount exposing (expectCaseTagsCount)

{-| Checks that every `eco.case` the code generator emits carries one tag for
each of its alternatives, so that no alternative is left without a tag and no
tag is left without an alternative.

An `eco.case` chooses one of its regions, the alternatives, by the value of its
scrutinee. Its `tags` attribute is an array holding the tag for each
alternative, and nothing in `Mlir.Mlir` ties the length of that array to the
number of regions.

`expectCaseTagsCount` compiles the program it is given to MLIR with
`TestLogic.TestPipeline.runToMlir`, and fails when compilation fails. It then
finds every op named `eco.case`, at any depth, and fails when one has no `tags`
array attribute or when the array's length differs from the op's number of
regions. When several ops fail, only the first is reported, as
`violationsToExpectation` describes.

Among what is not tested: the values of the tags, the kind of their elements,
and the `string_patterns` attribute of a string case.

@docs expectCaseTagsCount

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


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
every `eco.case` in the result has a `tags` array as long as its list of
regions. It fails with the compiler's message if compilation fails.
-}
expectCaseTagsCount : Src.Module -> Expectation
expectCaseTagsCount srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseTagsCount mlirModule)


{-| Returns a violation for each `eco.case` in the module whose `tags` array
is missing or has a different length from its list of regions.
-}
checkCaseTagsCount : MlirModule -> List Violation
checkCaseTagsCount mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.filterMap checkCaseTagsMatch caseOps


{-| Returns a violation when the op has no `tags` array attribute, or when the
array's length differs from the number of the op's regions, and `Nothing`
otherwise. A `tags` attribute that is not an array is reported as missing.
-}
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
