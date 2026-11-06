module FusionPartialOpaqueTest exposing (main)

{-| An elm/bytes encoder that mixes fixed encoders with one produced by a function argument chosen at runtime encodes all of its parts.

`encodeWith` sequences `unsignedInt8 7`, the encoder returned by its function
argument applied to `n`, and `string "hi"`. Called with `pickEnc 42` and 42, the
middle encoder writes the single byte 42, so the bytes are `[ 7, 42, 'h', 'i' ]`
and `Bytes.width` is 4.

## eco

Exercises the bytes fusion escape hatch (plans/bytes-fusion-escape-hatch.md): an unrecognised
subtree becomes an `EOpaque` (compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm) written
with `bf.write.encoder`, which delegates to the runtime walker `elm_encoder_write_into`
(runtime/src/allocator/ElmBytesRuntime.h), while the rest of the encoder stays fused. Before the
escape hatch, any unfusable subtree made the whole encoder fall back to `Elm_Kernel_Bytes_encode`.
The CHECK-MLIR lines assert one `bf.alloc` with `bf.write.u8`, `bf.write.encoder` and
`bf.write.utf8` writes.

`pickEnc` chooses between two encoders at run time. Passing `unsignedInt8` directly would be a
single-member set that the function-global devirtualisation (`devirtFnGlobals`, configured in
compiler/src/Builder/Generate.elm) resolves, making the whole encoder fuse and the
`bf.write.encoder` this test pins disappear.

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


{-| Returns one of two encoders depending on whether `n` is even, so which encoder
`encodeWith` receives is decided at runtime. Both write their argument as one
unsigned byte.
-}
pickEnc : Int -> (Int -> E.Encoder)
pickEnc n =
    if modBy 2 n == 0 then
        E.unsignedInt8

    else
        \v -> E.unsignedInt8 (v + 0)


main =
    let
        bytes =
            encodeWith (pickEnc 42) 42

        result =
            Bytes.width bytes

        _ =
            Debug.log "FusionPartialOpaqueTest" result
    in
    text (String.fromInt result)
