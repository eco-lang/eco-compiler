module LssSingletonLetBoundLambdaTest exposing (main)

{-| LSS M3 companion: the same shape with the lambda LET-BOUND. The binding
is a local-multi target, which is the documented v1 precision gap (no
member transport, no upgrade) — this test pins the CORRECTNESS of that
path: output identical with LSS on or off.
-}

-- CHECK: result: 26

import Html exposing (text)


repeatApply : (Int -> Int) -> Int -> Int -> Int
repeatApply f n acc =
    if n <= 0 then
        acc

    else
        repeatApply f (n - 1) (f acc)


main =
    let
        step =
            5

        addStep =
            \x -> x + step

        _ =
            Debug.log "result" (repeatApply addStep 5 1)
    in
    text "done"
