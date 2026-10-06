module TestLogic.Generate.CodeGen.RecordProjection exposing (expectRecordProjection)

{-| Checks the shape of every record field read in the MLIR generated for a
test program, so that a read with a missing or negative field index, or with
the wrong number of operands or results, fails a test.

The code generator reads a field of a record with an `eco.project.record` op.
Its one operand is the record, its one result is the field, and its
`field_index` attribute is the field's position in the record's layout, which
`Compiler.Generate.MLIR.Types` decides. The op is built only by
`Compiler.Generate.MLIR.Ops.ecoProjectRecord`, which always gives it one
operand, one result and an integer `field_index`, so on generated code only
the non-negative `field_index` check could fail.

The program is supplied by the caller and compiled with
`TestLogic.TestPipeline.runToMlir`, the production pipeline.
`expectRecordProjection` fails if compilation fails, and otherwise reports a
violation for each `eco.project.record` op, at any depth in the module, for
the first of these it breaks:

  - `field_index` is present and is an integer;
  - `field_index` is not negative;
  - the op has exactly one operand;
  - the op has exactly one result.

A failing test shows only the first violation, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not checked: that `field_index` is less than the number of fields
in the record's layout or names the field the program reads, the op's result
type, and that every record field read uses this op.

@docs expectRecordProjection

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
every `eco.project.record` op in it has a non-negative integer `field_index`,
one operand and one result.

It fails, with a message starting `Compilation failed:`, when the program
does not compile.

-}
expectRecordProjection : Src.Module -> Expectation
expectRecordProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordProjection mlirModule)


{-| Returns one violation for each `eco.project.record` op in `mlirModule`, at
any depth, that lacks an integer `field_index`, has a negative one, or does not
have exactly one operand and one result.
-}
checkRecordProjection : MlirModule -> List Violation
checkRecordProjection mlirModule =
    let
        recordProjectOps =
            findOpsNamed "eco.project.record" mlirModule
    in
    List.filterMap checkRecordProjectOp recordProjectOps


{-| Returns a violation for the first rule `op` breaks, testing the
`field_index` before the operand count and the operand count before the result
count, or `Nothing` when it breaks none.
-}
checkRecordProjectOp : MlirOp -> Maybe Violation
checkRecordProjectOp op =
    let
        maybeFieldIndex =
            getIntAttr "field_index" op

        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results
    in
    case maybeFieldIndex of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.project.record missing field_index attribute"
                }

        Just fieldIndex ->
            if fieldIndex < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record field_index=" ++ String.fromInt fieldIndex ++ " is negative"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.record should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
