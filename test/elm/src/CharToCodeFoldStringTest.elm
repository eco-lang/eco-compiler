module CharToCodeFoldStringTest exposing (main)

{-| Sum char codes by folding over a String. Each fold step receives a Char
extracted from the String (via the kernel) — exactly the path the JSON
parser was using when the bootstrap broke.
-}

-- CHECK: sum: 294


import Char
import Html exposing (text)


main =
    let
        sum =
            String.foldl (\c acc -> acc + Char.toCode c) 0 "abc"

        _ =
            Debug.log "sum" sum
    in
    text "done"
