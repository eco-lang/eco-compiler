module LoopifyLastRoundCaptureTest exposing (main)

{-| A recursive higher-order function called with nested lambdas, inside a
lambda applied through `|>`, returns the correct result.

`myAny` is a hand-written `List.any`. `hasK` pipes `k0` into a lambda that
calls `myAny` with a lambda which itself calls `myAny` with a lambda reading
`k`, so the innermost lambda uses a variable bound two lambdas out.
`hasK 3 [ [ 1, 2 ], [ 3 ] ]` finds 3 in the second inner list and prints True.

## eco

Regression test for a post-mono inliner miscompile in loopification.
`loopifyCall` in compiler/src/Compiler/MonoOpt/InlineSimplify.elm re-binds a
lambda's captures to fresh `mono_inline_N` lets, and used to rebuild the lambda
with no captures, relying on the next round's beta reduction to close it. When
the loopify happened on the last fixpoint round (the round cap
`postMonoFixpointIterations`, compiler/src/Compiler/Config.elm), the open
closure reached code generation and failed with "lookupVar: unbound variable
mono_inline_N". The `|>` into an applied lambda shifts the nested loopifies onto
odd rounds, so the default cap of 4 hit it. The lambda now captures the fresh
names.

-}

-- CHECK: result: True

import Html exposing (text)


myAny : (a -> Bool) -> List a -> Bool
myAny f l =
    case l of
        [] ->
            False

        x :: rest ->
            if f x then
                True

            else
                myAny f rest


hasK : Int -> List (List Int) -> Bool
hasK k0 ls =
    k0 |> (\k -> myAny (\xs -> myAny (\x -> x == k) xs) ls)


main =
    let
        _ =
            Debug.log "result" (hasK 3 [ [ 1, 2 ], [ 3 ] ])
    in
    text "done"
