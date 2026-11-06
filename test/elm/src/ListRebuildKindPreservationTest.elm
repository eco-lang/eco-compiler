module ListRebuildKindPreservationTest exposing (main)

{-| Checks that list functions which build a new list from their input return
`List Float` and `List Char` values equal to the expected literals, and that
arithmetic over such a result is correct.

The functions checked by equality are `List.take`, `List.concat`,
`List.intersperse`, `List.partition`, `List.unzip` and `List.filterMap` on
`Float` elements, and `List.take` and `List.concat` on `Char` elements. Also
checked are `List.maximum` and `List.minimum` of a `List Float`, and the sum
of `List.take 2` of one.

Sorting is checked by `ListSortWithKindPreservationTest` and
`ListSortByKindPreservationTest`.

-}

-- CHECK: take-float: True
-- CHECK: concat-float: True
-- CHECK: intersperse-float: True
-- CHECK: partition-float: True
-- CHECK: unzip-float: True
-- CHECK: filterMap-float: True
-- CHECK: take-char: True
-- CHECK: concat-char: True
-- CHECK: maximum-float: 3.5
-- CHECK: minimum-float: 1.5
-- CHECK: take-float-sum: 5

import Html exposing (text)


floats : List Float
floats =
    [ 3.5, 1.5, 2.5 ]


chars : List Char
chars =
    [ 'c', 'a', 'b' ]


main : Html.Html msg
main =
    let
        _ =
            Debug.log "take-float" (List.take 2 floats == [ 3.5, 1.5 ])

        _ =
            Debug.log "concat-float" (List.concat [ floats, [ 0.5 ] ] == [ 3.5, 1.5, 2.5, 0.5 ])

        _ =
            Debug.log "intersperse-float" (List.intersperse 0.5 floats == [ 3.5, 0.5, 1.5, 0.5, 2.5 ])

        _ =
            Debug.log "partition-float" (Tuple.first (List.partition (\f -> f > 2) floats) == [ 3.5, 2.5 ])

        _ =
            Debug.log "unzip-float" (Tuple.first (List.unzip [ ( 1.5, 0 ), ( 2.5, 0 ) ]) == [ 1.5, 2.5 ])

        _ =
            Debug.log "filterMap-float" (List.filterMap Just floats == [ 3.5, 1.5, 2.5 ])

        _ =
            Debug.log "take-char" (List.take 2 chars == [ 'c', 'a' ])

        _ =
            Debug.log "concat-char" (List.concat [ chars, [ 'd' ] ] == [ 'c', 'a', 'b', 'd' ])

        _ =
            Debug.log "maximum-float" (Maybe.withDefault 0 (List.maximum floats))

        _ =
            Debug.log "minimum-float" (Maybe.withDefault 0 (List.minimum floats))

        _ =
            Debug.log "take-float-sum" (List.sum (List.take 2 floats))
    in
    text "done"
