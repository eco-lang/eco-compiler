module CombinatorWConcatTest exposing (main)

{-| The W combinator, which passes one argument twice, applied to string append: `w (++) "hi"` is `"hihi"`.
-}

-- CHECK: result: "hihi"

import Html exposing (text)


w bf x = bf x x


main =
    let
        _ = Debug.log "result" (w (++) "hi")
    in
    text "done"
