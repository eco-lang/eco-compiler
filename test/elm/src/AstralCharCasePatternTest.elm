module AstralCharCasePatternTest exposing (main)

{-| A Char case pattern above U+FFFF (`'\u{1F600}'`) is decoded by
`Compiler.Generate.MLIR.Patterns.decodeChrPatternCode`, which folds every hex
digit of the parser's surrogate-pair escape into one number, so the i16
comparison constant is out of range (neither the code point nor a clamp).
Also covered by the unit test
compiler/tests/Compiler/Generate/MLIR/PatternsAstralCharTest.elm.

Eco's Char is one UTF-16 unit (design_docs/theory/value-representation.md);
the classification of BMP chars must still work. Today the emitted
eco.case tag is 928736402944 (0xD83D00DE00), so the astral branch can never
match anything. Under the documented clamp, `Char.fromCode 0x1F600` is the
Char 0xFFFF that the literal `'\u{1F600}'` must also denote (as the literal
test AstralCharLiteralTest expects), so it must take the "grin" branch;
today it prints "other". U+DE00 (the low surrogate the bogus tag's low 16
bits name) must not match.

EXPECTED TO FAIL until fixed.
-}

-- CHECK: a: "other"
-- CHECK: euro: "euro"
-- CHECK: lowSurrogate: "other"
-- CHECK: clamped: "grin"

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
            Debug.log "clamped" (classify (Char.fromCode 0x0001F600))
    in
    text "done"
