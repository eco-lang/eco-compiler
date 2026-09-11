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

NOTE (2026-09-10/11): under pre-mono η-expansion this fusion was lost — not
through `encodeByte` (`Encoder` is a custom type here, so it has no deficit)
but through elm/bytes' point-free CONSTRUCTOR aliases (`unsignedInt8 = U8`):
η made them one-line functions, the post-mono inliner replaced
`E.unsignedInt8 n` inside `encodeByte` by the bare `U8 n`, and
`reifyBytesEncodeCall` (keyed on the global's NAME) no longer matched. Since
2026-09-11 η is DEFAULT-ON and refuses constructor aliases
(`EtaExpand.isCtorAlias`, `declined.ctorAlias`), so this pin holds under
either flag setting; `Reify.etaReduceTrailingParam` additionally looks through
an η-expanded arrow-alias helper. A remaining limitation, independent of η:
the body recogniser does not accept post-inline constructor forms
(`U8 n`) the way the header recogniser accepts `U32 endian n`.
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
