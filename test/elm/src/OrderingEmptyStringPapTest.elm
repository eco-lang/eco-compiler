module OrderingEmptyStringPapTest exposing (main)

{-| Tests `<`, `<=`, `>`, `>=` and `compare` partially applied to `""` and
passed as functions to `List.map`.

Each partial application is mapped over `[ "", "a", "ab" ]`, so `""` is always
the left operand: it compares equal to itself and less than both non-empty
strings.

-}

-- CHECK: ltEmpty: [False,True,True]
-- CHECK: leEmpty: [True,True,True]
-- CHECK: gtEmpty: [False,False,False]
-- CHECK: geEmpty: [True,False,False]
-- CHECK: cmpEmpty: [EQ,LT,LT]

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
