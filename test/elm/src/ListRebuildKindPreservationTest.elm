module ListRebuildKindPreservationTest exposing (main)

{-| Every list REBUILD must reproduce its input's element representation, for
all three unboxed slot kinds — not just Int.

The kernel's collect-then-build helpers used to carry `bool is_boxed` per
element instead of the 2-bit slot KIND, so every unboxed kind collapsed to
Int. A `List Float` rebuilt through one of them came back with f64 bit
patterns sitting in Int-kinded slots: `Debug.log` still printed the right
numbers (the printer reads the cell header), but structural equality against a
genuine `List Float` failed and arithmetic folds read the wrong slot.

`List.take` and `List.concat` were the live Float/Char casualties beyond the
sort family; the rest of these are pinned because they share the same builder
and would regress silently if it ever collapsed again — the failure mode is
wrong VALUES, never a crash.

`ListSortWithKindPreservationTest` / `ListSortByKindPreservationTest` cover the
sort family.

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

        -- maximum/minimum wrap the winning element back up: the Maybe must
        -- carry the element's kind, not a boxed/unboxed boolean.
        _ =
            Debug.log "maximum-float" (Maybe.withDefault 0 (List.maximum floats))

        _ =
            Debug.log "minimum-float" (Maybe.withDefault 0 (List.minimum floats))

        -- Arithmetic over a rebuilt list reads elements at their static kind.
        _ =
            Debug.log "take-float-sum" (List.sum (List.take 2 floats))
    in
    text "done"
