module CombinatorWDupTest exposing (main)

{-| The W combinator, which passes one argument twice: `w mul 9` is `mul 9 9`, which is 81.
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
