module CombinatorWDupTest exposing (main)

{-| W combinator: x * x on 9 = 81
-}

-- CHECK: result: 81

import Html exposing (text)


w bf x = bf x x

mul x y = x * y


main =
    let
        _ = Debug.log "result" (w mul 9)
    in
    text "done"
