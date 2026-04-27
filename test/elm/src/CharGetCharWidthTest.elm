module CharGetCharWidthTest exposing (main)

{-| Direct reproduction of the `getCharWidth` pattern from
`Compiler.Parse.Primitives` that the JSON parser uses. With the i16-zero-
extension bug, `Char.toCode c` returned a value with garbage in the upper
bits, making `> 0xFFFF` true for every ASCII character and pushing the
parser to step by 2 instead of 1.
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
