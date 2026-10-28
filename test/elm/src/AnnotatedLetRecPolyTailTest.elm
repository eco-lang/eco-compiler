module AnnotatedLetRecPolyTailTest exposing (main)

{-| Bug: Compiler.LocalOpt.Typed.Expression.optimizePotentialTailCallDef, Can.TypedDef
arm, passes the annotation RESULT type (TypedDef stored type) instead of the
whole function type, so an annotated recursive let def becomes a TailDef typed
with its result type. Monomorphize.Specialize treats the TailDef type as the
whole function type (MonoTailFunc), so the local function gets a non-function
mono type. The same program without the let annotation works.
Unit test: compiler/tests/Compiler/LocalOpt/Typed/ExpressionTest.elm.
Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, item 3.3); the text
below describes the old behaviour.
Observed: MLIR verifier error CGEN_003 (typed papExtend newarg has type i64
but evaluator _tail_rep_N expects !eco.value).
-}

-- CHECK: AnnotatedLetRecPolyTailTest: ([1, 1, 1], ["s", "s"])

import Html exposing (text)


polyUse : ( List Int, List String )
polyUse =
    let
        rep : Int -> b -> List b -> List b
        rep n x acc =
            if n <= 0 then
                acc

            else
                rep (n - 1) x (x :: acc)
    in
    ( rep 3 1 [], rep 2 "s" [] )


main =
    let
        _ =
            Debug.log "AnnotatedLetRecPolyTailTest" polyUse
    in
    text "done"
