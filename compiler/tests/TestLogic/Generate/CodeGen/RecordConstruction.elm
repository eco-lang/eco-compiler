module TestLogic.Generate.CodeGen.RecordConstruction exposing (expectRecordConstruction)

{-| Checks the `field_count` attribute of every record construction in the MLIR
generated for a test program, so that a construction whose count is missing,
zero or different from its number of operands fails a test.

The code generator builds a non-empty record with an `eco.construct.record` op.
Its operands are exactly the field values, and `field_count` says how many
there are. The empty record is
never constructed this way: it is an `eco.constant`. Both choices are made in
`Compiler.Generate.MLIR.Expr`, and the op is built only by
`Compiler.Generate.MLIR.Ops.ecoConstructRecord`.

The program is supplied by the caller and compiled with
`TestLogic.TestPipeline.runToMlir`, the production pipeline.
`expectRecordConstruction` fails if compilation fails, and otherwise reports a
violation for each `eco.construct.record` op, at any depth in the module, whose
`field_count`:

  - is absent or not an integer;
  - is 0 or negative;
  - differs from the op's number of operands.

A failing test shows only the first violation, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not checked: that `field_count` equals the number of fields of
the record's type, and that an empty record is an `eco.constant` (only
that no construction has a count of 0).

@docs expectRecordConstruction

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
every `eco.construct.record` op in it has a positive integer `field_count` no
larger than its number of operands.

It fails, with a message starting `Compilation failed:`, when the program
does not compile.

-}
expectRecordConstruction : Src.Module -> Expectation
expectRecordConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordConstruction mlirModule)


{-| Returns one violation for each `eco.construct.record` op in `mlirModule`, at
any depth, whose `field_count` is absent, not an integer, 0, negative, or larger
than its operand count.
-}
checkRecordConstruction : MlirModule -> List Violation
checkRecordConstruction mlirModule =
    let
        recordOps =
            findOpsNamed "eco.construct.record" mlirModule
    in
    List.filterMap checkRecordOp recordOps


{-| Returns a violation saying what is wrong with `op`, or `Nothing` when its
`field_count` is a positive integer not larger than its operand count.
-}
checkRecordOp : MlirOp -> Maybe Violation
checkRecordOp op =
    let
        maybeFieldCount =
            getIntAttr "field_count" op

        operandCount =
            List.length op.operands
    in
    case maybeFieldCount of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.record missing field_count attribute"
                }

        Just 0 ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.record with field_count=0, should use eco.constant EmptyRec"
                }

        Just fieldCount ->
            if fieldCount < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.record with negative field_count=" ++ String.fromInt fieldCount
                    }

            else if operandCount /= fieldCount then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.construct.record field_count ("
                            ++ String.fromInt fieldCount
                            ++ ") differs from operand count ("
                            ++ String.fromInt operandCount
                            ++ ")"
                    }

            else
                Nothing
