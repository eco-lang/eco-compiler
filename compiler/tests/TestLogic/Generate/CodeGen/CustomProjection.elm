module TestLogic.Generate.CodeGen.CustomProjection exposing (expectCustomProjection)

{-| Nothing in the types of `Mlir.Mlir` stops the code generator from emitting
a malformed field read, so this module checks the generated MLIR for one.

An `eco.project.custom` op reads one field of a custom type value. Its one
operand is the value, its one result is the field, and its integer
`field_index` attribute says which field is read.

`expectCustomProjection` compiles a source module to MLIR with
`TestLogic.TestPipeline.runToMlir`. It fails when the pipeline returns an
error, and when any `eco.project.custom` op in the module, at any depth, has:

  - no `field_index` attribute holding an integer;
  - a negative `field_index`;
  - a number of operands other than one;
  - a number of results other than one.

An op with several of these faults is reported for the first of them in that
order. As `TestLogic.Generate.CodeGen.Invariants.violationsToExpectation`
describes, a failing test shows only the first violation.

Among what is not tested: whether `field_index` is less than the number of
fields the constructor has, whether the result type is the field's type, and
whether every field read of a custom type value uses `eco.project.custom` at
all.

@docs expectCustomProjection

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


{-| Compiles `srcModule` to MLIR and passes when no `eco.project.custom` op in
it has any of the faults the module docstring lists. When `runToMlir` returns
an error, fails with `Compilation failed:` and that error.
-}
expectCustomProjection : Src.Module -> Expectation
expectCustomProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomProjection mlirModule)


{-| Returns one violation for each malformed `eco.project.custom` op in the
module, at any depth, in the order the ops are walked.
-}
checkCustomProjection : MlirModule -> List Violation
checkCustomProjection mlirModule =
    let
        customProjectOps =
            findOpsNamed "eco.project.custom" mlirModule
    in
    List.filterMap checkCustomProjectOp customProjectOps


{-| Returns the violation for one `eco.project.custom` op, or `Nothing` when it
is well formed. Only the first fault is reported, checked in this order: no
integer `field_index`, a negative `field_index`, an operand count other than
one, a result count other than one.
-}
checkCustomProjectOp : MlirOp -> Maybe Violation
checkCustomProjectOp op =
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
                , message = "eco.project.custom missing field_index attribute"
                }

        Just fieldIndex ->
            if fieldIndex < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom field_index=" ++ String.fromInt fieldIndex ++ " is negative"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
