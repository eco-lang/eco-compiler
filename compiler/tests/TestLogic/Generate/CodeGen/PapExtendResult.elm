module TestLogic.Generate.CodeGen.PapExtendResult exposing (expectPapExtendResult, checkPapExtendResult)

{-| Checks that the code generator builds every `eco.papExtend` op with one
result of a type a closure application can return and, unless it is a generic
or segmentation-unknown application, with its arity recorded, so that an op
built otherwise fails a test (CGEN\_034, CGEN\_056, CGEN\_058).

A _partial application_ (PAP) is a function value together with the
arguments it has been given so far. An `eco.papExtend` op gives a PAP more
arguments. It may carry an integer `remaining_arity` attribute, whose value
`TestLogic.Generate.CodeGen.PapExtendArity` checks where it can, and a string
`_call_kind` attribute naming the kind of application. An op without
`remaining_arity` is in _generic mode_: the runtime decides saturation from the
closure header.

`expectPapExtendResult` compiles a program with `TestPipeline.runToMlir` and
fails if compilation fails. Otherwise it looks at every `eco.papExtend` op at
any depth of the module and reports one with:

  - a number of results other than one;
  - a result type other than `!eco.value` (a boxed value) or one of the
    primitives `i64`, `i16` and `f64`, in either mode. In particular an `i1`
    result is rejected: a Bool crosses the closure boundary boxed
    (REP\_ABI\_001, CGEN\_009), and a typed-mode result is the callee's
    result type (CGEN\_056), so it is never `i1` either. `PapExtendOp::verify`
    in `runtime/src/codegen/EcoOps.cpp` enforces this set in both modes, and in
    typed mode also requires `!eco.value` for a partial application and checks
    a saturated result against the evaluator's result type when the evaluator
    is known (`PapExtendOp::verifySymbolUses`);
  - no integer `remaining_arity` attribute, unless its `_call_kind` is
    `generic_apply` or `segmentation_unknown`.

When there are violations the expectation reports only the first, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not tested here: the value of `remaining_arity`; whether a typed
result matches the return type of the function being applied (the C++ verifier
checks it where it can see the evaluator); whether a
`generic_apply` or `segmentation_unknown` op that does carry `remaining_arity`
should; and whether a generic-mode op's `_result_kind` agrees with its result
type, which the C++ verifier does not check either.

@docs expectPapExtendResult, checkPapExtendResult

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
result, a valid result type, then an integer `remaining_arity`
present. An op with no `remaining_arity` passes the last rule when its
`_call_kind` is `generic_apply` or `segmentation_unknown`.
-}
checkPapExtendOp : MlirOp -> Maybe Violation
checkPapExtendOp op =
    let
        maybeRemainingArity =
            getIntAttr "remaining_arity" op

        callKindText =
            case getStringAttr "_call_kind" op of
                Just kind ->
                    " (_call_kind " ++ kind ++ ")"

                Nothing ->
                    ""
    in
    case op.results of
        [ ( _, resultType ) ] ->
            if not (isValidPapExtendResultType resultType) then
                let
                    mode =
                        if maybeRemainingArity == Nothing then
                            "generic-mode eco.papExtend (no remaining_arity)"

                        else
                            "typed-mode eco.papExtend"
                in
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = mode ++ callKindText ++ " result should be !eco.value, i16, i64, or f64, got " ++ typeToString resultType
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

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.papExtend should have exactly 1 result, got " ++ String.fromInt (List.length op.results)
                }


{-| Returns whether `t` is `!eco.value`, `i16`, `i64` or `f64`, the result
types an `eco.papExtend` op may have in either mode. `PapExtendOp::verify`
accepts the same set on a generic-mode op.
-}
isValidPapExtendResultType : MlirType -> Bool
isValidPapExtendResultType t =
    case t of
        NamedStruct name ->
            name == "eco.value"

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
