module TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr)

{-| Checks that every `arith.cmpi` op in the MLIR generated for a program says
which comparison it makes, so that an integer comparison emitted without one is
caught.

An `arith.cmpi` compares two integers, and its `predicate` attribute is an
integer naming the comparison, in MLIR's numbering: 0 is `eq`, 1 is `ne`, 2 is
`slt`, and so on. This module treats an `arith.cmpi` without that attribute as
malformed.

A violation is reported for each `arith.cmpi`, at any depth, whose `predicate`
attribute is absent or is not an integer attribute. The value of the predicate
is not checked, so an integer outside MLIR's numbering passes, and nor are the
operands or the result.

@docs expectCmpiPredicateAttr

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


{-| Creates an expectation that `srcModule` compiles to MLIR in which every
`arith.cmpi` op has an integer `predicate` attribute.

The expectation fails with the test pipeline's error message, prefixed
`Compilation failed:`, if compilation fails. When several ops lack the
attribute, the failure reports only the first of them.

-}
expectCmpiPredicateAttr : Src.Module -> Expectation
expectCmpiPredicateAttr srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCmpiPredicateAttr mlirModule)


{-| Returns a violation for each `arith.cmpi` op of `mlirModule`, at any depth,
that has no integer `predicate` attribute.
-}
checkCmpiPredicateAttr : MlirModule -> List Violation
checkCmpiPredicateAttr mlirModule =
    let
        cmpiOps =
            findOpsNamed "arith.cmpi" mlirModule
    in
    List.filterMap checkCmpiOp cmpiOps


{-| Returns a violation if `op` has no integer `predicate` attribute, whatever
the op's name.
-}
checkCmpiOp : MlirOp -> Maybe Violation
checkCmpiOp op =
    case getIntAttr "predicate" op of
        Just _ ->
            Nothing

        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "arith.cmpi is missing required 'predicate' attribute"
                }
