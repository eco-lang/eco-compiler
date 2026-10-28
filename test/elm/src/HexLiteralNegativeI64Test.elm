module HexLiteralNegativeI64Test exposing (main)

{-| A hex Int literal at or above 2^63 means its 64-bit two's-complement value
(Eco Int is 64-bit), so these masks are negative i64 constants. Two bugs, both
fixed, broke this when the compiler runs as JavaScript (as the E2E harnesses
run it, with bytecode output): the parser accumulated the digits in a double,
inexact above 2^53 (`Compiler.Data.Int64` now reads the text exactly), and
`Mlir.Bytecode.VarInt.encodeSignedVarInt` computed the zigzag with
`Bitwise.xor`, which truncates to 32 bits, so every such constant read back as
-9223372036854775808.
A plain negative literal (-3000000000) does not reach the bug: the compiler
emits it as a positive constant plus eco.int.negate.
Also covered by the unit tests compiler/tests/Mlir/Bytecode/VarIntTest.elm and
compiler/tests/Parse/NumberTests.elm.
-}

-- CHECK: boundary: -1073741824
-- CHECK: minInt32: -2147483648
-- CHECK: minus2pow32: -4294967296

import Html exposing (text)


main =
    let
        _ =
            Debug.log "boundary" 0xFFFFFFFFC0000000

        _ =
            Debug.log "minInt32" 0xFFFFFFFF80000000

        _ =
            Debug.log "minus2pow32" 0xFFFFFFFF00000000
    in
    text "done"
