module CompareEmptyListTest exposing (main)

{-| `compare` on List values, including `[]` (Const_Nil). Same top-level
early-return path as empty strings. Regression guard.
-}

-- CHECK: ee: EQ
-- CHECK: ea: LT
-- CHECK: ae: GT
-- CHECK: eab: LT
-- CHECK: abe: GT
-- CHECK: aa: EQ
-- CHECK: ab: LT
-- CHECK: ba: GT
-- CHECK: aba: GT

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        _ = Debug.log "ee" (compare emptyL emptyL)
        _ = Debug.log "ea" (compare emptyL [ 1 ])
        _ = Debug.log "ae" (compare [ 1 ] emptyL)
        _ = Debug.log "eab" (compare emptyL [ 1, 2 ])
        _ = Debug.log "abe" (compare [ 1, 2 ] emptyL)
        _ = Debug.log "aa" (compare [ 1 ] [ 1 ])
        _ = Debug.log "ab" (compare [ 1 ] [ 2 ])
        _ = Debug.log "ba" (compare [ 2 ] [ 1 ])
        _ = Debug.log "aba" (compare [ 1, 2 ] [ 1 ])
    in
    text "done"
