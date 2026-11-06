module LssSingletonFastDispatchTest exposing (main)

{-| A recursive higher-order function called with a single lambda literal that captures a local value applies it correctly.

`repeatApply f n acc` applies `f` to `acc` `n` times. The lambda `\x -> x + step` captures
`step` = 5, so five applications starting from 1 give 26. `LssSingletonLetBoundLambdaTest` is
the same program with the lambda bound in a `let` first.

## eco

Exercises singleton fast dispatch in lambda-set specialization
(plans/lss-lambda-set-specialization.md). The internal `f acc` call of the recursive `repeatApply`
sees a singleton lambda set, and AbiCloning (compiler/src/Compiler/MonoOpt/AbiCloning.elm) upgrades
it to a direct call (`_call_kind = "singleton_fast"` on the saturating `eco.papExtend`). The
recursion keeps the call from being inlined away. Output must match the generic apply path
(LSS_005 in design_docs/invariants.csv).

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

        _ =
            Debug.log "result" (repeatApply (\x -> x + step) 5 1)
    in
    text "done"
