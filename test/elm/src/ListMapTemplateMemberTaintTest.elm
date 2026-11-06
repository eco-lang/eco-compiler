module ListMapTemplateMemberTaintTest exposing (main)

{-| Checks that `List.map` applies its callback to the elements from last to
first when the callback calls a `let`-bound sorting function whose comparator
logs.

elm/core defines `List.map` with `List.foldr`, which, on a list this short,
applies the callback to the last element first. The callback calls `sortIt`,
which sorts with `cmp`, a local name for `loggingCompare`, which logs its first
argument. The inner lists are `[1, 1]` and `[2, 2]`, so the number logged names
the list being sorted whichever way the comparator's arguments are ordered: the
expected output is the log for `[2, 2]` immediately followed by the log for
`[1, 1]`, then the unchanged sorted lists.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1,1],[2,2]]

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
