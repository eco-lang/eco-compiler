module EscapeTopLevelTupleTest exposing (main)

{-| A tuple defined as a top-level constant is destructured in a `let` pattern into its two components.

`globalPair` is `( 11, 22 )`, so `a` is 11 and `b` is 22.
-}

-- CHECK: a: 11
-- CHECK: b: 22


import Html exposing (text)


globalPair : ( Int, Int )
globalPair =
    ( 11, 22 )


main =
    let
        ( a, b ) =
            globalPair

        _ =
            Debug.log "a" a

        _ =
            Debug.log "b" b
    in
    text "done"
