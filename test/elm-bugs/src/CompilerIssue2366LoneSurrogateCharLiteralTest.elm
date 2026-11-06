module CompilerIssue2366LoneSurrogateCharLiteralTest exposing (main)

{-| Char literals for surrogate code points compare correctly against a string's lone surrogates.

<https://github.com/elm/compiler/issues/2366>

`String.left 3 "ab😀"` cuts the emoji in half, leaving `"ab"` followed by a lone high surrogate.
Filtering out every `Char` between the literals `'\u{D800}'` and `'\u{DFFF}'` must remove it,
giving `"ab"` of length 2, as Elm 0.19.1 does. Elm 0.19.2, Elm 0.19.3 and Lamdera 1.5.0 write
those literals into the generated JavaScript as raw lone surrogates instead of escapes, so the
output is not valid UTF-8, the literals no longer hold surrogates, and the program logs
`"ab�undefined"` of length 12.

-}

-- CHECK: cleaned: "ab"
-- CHECK: length: 2
-- CHECK: cut: 3

import Html exposing (text)


{-| Removes every UTF-16 surrogate code unit from a string.
-}
clean : String -> String
clean =
    String.filter (not << isSurrogate)


{-| Whether a `Char` is in the surrogate range, written with surrogate `Char` literals.
-}
isSurrogate : Char -> Bool
isSurrogate char =
    '\u{D800}' <= char && char <= '\u{DFFF}'


main =
    let
        cut =
            String.left 3 "ab😀"

        result =
            clean cut

        _ =
            Debug.log "cut" (String.length cut)

        _ =
            Debug.log "cleaned" result

        _ =
            Debug.log "length" (String.length result)
    in
    text "done"
