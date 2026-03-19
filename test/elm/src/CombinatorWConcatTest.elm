module CombinatorWConcatTest exposing (main)

{-| W combinator with string append: w (++) "hi" = "hihi"
-}

-- CHECK: result: "hihi"

import Html exposing (text)


w bf x = bf x x


main =
    let
        _ = Debug.log "result" (w (++) "hi")
    in
    text "done"
