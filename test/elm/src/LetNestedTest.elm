module LetNestedTest exposing (main)

{-| Test nested let expressions.
-}

-- CHECK: nested: 30

import Html exposing (text)


main =
    let
        outer =
            let
                inner = 10
            in
            inner * 3

        _ = Debug.log "nested" outer
    in
    text "done"
