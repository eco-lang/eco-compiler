module EscapeCustomCaseScrutineeTest exposing (main)

{-| A value of a user-defined custom type, built in the call and taken apart by a `case` in another function, yields its payload.

`unwrap (Just2 7)` returns 7 and `unwrap Nothing2` returns 0.
-}

-- CHECK: just: 7
-- CHECK: nothing: 0


import Html exposing (text)


type Maybe2
    = Just2 Int
    | Nothing2


unwrap : Maybe2 -> Int
unwrap m =
    case m of
        Just2 x ->
            x

        Nothing2 ->
            0


main =
    let
        _ =
            Debug.log "just" (unwrap (Just2 7))

        _ =
            Debug.log "nothing" (unwrap Nothing2)
    in
    text "done"
