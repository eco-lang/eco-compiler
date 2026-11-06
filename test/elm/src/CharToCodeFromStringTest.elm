module CharToCodeFromStringTest exposing (main)

{-| `Char.toCode` of a character obtained at run time from `String.uncons`, rather
than written as a literal, gives that character's code point.

The first character of `"type"` is `'t'`, whose code is 116.

-}

-- CHECK: code: 116


import Char
import Html exposing (text)


main =
    let
        src =
            "type"

        code =
            case String.uncons src of
                Just ( c, _ ) ->
                    Char.toCode c

                Nothing ->
                    -1

        _ =
            Debug.log "code" code
    in
    text "done"
