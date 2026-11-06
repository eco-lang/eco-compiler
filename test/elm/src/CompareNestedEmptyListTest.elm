module CompareNestedEmptyListTest exposing (main)

{-| `compare` on `List (List Int)` values where some inner lists are empty.

The outer lists compare element by element, so each inner list is itself
compared as a list: `[ [] ]` is less than `[ [ 1 ] ]`, and an empty inner list
in the middle position decides the result when the elements before it are
equal.

-}

-- CHECK: ee: EQ
-- CHECK: eA: LT
-- CHECK: Ae: GT
-- CHECK: midEmpty: LT
-- CHECK: midNonEmpty: GT

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        _ = Debug.log "ee" (compare [ emptyL ] [ emptyL ])
        _ = Debug.log "eA" (compare [ emptyL ] [ [ 1 ] ])
        _ = Debug.log "Ae" (compare [ [ 1 ] ] [ emptyL ])
        _ = Debug.log "midEmpty" (compare [ [ 1 ], emptyL, [ 2 ] ] [ [ 1 ], [ 9 ], [ 2 ] ])
        _ = Debug.log "midNonEmpty" (compare [ [ 1 ], [ 9 ], [ 2 ] ] [ [ 1 ], emptyL, [ 2 ] ])
    in
    text "done"
