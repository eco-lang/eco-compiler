module TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr, expectCmpiPresentWithPredicate)

{-| Checks that every `arith.cmpi` op in the MLIR generated for a program says
which comparison it makes, so that an integer comparison emitted without one is
caught.

An `arith.cmpi` compares two integers, and its `predicate` attribute is an
integer naming the comparison, in MLIR's numbering: 0 is `eq`, 1 is `ne`, 2 is
`slt`, and so on. This module treats an `arith.cmpi` without that attribute as
malformed.

A violation is reported for each `arith.cmpi`, at any depth, whose `predicate`
attribute is absent, is not an integer attribute, or is outside MLIR's
numbering 0 (`eq`) to 9 (`uge`). The operands and the result are not checked.

`expectCmpiPredicateAttr` passes a program with no `arith.cmpi`;
`expectCmpiPresentWithPredicate` also requires at least one, for a focused test
whose subject is the comparison.

@docs expectCmpiPredicateAttr, expectCmpiPresentWithPredicate

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
`Compilation failed:`, if compilation fails, and otherwise with every
violation. A program with no `arith.cmpi` passes.

-}
expectCmpiPredicateAttr : Src.Module -> Expectation
expectCmpiPredicateAttr srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCmpiPredicateAttr mlirModule)


{-| Like `expectCmpiPredicateAttr`, and also fails when the generated MLIR
holds no `arith.cmpi` at all.
-}
expectCmpiPresentWithPredicate : Src.Module -> Expectation
expectCmpiPresentWithPredicate srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            if List.isEmpty (findOpsNamed "arith.cmpi" mlirModule) then
                Expect.fail "Expected at least one arith.cmpi, found none"

            else
                violationsToExpectation (checkCmpiPredicateAttr mlirModule)


{-| Returns a violation for each `arith.cmpi` op of `mlirModule`, at any depth,
that has no integer `predicate` attribute in MLIR's range 0 to 9.
-}
checkCmpiPredicateAttr : MlirModule -> List Violation
checkCmpiPredicateAttr mlirModule =
    let
        cmpiOps =
            findOpsNamed "arith.cmpi" mlirModule
    in
    List.filterMap checkCmpiOp cmpiOps


{-| Returns a violation if `op` has no integer `predicate` attribute in the
range 0 to 9, whatever the op's name.
-}
checkCmpiOp : MlirOp -> Maybe Violation
checkCmpiOp op =
    case getIntAttr "predicate" op of
        Just predicate ->
            if predicate >= 0 && predicate <= 9 then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "arith.cmpi predicate " ++ String.fromInt predicate ++ " is outside MLIR's range 0..9"
                    }

        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "arith.cmpi is missing required 'predicate' attribute"
                }
