module ListMapTemplateMemberTaintTest exposing (main)

{-| The MEMBER-LEVEL canary for the `List.map` template licence
(`plans/list-map-mlir-template.md`, F-3/F-4 joint-architecture section).

Shape: the callback applies a callee LOCAL (`sortIt`), and that local's own
body launders `Debug` through a kernel HOF's argument position.

Before F-3, `sortIt` in callee position was declined by the shape-blind
higher-order arm — sound BY ACCIDENT. F-3 resolves the callee through the
lambda-set member table, so this shape becomes licensable unless the member
table is TAINT-AWARE BY CONSTRUCTION: scanning `sortIt`'s body must apply
the same argument-position rule the licence walk applies, or F-3 licenses
this map and the comparator's lines reorder.

Same `[1, 1]` / `[2, 2]` construction as
`ListMapTemplateLaunderedDebugTest.elm` — the logged number names the
sublist, not the argument order. Expected order is foldr's right-to-left.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1, 1], [2, 2]]

import Html exposing (text)


loggingCompare : Int -> Int -> Order
loggingCompare a b =
    let
        _ =
            Debug.log "cmp" a
    in
    compare a b


main : Html.Html msg
main =
    let
        cmp : Int -> Int -> Order
        cmp =
            loggingCompare

        sortIt : List Int -> List Int
        sortIt =
            \ys -> List.sortWith cmp ys

        sorted =
            List.map (\x -> sortIt x) [ [ 1, 1 ], [ 2, 2 ] ]

        _ =
            Debug.log "sorted" sorted
    in
    text "done"
