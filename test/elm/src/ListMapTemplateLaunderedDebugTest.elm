module ListMapTemplateLaunderedDebugTest exposing (main)

{-| The KERNEL-HOF canary for the `List.map` template licence
(`plans/list-map-mlir-template.md` F-4; policy `D-4a`).

`ListMapTemplateCapturedDebugTest.elm` covers `Debug` reaching the callback
through a DIRECTLY applied captured value. This fixture covers the channel
that one misses: the captured function is never applied by the callback
itself — it is handed to a **kernel higher-order function** as an ARGUMENT.

`List.sortWith` is a direct kernel alias (`List.elm`:
`sortWith = Elm.Kernel.List.sortWith`), so the callee position of
`\x -> List.sortWith g x` resolves to a kernel reference and answers Clean.
Before F-4 the walk then folded into the args, where `g` — a `MonoVarLocal`
capture — contributed nothing, and the map licensed. The comparator's
`Debug` lines would then come out left-to-right instead of foldr's
right-to-left. F-4's argument-position taint rule is what declines it.

The two sublists are `[1, 1]` and `[2, 2]`, so a comparison inside either
one logs the SAME number whichever way the kernel orders the pair — the log
line identifies the sublist, never the argument order.

Expected order is foldr's right-to-left: the `[2, 2]` sublist is compared
first.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1, 1], [2, 2]]

import Html exposing (text)


{-| The comparator logs. Nothing else in this module mentions `Debug`.
-}
loggingCompare : Int -> Int -> Order
loggingCompare a b =
    let
        _ =
            Debug.log "cmp" a
    in
    compare a b


{-| `g` is a captured function value passed to a KERNEL HOF as an argument.
The callback never applies `g` itself.
-}
sortEach : (Int -> Int -> Order) -> List (List Int) -> List (List Int)
sortEach g xs =
    List.map (\x -> List.sortWith g x) xs


main : Html.Html msg
main =
    let
        sorted =
            sortEach loggingCompare [ [ 1, 1 ], [ 2, 2 ] ]

        _ =
            Debug.log "sorted" sorted
    in
    text "done"
