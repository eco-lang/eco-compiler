module CharGetCharWidthTest exposing (main)

{-| A width function comparing `Char.toCode` against `0xFFFF` gives 1 for an
ASCII character taken from a string with `String.uncons`.

`getCharWidth` returns 2 for a character above `0xFFFF` and 1 otherwise. The
first character of `"abc"` is `'a'`, so the logged width is 1.

-}

-- CHECK: width: 1


import Char
import Html exposing (text)


getCharWidth : Char -> Int
getCharWidth c =
    if Char.toCode c > 0xFFFF then
        2

    else
        1


main =
    let
        src =
            "abc"

        width =
            case String.uncons src of
                Just ( c, _ ) ->
                    getCharWidth c

                Nothing ->
                    -1

        _ =
            Debug.log "width" width
    in
    text "done"
