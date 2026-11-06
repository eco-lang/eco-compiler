module FusionGlobalMapFnTest exposing (main)

{-| An elm/bytes encoder built by mapping a named top-level function over a list, after a 32-bit length prefix, produces a buffer of the expected width.

`encodeByte` is a top-level function wrapping `Bytes.Encode.unsignedInt8`, used
with `List.map` rather than an inline lambda. The list `[ 7, 8, 9 ]` is encoded
as a big-endian `unsignedInt32` length followed by one byte per item, so the
encoded bytes are `[ 0, 0, 0, 3, 7, 8, 9 ]` and `Bytes.width` is 7.

## eco

Exercises the `MonoVarGlobal` case of `reifyMapBody` in compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm: the map
function is a named top-level function, which the body lookup beta-reduces, so the encoder
fuses into an `ELoop` that lowers to `scf.while` with `bf.write.u8` inside (the CHECK-MLIR
lines). The reifier once rejected global map functions and fell back to the kernel encoder. The
header is `unsignedInt32 BE (List.length xs)`, the length-prefix shape `reifyLengthPrefixedLoop`
expects.

Pre-mono eta-expansion once lost this fusion through elm/bytes' point-free constructor aliases
(`unsignedInt8 = U8`): the inliner left a bare `U8 n`, which the name-keyed encoder recogniser
did not match. Eta-expansion now declines constructor aliases (`isCtorAlias` in
compiler/src/Compiler/PreMono/EtaExpand.elm). The body recogniser still does not accept
post-inline constructor forms (`U8 n`) the way the header recogniser accepts `U32 endian n`.

-}

-- CHECK: FusionGlobalMapFnTest: 7
-- CHECK-MLIR: scf.while
-- CHECK-MLIR: bf.write.u8

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


encodeByte : Int -> E.Encoder
encodeByte n =
    E.unsignedInt8 n


main =
    let
        xs =
            [ 7, 8, 9 ]

        bytes =
            E.encode
                (E.sequence
                    (E.unsignedInt32 BE (List.length xs)
                        :: List.map encodeByte xs
                    )
                )

        result =
            Bytes.width bytes

        _ =
            Debug.log "FusionGlobalMapFnTest" result
    in
    text (String.fromInt result)
