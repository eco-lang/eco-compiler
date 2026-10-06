module LoopifyLastRoundCaptureTest exposing (main)

{-| Regression test for a post-mono inliner miscompile (H5 loopification on the LAST fixpoint round).

`MonoInlineSimplify.loopifyCall` re-binds a lambda's captures to fresh `mono_inline_N` lets and
used to rebuild the lambda with `captures = []`, relying on the NEXT round's beta reduction to
close it. When the loopify happened in the last round (`iterate` stops at
`postMonoFixpointIterations`), the open closure reached code generation: "lookupVar: unbound
variable mono_inline_N". The `|>` into an applied lambda shifts the nested loopifies onto odd
rounds, so the DEFAULT cap (4) hit it. The lambda now captures the fresh names.
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
