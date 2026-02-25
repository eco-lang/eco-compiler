module TestLogic.Generate.CodeGen.PapCreateArity exposing (expectPapCreateArity, checkPapCreateArity)

{-| Test logic for CGEN\_033: PapCreate Arity Constraints invariant.

`eco.papCreate` requires:

  - `arity > 0`
  - `num_captured == operand count`
  - `num_captured < arity`

@docs expectPapCreateArity, checkPapCreateArity

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


{-| Verify that papCreate arity constraint invariants hold for a source module.
-}
expectPapCreateArity : Src.Module -> Expectation
expectPapCreateArity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapCreateArity mlirModule)


{-| Check papCreate arity constraint invariants.
-}
checkPapCreateArity : MlirModule -> List Violation
checkPapCreateArity mlirModule =
    let
        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        violations =
            List.concatMap checkPapCreateOp papCreateOps
    in
    violations


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
