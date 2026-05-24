module FusionGlobalMapFnTest exposing (main)

{-| Smoke test for bytes-fusion Phase 5: `reifyMapBody`'s
`MonoVarGlobal` arm. The mapFn `encodeByte` is a top-level named
function, not an inline lambda. Before Phase 5, the reifier rejected
`MonoVarGlobal` mapFns and the encoder fell back to the kernel call;
after Phase 5 the body lookup beta-reduces `encodeByte` and produces
an `ELoop` that lowers to `scf.while` with `bf.write.u8` inside.

The width-1 header is `BE.unsignedInt32 BE (List.length xs)`, matching
the length-prefix shape `reifyLengthPrefixedLoop` expects.

The encoded buffer is `[0,0,0,3, 7, 8, 9]` — a 4-byte length prefix
followed by the three u8 items. Total width is 7.

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
