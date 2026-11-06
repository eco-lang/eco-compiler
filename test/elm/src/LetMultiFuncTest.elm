module LetMultiFuncTest exposing (main)

{-| Two named functions defined in one `let` and called from later bindings: a local
`identity` returns its argument (1) and a local `const` returns the first of two (2).
-}

-- CHECK: r1: 1
-- CHECK: r2: 2

import Html exposing (text)


main =
    let
        identity x = x
        const x y = x

        r1 = identity 1
        r2 = const 2 3
        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
