module AnnotatedLetRecPolyTailTest exposing (main)

{-| A tail-recursive let-bound function with a polymorphic type annotation can be used at two types in the same expression.

`rep : Int -> b -> List b -> List b` is applied once to an `Int` and once to a
`String`.

## eco

Regression test for a bug in `optimizePotentialTailCallDef` (compiler/src/Compiler/LocalOpt/Typed/Expression.elm): for an annotated recursive let definition it stored the annotation's result type rather than the whole function type on the tail-call definition, so monomorphization gave the local function a non-function type and the MLIR verifier rejected a `papExtend` argument (i64 where the evaluator expected `!eco.value`, CGEN_003 in design_docs/invariants.csv). The same program without the annotation was fine.

Fixed in the review bug-triage work (plans/review-bug-triage-fixes.md, item 3.3); unit test in compiler/tests/Compiler/LocalOpt/Typed/ExpressionTest.elm.

-}

-- CHECK: AnnotatedLetRecPolyTailTest: ([1,1,1],["s","s"])

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
