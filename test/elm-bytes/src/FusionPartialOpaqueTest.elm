module FusionPartialOpaqueTest exposing (main)

{-| Smoke test for the bytes-fusion escape hatch (EOpaque +
bf.write.encoder). The encoder mixes:

  - Fusable primitives: `BE.unsignedInt8 7`, `BE.string "hi"`.
  - An opaque subtree: `mkEnc n` where `mkEnc` is a function
    parameter the reifier cannot statically resolve.

Before the escape hatch, the presence of any unfusable subtree
poisoned the whole encoder and the entire expression fell back to
`Elm_Kernel_Bytes_encode`. With the escape hatch the outer encoder
still fuses (single `bf.alloc` + `bf.cursor.init` + a mix of
`bf.write.u8` / `bf.write.encoder` / `bf.write.utf8` + ReturnBuffer);
only the unfusable middle delegates to the runtime walker via
`elm_encoder_write_into`.

Encoded bytes: [7, 42, 'h', 'i'] = 4 bytes when `mkEnc = E.unsignedInt8`
and `n = 42`.

-}

-- CHECK: FusionPartialOpaqueTest: 4
-- CHECK-MLIR: bf.alloc
-- CHECK-MLIR: bf.write.encoder
-- CHECK-MLIR: bf.write.u8
-- CHECK-MLIR: bf.write.utf8

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


encodeWith : (Int -> E.Encoder) -> Int -> Bytes
encodeWith mkEnc n =
    E.encode
        (E.sequence
            [ E.unsignedInt8 7
            , mkEnc n
            , E.string "hi"
            ]
        )


main =
    let
        bytes =
            encodeWith E.unsignedInt8 42

        result =
            Bytes.width bytes

        _ =
            Debug.log "FusionPartialOpaqueTest" result
    in
    text (String.fromInt result)
