module TestLogic.Generate.CodeGen.TupleProjection exposing (expectTupleProjection)

{-| A check that the tuple projection ops the code generator emits are well
formed. Nothing in `Mlir.Mlir` stops it emitting one that names no field, names
a field the tuple does not have, or has the wrong number of operands or results,
and this check is what notices.

A projection reads one element of a two- or three-element tuple. It is an
`eco.project.tuple2` or `eco.project.tuple3` op whose single operand is the
tuple, whose single result is the element, and whose integer `field` attribute
is the element's zero-based index.

`expectTupleProjection` compiles a module to MLIR and, for each such op at any
nesting depth, reports the first of these that applies:

  - the `field` attribute is missing or is not an integer;
  - `field` is outside 0 to 1 for `eco.project.tuple2`, or 0 to 2 for
    `eco.project.tuple3`;
  - the op has other than one operand;
  - the op has other than one result.

Among what is not checked: whether tuple destructuring uses these ops rather
than some other op, and the types of the operand and result.

@docs expectTupleProjection

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


{-| Returns an expectation that `srcModule` compiles to MLIR through
`TestLogic.TestPipeline.runToMlir` and that no tuple projection in the MLIR
breaks the rules in the module docstring.

A compilation failure fails with `Compilation failed:` followed by the
pipeline's error. When there are violations, only the first is reported, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes, and
`eco.project.tuple2` violations come before `eco.project.tuple3` ones.

-}
expectTupleProjection : Src.Module -> Expectation
expectTupleProjection srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleProjection mlirModule)


{-| Returns the violations of the `eco.project.tuple2` ops in `mlirModule`,
followed by those of the `eco.project.tuple3` ops.
-}
checkTupleProjection : MlirModule -> List Violation
checkTupleProjection mlirModule =
    let
        tuple2Ops =
            findOpsNamed "eco.project.tuple2" mlirModule

        tuple2Violations =
            List.filterMap (checkTupleOp 2) tuple2Ops

        tuple3Ops =
            findOpsNamed "eco.project.tuple3" mlirModule

        tuple3Violations =
            List.filterMap (checkTupleOp 3) tuple3Ops
    in
    tuple2Violations ++ tuple3Violations


{-| Returns a violation for the first rule that `op` breaks as a projection from
a tuple of `tupleSize` elements, or `Nothing` when it breaks none. The rules are
tried in order: `field` present and an integer, `field` from 0 to
`tupleSize - 1`, one operand, one result.
-}
checkTupleOp : Int -> MlirOp -> Maybe Violation
checkTupleOp tupleSize op =
    let
        maybeField =
            getIntAttr "field" op

        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results

        maxField =
            tupleSize - 1

        tupleName =
            "eco.project.tuple" ++ String.fromInt tupleSize
    in
    case maybeField of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = tupleName ++ " missing field attribute"
                }

        Just field ->
            if field < 0 || field > maxField then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        tupleName
                            ++ " field="
                            ++ String.fromInt field
                            ++ " out of range [0,"
                            ++ String.fromInt maxField
                            ++ "]"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = tupleName ++ " should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = tupleName ++ " should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing
