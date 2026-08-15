module ListSortByKindPreservationTest exposing (main)

{-| `List.sortBy` — and `List.sort`, which is `sortBy identity` — must return a
list at the SAME element representation they were given.

Same defect and same reasoning as `ListSortWithKindPreservationTest`: the
kernel export flattens the input to an all-HPointer buffer for the key
closure, then rebuilt the result from that buffer, handing back boxed cells
for a statically-unboxed element type. Arithmetic folds over the result read
pointer words as numbers.

The pre-existing `ListSortByFloatIdentityTest` misses it: it never folds
arithmetic over the sorted result.

Also pins the composition that made this easy to hit in practice — sorting
the output of another list producer (`List.range`, `List.map`) and then
summing it.

-}

-- CHECK: sortby-sum: 6
-- CHECK: sortby-negate-sum: 6
-- CHECK: sort-sum: 6
-- CHECK: sort-float-sum: 7.5
-- CHECK: sort-char-codes: 294
-- CHECK: sort-of-range: 6
-- CHECK: sort-of-map: 12
-- CHECK: sortby-key-order: [1, 2, 3]

import Html exposing (text)


ints : List Int
ints =
    [ 3, 1, 2 ]


floats : List Float
floats =
    [ 3.5, 1.5, 2.5 ]


chars : List Char
chars =
    [ 'c', 'a', 'b' ]


codeSum : List Char -> Int
codeSum cs =
    List.foldl (\c acc -> acc + Char.toCode c) 0 cs


main : Html.Html msg
main =
    let
        _ =
            Debug.log "sortby-sum" (List.sum (List.sortBy identity ints))

        _ =
            Debug.log "sortby-negate-sum" (List.sum (List.sortBy negate ints))

        _ =
            Debug.log "sort-sum" (List.sum (List.sort ints))

        _ =
            Debug.log "sort-float-sum" (List.sum (List.sort floats))

        _ =
            Debug.log "sort-char-codes" (codeSum (List.sort chars))

        _ =
            Debug.log "sort-of-range" (List.sum (List.sort (List.range 1 3)))

        _ =
            Debug.log "sort-of-map" (List.sum (List.sort (List.map (\n -> n * 2) ints)))

        -- The ORDER must stay correct too: a kind fix that reordered or
        -- duplicated elements would still pass the sums above by accident.
        _ =
            Debug.log "sortby-key-order" (List.sort ints)
    in
    text "done"
