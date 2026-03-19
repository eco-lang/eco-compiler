module PolyLetConstTest exposing (main)

{-| Test polymorphic let-bound const at two type combos.
-}

-- CHECK: r1: 1
-- CHECK: r2: "hi"

import Html exposing (text)


main =
    let
        const a b = a

        r1 = const 1 "hi"
        r2 = const "hi" 1
        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
