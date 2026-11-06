module CharToCodeThroughFunctionTest exposing (main)

{-| `Char.toCode` of a character returned from a top-level function, here an
identity function applied to `'A'`, gives 65.
-}

-- CHECK: code: 65


import Char
import Html exposing (text)


identityChar : Char -> Char
identityChar c =
    c


main =
    let
        c =
            identityChar 'A'

        _ =
            Debug.log "code" (Char.toCode c)
    in
    text "done"
