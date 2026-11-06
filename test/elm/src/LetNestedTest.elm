module LetNestedTest exposing (main)

{-| A `let` expression used as the definition of a binding in an outer `let`: the
inner binding 10 is multiplied by 3, giving 30.
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
