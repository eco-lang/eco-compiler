module OrderingEmptyStringPapTest exposing (main)

{-| First-class references to `<`, `<=`, `>`, `>=`, `compare` partially
applied with `""`. Forces the kernel symbols (no intrinsic shortcut).
-}

-- CHECK: ltEmpty: [False, True, True]
-- CHECK: leEmpty: [True, True, True]
-- CHECK: gtEmpty: [False, False, False]
-- CHECK: geEmpty: [True, False, False]
-- CHECK: cmpEmpty: [EQ, LT, LT]

import Html exposing (text)


main =
    let
        xs : List String
        xs = [ "", "a", "ab" ]

        _ = Debug.log "ltEmpty" (List.map ((<) "") xs)
        _ = Debug.log "leEmpty" (List.map ((<=) "") xs)
        _ = Debug.log "gtEmpty" (List.map ((>) "") xs)
        _ = Debug.log "geEmpty" (List.map ((>=) "") xs)
        _ = Debug.log "cmpEmpty" (List.map (compare "") xs)
    in
    text "done"
