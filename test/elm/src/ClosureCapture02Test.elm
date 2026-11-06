module ClosureCapture02Test exposing (main)

{-| A lambda returned from a function captures a `Maybe String` argument and
matches on it with `case` when called.

The captured value is used only as the subject of the `case`. `Just "hello"`
gives `"hello"` and `Nothing` gives `"none"`.

-}

-- CHECK: just: "hello"
-- CHECK: nothing: "none"

import Html exposing (text)


toLabel : Maybe String -> (Int -> String)
toLabel m =
    \dummy ->
        case m of
            Just s ->
                s

            Nothing ->
                "none"


main =
    let
        _ = Debug.log "just" (toLabel (Just "hello") 0)
        _ = Debug.log "nothing" (toLabel Nothing 0)
    in
    text "done"
