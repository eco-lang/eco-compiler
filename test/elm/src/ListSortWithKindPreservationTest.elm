module ListSortWithKindPreservationTest exposing (main)

{-| Checks that the result of `List.sortWith` gives correct values when summed,
folded or searched for its maximum, for `Int`, `Float` and `Char` elements.

  - `int-sum`, `int-foldl` and `int-max` use `[3, 1, 2]` sorted with
    `compare`.
  - `float-sum` and `float-max` use `[3.5, 1.5, 2.5]` sorted with `compare`.
  - `char-codes` sums the codes of `['c', 'a', 'b']` sorted with `compare`.
  - `int-desc-sum` sums `[3, 1, 2]` sorted with a descending comparator.

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
