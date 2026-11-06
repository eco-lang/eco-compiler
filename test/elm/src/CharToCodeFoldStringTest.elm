module CharToCodeFoldStringTest exposing (main)

{-| `String.foldl` hands each character of a string to a function that sums their
`Char.toCode` values.

The codes of `"abc"` are 97, 98 and 99, so the logged sum is 294.

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
