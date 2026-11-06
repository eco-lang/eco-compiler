module StringAstralLengthTest exposing (main)

{-| `String.length` counts UTF-16 code units, so a character outside the Basic Multilingual Plane counts as 2.

U+1F600 (😀) is encoded as a surrogate pair. `String.length "😀"` is 2, and
`String.length "a😀b"` is 4. The test also requires such a character to survive
inside a string literal.
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
