module LssSingletonLetBoundLambdaTest exposing (main)

{-| A recursive higher-order function called with a let-bound lambda that captures a local value applies it correctly.

`addStep` is bound to `\x -> x + step` with `step` = 5, and `repeatApply addStep 5 1` applies it
five times starting from 1, giving 26. `LssSingletonFastDispatchTest` is the same program with
the lambda passed directly.

## eco

Companion to test/eco-elm/src/LssSingletonFastDispatchTest.elm. The let-bound lambda goes
through the monomorphizer's local-multi path, which originally carried no member to the call site,
so the call was not upgraded to fast dispatch. This test pins correctness of that path: the output
is the same with lambda-set specialization on or off.

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
