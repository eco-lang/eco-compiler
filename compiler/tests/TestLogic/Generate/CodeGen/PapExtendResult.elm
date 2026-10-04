module TestLogic.Generate.CodeGen.PapExtendResult exposing (expectPapExtendResult)

{-| Checks that the code generator builds every `eco.papExtend` op with one
result of a type a closure application can return and, unless it is a generic
or segmentation-unknown application, with its arity recorded, so that an op
built otherwise fails a test.

A _partial application_ (PAP) is a function value together with the
arguments it has been given so far. An `eco.papExtend` op gives a PAP more
arguments. It may carry an integer `remaining_arity` attribute, whose value
`TestLogic.Generate.CodeGen.PapExtendArity` checks where it can, and a string
`_call_kind` attribute naming the kind of application.

`expectPapExtendResult` compiles a program with `TestPipeline.runToMlir` and
fails if compilation fails. Otherwise it looks at every `eco.papExtend` op at
any depth of the module and reports one with:

  - a number of results other than one;
  - a result type other than `!eco.value` (a boxed value) or one of the
    unboxed types `i1`, `i16`, `i64` and `f64`;
  - no integer `remaining_arity` attribute, unless its `_call_kind` is
    `generic_apply` or `segmentation_unknown`.

When there are violations the expectation reports only the first, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not tested: the value of `remaining_arity`; whether a typed
result matches the return type of the function being applied; and whether a
`generic_apply` or `segmentation_unknown` op that does carry `remaining_arity`
should.

@docs expectPapExtendResult

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
no `eco.papExtend` op breaks a rule listed in the module docstring. A
compilation failure fails the expectation with its error.
-}
expectPapExtendResult : Src.Module -> Expectation
expectPapExtendResult srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendResult mlirModule)


{-| Returns a violation for each `eco.papExtend` op in `mlirModule`, at any
depth, that breaks a rule listed in the module docstring.
-}
checkPapExtendResult : MlirModule -> List Violation
checkPapExtendResult mlirModule =
    let
        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule
    in
    List.filterMap checkPapExtendOp papExtendOps


{-| Returns a violation for the first rule `op` breaks, checking in order: one
result, a valid result type, then an integer `remaining_arity` present. An op
with no `remaining_arity` passes when its `_call_kind` is `generic_apply` or
`segmentation_unknown`.

The failure message for a bad result type lists `!eco.value`, `i1`, `i64` and
`f64` but not `i16`, which is accepted.

-}
checkPapExtendOp : MlirOp -> Maybe Violation
checkPapExtendOp op =
    let
        resultCount =
            List.length op.results

        maybeRemainingArity =
            getIntAttr "remaining_arity" op
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.papExtend should have exactly 1 result, got " ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Nothing ->
                Nothing

            Just ( _, resultType ) ->
                if not (isValidPapExtendResultType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.papExtend result should be !eco.value, i1, i64, or f64, got " ++ typeToString resultType
                        }

                else
                    case maybeRemainingArity of
                        Nothing ->
                            -- The generator builds these two kinds without remaining_arity.
                            if getStringAttr "_call_kind" op == Just "generic_apply" || getStringAttr "_call_kind" op == Just "segmentation_unknown" then
                                Nothing

                            else
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message = "eco.papExtend missing remaining_arity attribute"
                                    }

                        Just _ ->
                            Nothing


{-| Returns whether `t` is `!eco.value`, `i1`, `i16`, `i64` or `f64`, the
result types an `eco.papExtend` op may have.
-}
isValidPapExtendResultType : MlirType -> Bool
isValidPapExtendResultType t =
    case t of
        NamedStruct name ->
            name == "eco.value"

        I1 ->
            True

        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


{-| Returns a short name for `t` to use in a failure message. A named type is
given without its leading `!`, and a function type is `function`.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"
