module LetNumberNestedLetTest exposing (main)

{-| Probe: binding-site variation — a `number` flows across nested `let`s before
the `Float` use. `m = n` re-binds the number; the multiply is on `m`. Correct:
1.5*30 = 45.

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
