module AstralCharLiteralTest exposing (main)

{-| A Char literal above U+FFFF (`'\u{1F600}'`) is emitted by
`Compiler.Generate.MLIR.Expr.generateLiteral` as an `i32` constant holding its
code point, 128512 (Char is a Unicode code point in i32, CGEN_015). Before
Char was widened the constant was an out-of-range `i16`, and eco-boot-native
aborted reading the MLIR bytecode (APInt "Value is not an N-bit unsigned
value"). Also covered by the unit test
compiler/tests/Compiler/Generate/MLIR/ExprAstralCharTest.elm.

The literal and `Char.fromCode` of the same code point are the same Char.
-}

-- CHECK: astral: 128512
-- CHECK: bmp: 8364
-- CHECK: sameAsFromCode: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "astral" (Char.toCode '\u{1F600}')

        _ =
            Debug.log "bmp" (Char.toCode '\u{20AC}')

        _ =
            Debug.log "sameAsFromCode" ('\u{1F600}' == Char.fromCode 0x0001F600)
    in
    text "done"
