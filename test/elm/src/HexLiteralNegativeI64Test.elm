module HexLiteralNegativeI64Test exposing (main)

{-| A hex Int literal at or above 2^63 wraps to a negative i64 constant (Eco
Int is 64-bit two's complement; the --text-mlir output shows exactly these
values). Below -2^30 the MLIR bytecode writer then mis-encodes it when the
compiler runs as JavaScript: `Mlir.Bytecode.VarInt.encodeSignedVarInt`
computes the zigzag with `Bitwise.xor`, which truncates to 32 bits, and every
such constant reads back as -9223372036854775808.
A plain negative literal (-3000000000) does not reach the bug: the compiler
emits it as a positive constant plus eco.int.negate.
Also covered by the unit test compiler/tests/Mlir/Bytecode/VarIntTest.elm.

EXPECTED TO FAIL until fixed (the E2E harnesses compile with the JS-hosted
compiler and bytecode output).
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
