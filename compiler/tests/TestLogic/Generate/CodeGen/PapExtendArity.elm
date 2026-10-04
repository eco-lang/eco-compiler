module TestLogic.Generate.CodeGen.PapExtendArity exposing (expectPapExtendArity)

{-| The code generator can write on an `eco.papExtend` how many arguments the
closure it extends was still waiting for, and nothing in the `Mlir.Mlir` types
checks that number. This module is the check, run on the MLIR compiled from a
test program.

A _PAP_ (partial application) is a closure value: a function together with the
arguments captured so far. `eco.papCreate` builds one; its `arity` attribute
counts the closure's captured values and parameters together, and its
`num_captured` attribute the captured values alone. `eco.papExtend` applies one to
more arguments, its _new arguments_: the operands after the first, which is the
PAP being extended, less the trailing GC-root operands that its
`eco.gc_roots_count` attribute counts. A PAP's _remaining arity_ is how many
arguments it still needs before its function runs. The `remaining_arity`
attribute of an `eco.papExtend` must be the remaining arity of the PAP it
extends before this application, not after it.

`expectPapExtendArity` compiles a source module with
`TestLogic.TestPipeline.runToMlir` and examines the MLIR one top-level op at a
time, so the same SSA name in two top-level ops is never confused. Within one
top-level op it first records the remaining arity of each PAP defined there:
`arity - num_captured` for an `eco.papCreate`, and `remaining_arity` less the
new arguments for an `eco.papExtend` whose result still needs at least one more
argument. It then reports, for each `eco.papExtend` in that op, the first of
these that applies:

  - a missing `remaining_arity`, unless the op's `_call_kind` attribute is
    `generic_apply` or `segmentation_unknown`, in which case nothing more is
    checked;
  - a negative `remaining_arity`;
  - no operands at all;
  - a `remaining_arity` different from the recorded remaining arity of the PAP
    it extends;
  - more new arguments than `remaining_arity`, which is an over-application.

The violations are turned into an expectation by
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation`.

Among what is not checked: the last two checks are skipped when the extended
PAP has no recorded remaining arity, as for a block argument, a value defined
in another top-level op, an `eco.papCreate` without integer `arity` and
`num_captured` attributes, or the result of an `eco.papExtend` that saturated
its PAP or has no `remaining_arity`. A recorded remaining arity taken from an
`eco.papExtend` trusts that op's own `remaining_arity`. The result type of an
`eco.papExtend` is not examined.

@docs expectPapExtendArity

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
no `eco.papExtend` in it breaks the rules in the module docstring.

When `runToMlir` fails, it fails with a message that starts
`Compilation failed:` and goes on with the pipeline's message.

-}
expectPapExtendArity : Src.Module -> Expectation
expectPapExtendArity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendArity mlirModule)


{-| Returns the violations of the `eco.papExtend` rules in `mlirModule`, each
top-level op checked on its own.
-}
checkPapExtendArity : MlirModule -> List Violation
checkPapExtendArity mlirModule =
    List.concatMap checkFunction mlirModule.body


{-| Returns the violations among the `eco.papExtend` ops nested at any depth in
`funcOp`, judged against the remaining arities of the PAPs defined in `funcOp`.

The remaining arities are all recorded before any `eco.papExtend` is checked,
so a PAP defined after its use in walk order is still found.

-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        allOpsInFunc =
            walkOpAndChildren funcOp

        papArityMap =
            buildPapArityMapForOps allOpsInFunc

        papExtendOps =
            List.filter (\op -> op.name == "eco.papExtend") allOpsInFunc
    in
    List.filterMap (checkPapExtendOp papArityMap) papExtendOps


{-| Returns the remaining arity of each PAP defined by `ops`, keyed by the SSA
name of the op's first result.

An `eco.papCreate` gives `arity - num_captured`, and is left out unless both
attributes are integers. An `eco.papExtend` gives its `remaining_arity` less
its new arguments, and is left out when that is zero or less or when it has
no integer `remaining_arity`.

-}
buildPapArityMapForOps : List MlirOp -> Dict String Int
buildPapArityMapForOps ops =
    let
        processOp : MlirOp -> Dict String Int -> Dict String Int
        processOp op map =
            if op.name == "eco.papCreate" then
                case ( List.head op.results, getIntAttr "arity" op, getIntAttr "num_captured" op ) of
                    ( Just ( resultName, _ ), Just arity, Just numCaptured ) ->
                        let
                            remaining =
                                arity - numCaptured
                        in
                        Dict.insert resultName remaining map

                    _ ->
                        map

            else if op.name == "eco.papExtend" then
                case ( List.head op.results, getIntAttr "remaining_arity" op ) of
                    ( Just ( resultName, _ ), Just remainingArity ) ->
                        let
                            rootCount =
                                Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                            numNewArgs =
                                List.length op.operands - 1 - rootCount

                            resultRemaining =
                                remainingArity - numNewArgs
                        in
                        if resultRemaining > 0 then
                            Dict.insert resultName resultRemaining map

                        else
                            map

                    _ ->
                        map

            else
                map
    in
    List.foldl processOp Dict.empty ops


{-| Returns the violation for the first rule that the `eco.papExtend` `op`
breaks, given the remaining arities recorded in `papArityMap`, or `Nothing` when
it breaks none.

The rules are tried in the order the module docstring lists them. The
comparison with the extended PAP and the over-application check are made only
when the first operand has an entry in `papArityMap`.

-}
checkPapExtendOp : Dict String Int -> MlirOp -> Maybe Violation
checkPapExtendOp papArityMap op =
    let
        maybeRemainingArity =
            getIntAttr "remaining_arity" op

        maybeSourcePap =
            List.head op.operands

        rootCount =
            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

        -- The trailing GC-root operands are not arguments.
        numNewArgs =
            List.length op.operands - 1 - rootCount
    in
    case maybeRemainingArity of
        Nothing ->
            if getStringAttr "_call_kind" op == Just "generic_apply" || getStringAttr "_call_kind" op == Just "segmentation_unknown" then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papExtend missing remaining_arity attribute"
                    }

        Just remainingArity ->
            if remainingArity < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.papExtend remaining_arity="
                            ++ String.fromInt remainingArity
                            ++ " is negative"
                    }

            else
                case maybeSourcePap of
                    Nothing ->
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message = "eco.papExtend has no source PAP operand"
                            }

                    Just sourcePapName ->
                        case Dict.get sourcePapName papArityMap of
                            Nothing ->
                                -- Not a PAP recorded in this top-level op, such as a
                                -- block argument: nothing to compare against.
                                Nothing

                            Just sourceRemaining ->
                                if remainingArity /= sourceRemaining then
                                    Just
                                        { opId = op.id
                                        , opName = op.name
                                        , message =
                                            "eco.papExtend remaining_arity="
                                                ++ String.fromInt remainingArity
                                                ++ " but source PAP has remaining="
                                                ++ String.fromInt sourceRemaining
                                        }

                                else if remainingArity < numNewArgs then
                                    Just
                                        { opId = op.id
                                        , opName = op.name
                                        , message =
                                            "eco.papExtend over-applies: remaining_arity="
                                                ++ String.fromInt remainingArity
                                                ++ " but num_new_args="
                                                ++ String.fromInt numNewArgs
                                        }

                                else
                                    Nothing
