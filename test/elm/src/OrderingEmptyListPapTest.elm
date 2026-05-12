module OrderingEmptyListPapTest exposing (main)

{-| First-class `<`, `<=`, `>`, `>=`, `compare` partially applied with `[]`.
Forces kernel symbols, no intrinsic shortcut.
-}

-- CHECK: ltEmpty: [False, True, True]
-- CHECK: leEmpty: [True, True, True]
-- CHECK: gtEmpty: [False, False, False]
-- CHECK: geEmpty: [True, False, False]
-- CHECK: cmpEmpty: [EQ, LT, LT]

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        xs : List (List Int)
        xs = [ emptyL, [ 1 ], [ 1, 2 ] ]

        _ = Debug.log "ltEmpty" (List.map ((<) emptyL) xs)
        _ = Debug.log "leEmpty" (List.map ((<=) emptyL) xs)
        _ = Debug.log "gtEmpty" (List.map ((>) emptyL) xs)
        _ = Debug.log "geEmpty" (List.map ((>=) emptyL) xs)
        _ = Debug.log "cmpEmpty" (List.map (compare emptyL) xs)
    in
    text "done"
