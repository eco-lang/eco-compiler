module CharToCodeThroughFunctionTest exposing (main)

{-| Pass a Char through a non-inlined function so it is register-passed at
the kernel boundary, exercising the i16 zero-extension contract.
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
