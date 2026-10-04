module TestLogic.Generate.CodeGen.TupleConstruction exposing (expectTupleConstruction)

{-| A check that the code generator builds tuples with the tuple construction
ops, with every element supplied. Nothing in `Mlir.Mlir` stops it emitting a
tuple op with an element missing, or building a tuple through the generic
`eco.construct.custom` op, and this check is what notices.

A tuple of two or three elements has its own heap construction ops,
`eco.construct.tuple2` and `eco.construct.tuple3`, which take the elements as
their leading operands. The code generator's builders for them may append
GC-root hints after the elements, extra operands naming values to be kept as
garbage-collection roots, so an op with more operands than elements is
accepted, and only one with fewer is a violation.

`expectTupleConstruction` compiles a module to MLIR and reports, among the ops
at any nesting depth:

  - an `eco.construct.tuple2` with fewer than two operands;
  - an `eco.construct.tuple3` with fewer than three operands;
  - an `eco.construct.custom` whose `constructor` attribute is `Tuple2`,
    `Tuple3`, `(,)` or `(,,)`.

Among what is not checked: the value-level `eco.make.tuple2` and
`eco.make.tuple3` ops, an `eco.make.custom` with a tuple constructor name, an
`eco.construct.custom` that has no `constructor` attribute, and the types of
the operands.

@docs expectTupleConstruction

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


{-| Returns an expectation that `srcModule` compiles to MLIR through
`TestLogic.TestPipeline.runToMlir` and that the MLIR breaks none of the tuple
construction rules in the module docstring.

A compilation failure fails with `Compilation failed:` followed by the
pipeline's error. When there are violations, only the first is reported, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes:
`eco.construct.tuple2` violations come first, then `eco.construct.tuple3`,
then `eco.construct.custom`.

-}
expectTupleConstruction : Src.Module -> Expectation
expectTupleConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTupleConstruction mlirModule)


{-| Returns the violations in `mlirModule`: those of the `eco.construct.tuple2`
ops, then those of the `eco.construct.tuple3` ops, then the
`eco.construct.custom` ops that name a tuple constructor.
-}
checkTupleConstruction : MlirModule -> List Violation
checkTupleConstruction mlirModule =
    let
        tuple2Ops =
            findOpsNamed "eco.construct.tuple2" mlirModule

        tuple2Violations =
            List.filterMap checkTuple2OperandCount tuple2Ops

        tuple3Ops =
            findOpsNamed "eco.construct.tuple3" mlirModule

        tuple3Violations =
            List.filterMap checkTuple3OperandCount tuple3Ops

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        customViolations =
            List.filterMap checkForTupleConstructorMisuse customOps
    in
    tuple2Violations ++ tuple3Violations ++ customViolations


{-| Returns a violation when `op`, an `eco.construct.tuple2`, has fewer than two
operands. More are accepted, because operands after the two elements are GC-root
hints.
-}
checkTuple2OperandCount : MlirOp -> Maybe Violation
checkTuple2OperandCount op =
    let
        operandCount =
            List.length op.operands
    in
    if operandCount < 2 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.construct.tuple2 should have at least 2 operands, got " ++ String.fromInt operandCount
            }

    else
        Nothing


{-| Returns a violation when `op`, an `eco.construct.tuple3`, has fewer than
three operands. More are accepted, because operands after the three elements
are GC-root hints.
-}
checkTuple3OperandCount : MlirOp -> Maybe Violation
checkTuple3OperandCount op =
    let
        operandCount =
            List.length op.operands
    in
    if operandCount < 3 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.construct.tuple3 should have at least 3 operands, got " ++ String.fromInt operandCount
            }

    else
        Nothing


{-| Returns a violation when the `constructor` attribute of `op`, an
`eco.construct.custom`, is a name `isTupleConstructorName` accepts. An op
without that attribute gives no violation.
-}
checkForTupleConstructorMisuse : MlirOp -> Maybe Violation
checkForTupleConstructorMisuse op =
    let
        constructorName =
            getStringAttr "constructor" op
    in
    case constructorName of
        Just name ->
            if isTupleConstructorName name then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for tuple constructor '" ++ name ++ "', should use eco.construct.tuple2 or tuple3"
                    }

            else
                Nothing

        Nothing ->
            Nothing


{-| Tells whether `name` is one of the constructor names that mark a tuple:
`Tuple2`, `Tuple3`, `(,)` or `(,,)`.
-}
isTupleConstructorName : String -> Bool
isTupleConstructorName name =
    List.member name [ "Tuple2", "Tuple3", "(,)", "(,,)" ]
