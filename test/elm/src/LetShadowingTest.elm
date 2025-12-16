module LetShadowingTest exposing (main)

{-| Test variable shadowing in let.
-}

-- CHECK: shadow1: 20
-- CHECK: shadow2: 10

import Html exposing (text)


main =
    let
        x = 10
        result1 =
            let
                x = 20
            in
            x
        result2 = x
        _ = Debug.log "shadow1" result1
        _ = Debug.log "shadow2" result2
    in
    text "done"
