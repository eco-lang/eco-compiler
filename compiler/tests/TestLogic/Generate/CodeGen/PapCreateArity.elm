module TestLogic.Generate.CodeGen.PapCreateArity exposing (expectPapCreateArity)

{-| The code generator builds closures with `eco.papCreate` ops, and nothing in
`Mlir.Mlir` stops one from being built with attributes that do not describe a
partial application. This module checks those attributes.

An `eco.papCreate` builds a partial application object (PAP): a closure over
the function named by its `function` attribute. Its `arity` attribute records
the total number of arguments the closure stands for, captured values plus those
still to be supplied, and `num_captured` how many of them the closure already
holds. The captured values are the op's operands.

`expectPapCreateArity` compiles a program to MLIR and, for each
`eco.papCreate` in the result, checks that:

  - `arity` is present as an integer and is greater than zero;
  - `num_captured` is present as an integer and equals the number of operands;
  - `num_captured` is less than `arity`, since holding every argument would
    make a full application rather than a partial one;
  - `function` is present as a string or a symbol reference.

Among what is not tested: whether `function` names a function that exists,
whether `arity` is consistent with the function `function` names, whether the
operand types match its parameters, and closures built by `eco.papCreateGroup`,
which this check does not look at.

@docs expectPapCreateArity

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR with
`runToMlir` and every `eco.papCreate` in the result has the attributes the
module docstring lists.

A failed compilation fails with its error. Otherwise only the first violation
found is reported, as `violationsToExpectation` describes.

-}
expectPapCreateArity : Src.Module -> Expectation
expectPapCreateArity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapCreateArity mlirModule)


{-| Returns the violations of every `eco.papCreate` op in `mlirModule`, at any
depth.
-}
checkPapCreateArity : MlirModule -> List Violation
checkPapCreateArity mlirModule =
    let
        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule
    in
    List.concatMap checkPapCreateOp papCreateOps


{-| Returns the violations of one `eco.papCreate` op, in a fixed order: a
missing or non-positive `arity`, a missing `num_captured` or one that differs
from the operand count, `num_captured` not less than `arity`, and a missing
`function`.

An attribute of another kind than the one expected counts as missing. The
comparison of `num_captured` with `arity` is made only when both are present.

-}
checkPapCreateOp : MlirOp -> List Violation
checkPapCreateOp op =
    let
        maybeArity =
            getIntAttr "arity" op

        maybeNumCaptured =
            getIntAttr "num_captured" op

        maybeFuncAttr =
            getStringAttr "function" op

        operandCount =
            List.length op.operands
    in
    List.filterMap identity
        [ case maybeArity of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing arity attribute"
                    }

            Just arity ->
                if arity <= 0 then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.papCreate arity must be > 0, got " ++ String.fromInt arity
                        }

                else
                    Nothing
        , case maybeNumCaptured of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing num_captured attribute"
                    }

            Just numCaptured ->
                if numCaptured /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.papCreate num_captured="
                                ++ String.fromInt numCaptured
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else
                    Nothing
        , case ( maybeArity, maybeNumCaptured ) of
            ( Just arity, Just numCaptured ) ->
                if numCaptured >= arity then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.papCreate num_captured="
                                ++ String.fromInt numCaptured
                                ++ " >= arity="
                                ++ String.fromInt arity
                                ++ ", not a valid partial application"
                        }

                else
                    Nothing

            _ ->
                Nothing
        , case maybeFuncAttr of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing function attribute"
                    }

            Just _ ->
                Nothing
        ]
