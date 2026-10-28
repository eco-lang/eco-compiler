module AstralCharCasePatternTest exposing (main)

{-| A Char case pattern above U+FFFF (`'\u{1F600}'`) is decoded by
`Compiler.Generate.MLIR.Patterns.decodeChrPatternCode`, which combines the
parser's surrogate-pair escape into the code point, so the `eco.case` tag is
128512, the same value `Char.fromCode 0x1F600` and the literal produce (Char is
a Unicode code point in i32, CGEN_015). Before the fix the decoder folded every
hex digit into one number (928736402944 = 0xD83D00DE00), so the astral branch
could never match. Also covered by the unit test
compiler/tests/Compiler/Generate/MLIR/PatternsAstralCharTest.elm.

BMP patterns must still classify. U+DE00 (a lone low surrogate, which
`Char.fromCode` passes through) is a different Char and must not match.
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
