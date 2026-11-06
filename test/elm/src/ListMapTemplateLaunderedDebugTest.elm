module ListMapTemplateLaunderedDebugTest exposing (main)

{-| Checks that `List.map` applies its callback to the elements from last to
first when the callback passes a logging comparator it was given to
`List.sortWith`.

elm/core defines `List.map` with `List.foldr`, which, on a list this short,
applies the callback to the last element first. `sortEach g` maps
`\x -> List.sortWith g x` and never calls `g` itself. With `loggingCompare`,
which logs its first argument, as `g` and the inner lists `[1, 1]` and
`[2, 2]`, the number logged names the list being sorted whichever way the
comparator's arguments are ordered: the expected output is the log for
`[2, 2]` immediately followed by the log for `[1, 1]`, then the unchanged
sorted lists.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1,1],[2,2]]

import Html exposing (text)


{-| Compares two integers with `compare`, logging the first.
-}
loggingCompare : Int -> Int -> Order
loggingCompare a b =
    let
        _ =
            Debug.log "cmp" a
    in
    compare a b


{-| Sorts each inner list of `xs` with the comparator `g`, using `List.map`
over `List.sortWith`.
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
