module AstralCharCasePatternTest exposing (main)

{-| A `case` on a `Char` matches a pattern above U+FFFF, `'\u{1F600}'`, against the same character built by `Char.fromCode` or written as a literal.

A pattern in the Basic Multilingual Plane, `'\u{20AC}'`, still matches, and
`'a'` falls through to the wildcard. `Char.fromCode 0xDE00` is the low
surrogate of U+1F600 on its own; it is a different `Char` and does not match
the U+1F600 pattern.

-}

-- CHECK: a: "other"
-- CHECK: euro: "euro"
-- CHECK: lowSurrogate: "other"
-- CHECK: fromCode: "grin"
-- CHECK: literal: "grin"

import Html exposing (text)


classify : Char -> String
classify c =
    case c of
        '\u{1F600}' ->
            "grin"

        '\u{20AC}' ->
            "euro"

        _ ->
            "other"


main =
    let
        _ =
            Debug.log "a" (classify 'a')

        _ =
            Debug.log "euro" (classify (Char.fromCode 0x20AC))

        _ =
            Debug.log "lowSurrogate" (classify (Char.fromCode 0xDE00))

        _ =
            Debug.log "fromCode" (classify (Char.fromCode 0x0001F600))

        _ =
            Debug.log "literal" (classify '😀')
    in
    text "done"
