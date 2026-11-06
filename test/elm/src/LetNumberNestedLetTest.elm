module LetNumberNestedLetTest exposing (main)

{-| An integer literal bound in one `let` and re-bound in a nested `let` is used as
a `Float`: `n = 30`, then `m = n`, then `round (m * 1.5)` logs 45.
-}

-- CHECK: nestedlet: 45

import Html exposing (text)


main =
    let
        result =
            let
                n =
                    30
            in
            let
                m =
                    n
            in
            round (m * 1.5)

        _ =
            Debug.log "nestedlet" result
    in
    text "done"
