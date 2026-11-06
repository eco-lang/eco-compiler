module ListSortByKindPreservationTest exposing (main)

{-| Checks that the results of `List.sortBy` and `List.sort` give correct values
when summed or folded, for `Int`, `Float` and `Char` elements.

  - `sortby-sum` and `sortby-negate-sum` sum `[3, 1, 2]` sorted by `identity`
    and by `negate`.
  - `sort-sum`, `sort-float-sum` and `sort-char-codes` sum `List.sort` of the
    `Int`, `Float` and `Char` lists, the characters by their codes.
  - `sort-of-range` and `sort-of-map` sort the output of `List.range` and
    `List.map` and sum it.
  - `sortby-key-order` prints `List.sort` of `[3, 1, 2]`, checking the order,
    which the sums cannot see.

-}

-- CHECK: sortby-sum: 6
-- CHECK: sortby-negate-sum: 6
-- CHECK: sort-sum: 6
-- CHECK: sort-float-sum: 7.5
-- CHECK: sort-char-codes: 294
-- CHECK: sort-of-range: 6
-- CHECK: sort-of-map: 12
-- CHECK: sortby-key-order: [1,2,3]

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

        -- The sums above would not notice elements in the wrong order.
        _ =
            Debug.log "sortby-key-order" (List.sort ints)
    in
    text "done"
