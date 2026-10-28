module AstralCharLiteralTest exposing (main)

{-| A Char literal above U+FFFF (`'\u{1F600}'`) is emitted by
`Compiler.Generate.MLIR.Expr.generateLiteral` as an `i16` arith.constant
holding 128512, which does not fit; eco-boot-native then aborts reading the
MLIR bytecode (APInt "Value is not an N-bit unsigned value").
Also covered by the unit test
compiler/tests/Compiler/Generate/MLIR/ExprAstralCharTest.elm.

Eco's Char is one UTF-16 unit (design_docs/theory/value-representation.md,
CharAstralCodeTest): `Char.fromCode` clamps above 0xFFFF to 65535, so a
literal is expected to clamp the same way.

EXPECTED TO FAIL until fixed (currently fails to compile/lower).
-}

-- CHECK: astral: 65535
-- CHECK: bmp: 8364

import Html exposing (text)


main =
    let
        _ =
            Debug.log "astral" (Char.toCode '\u{1F600}')

        _ =
            Debug.log "bmp" (Char.toCode '\u{20AC}')
    in
    text "done"
