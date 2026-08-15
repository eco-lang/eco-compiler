module ListSortWithKindPreservationTest exposing (main)

{-| `List.sortWith` must return a list at the SAME element representation it
was given.

Sorting is a permutation: a `List Int` in, a `List Int` out. The kernel export
materialises the input through an all-HPointer buffer so the user comparator
can be called with boxed values, and it used to REBUILD the result from that
buffer — producing boxed cells for a list whose static element kind is
unboxed. Consumers that read elements at their static kind (arithmetic folds:
`List.sum`, `List.foldl (+)`, `List.maximum`) then read the pointer words as
numbers. Nothing crashes; the arithmetic is just silently wrong, which is why
this went unnoticed — `Debug.log` prints the list correctly because the
printer consults the cell header instead.

The pre-existing `ListSortWithFloatCompareTest` misses it: it never folds
arithmetic over the sorted result.

Covers all three unboxed slot kinds (REP_HEAP_002): Int, Float, Char.

-}

-- CHECK: int-sum: 6
-- CHECK: int-foldl: 6
-- CHECK: int-max: 3
-- CHECK: float-sum: 7.5
-- CHECK: float-max: 3.5
-- CHECK: char-codes: 294
-- CHECK: int-desc-sum: 6

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


descending : Int -> Int -> Order
descending a b =
    compare b a


codeSum : List Char -> Int
codeSum cs =
    List.foldl (\c acc -> acc + Char.toCode c) 0 cs


main : Html.Html msg
main =
    let
        sortedInts =
            List.sortWith compare ints

        sortedFloats =
            List.sortWith compare floats

        _ =
            Debug.log "int-sum" (List.sum sortedInts)

        _ =
            Debug.log "int-foldl" (List.foldl (+) 0 sortedInts)

        _ =
            Debug.log "int-max" (Maybe.withDefault 0 (List.maximum sortedInts))

        _ =
            Debug.log "float-sum" (List.sum sortedFloats)

        _ =
            Debug.log "float-max" (Maybe.withDefault 0 (List.maximum sortedFloats))

        _ =
            Debug.log "char-codes" (codeSum (List.sortWith compare chars))

        _ =
            Debug.log "int-desc-sum" (List.sum (List.sortWith descending ints))
    in
    text "done"
