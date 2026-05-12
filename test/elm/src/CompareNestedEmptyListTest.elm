module CompareNestedEmptyListTest exposing (main)

{-| F2 inside `Tag_Cons` heads: comparing `List (List Int)` where some
inner lists are `[]` reaches `compareUnboxableSlot` on the head field of
the outer Cons (same path as tuple-field compare). Expected to FAIL
today: `compare [[]] [[1]]` returns GT instead of LT.
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
