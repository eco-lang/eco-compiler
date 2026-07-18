module StagedFastDispatchTest exposing (main)

{-| E2.7 staged fast dispatch (LSS_014, plans/lss-dispatch-value-extraction.md §E2.7).

A CURRIED lambda literal (stage arities [1,1]) flows into a
recursion-protected HOF whose body OVER-applies it: `f 10 (…)` applies two
args across the instance's two stages. Flag-on (solver+LSS) the site is
staged-stamped: batch 1 lowers to a direct fast call of the outer stage,
the remainder applies generically to the returned inner closure — the CHECK
below must print the same answer as the un-stamped (flag-off) build. The
recursion is non-tail so H5 loopification cannot eat the dispatch.

Unit-level pin: compiler/tests/TestLogic/Generate/CodeGen/E2V2StagedDispatchTest.elm.

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
