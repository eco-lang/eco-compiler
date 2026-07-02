module StringAstralLengthTest exposing (main)

{-| G1/E1: String.length counts UTF-16 code units. An astral char (U+1F600 😀)
occupies a surrogate pair = 2 code units. Also exercises astral string-literal
encoding into the MLIR bytecode string section.
-}

-- CHECK: len_astral: 2
-- CHECK: len_mixed: 4

import Html exposing (text)


main =
    let
        _ =
            Debug.log "len_astral" (String.length "😀")

        _ =
            Debug.log "len_mixed" (String.length "a😀b")
    in
    text "done"
