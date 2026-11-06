module StagedFastDispatchTest exposing (main)

{-| A curried lambda written as `\a -> \b -> ...` can be applied to two arguments at once by a recursive higher-order function.

`applyStaged f n acc` applies `f 10` to the result of the recursive call, so the
recursion is not in tail position. With `f = \a -> \b -> a * 10 + b`, `n = 2`
and `acc = 3`, the result is `f 10 (f 10 3)`, which is `100 + 103 = 203`.

## eco

Exercises staged fast dispatch, LSS_014 in design_docs/invariants.csv
(plans/lss-dispatch-value-extraction.md). The curried lambda literal has stage
arities `[1,1]` and flows into a recursion-protected higher-order function that
over-applies it. With solver plus lambda-set specialization on, the site is
staged-stamped: the first batch lowers to a direct fast call of the outer stage
and the remainder applies generically to the returned closure. The output must
match the unstamped build. The recursion is non-tail so loopification cannot
remove the dispatch.

Unit-level pin: compiler/tests/Compiler/MonoOpt/E2V2StagedDispatchTest.elm.

-}

-- CHECK: result: 203

import Html exposing (text)


applyStaged : (Int -> Int -> Int) -> Int -> Int -> Int
applyStaged f n acc =
    if n <= 0 then
        acc

    else
        f 10 (applyStaged f (n - 1) acc)


main =
    let
        _ =
            Debug.log "result" (applyStaged (\a -> \b -> a * 10 + b) 2 3)
    in
    text "done"
