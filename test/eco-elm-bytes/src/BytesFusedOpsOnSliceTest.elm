module BytesFusedOpsOnSliceTest exposing (main)

{-| A two-field decoder run on `Bytes` cut from a larger buffer with `Bytes.Decode.bytes` reads the start of that slice correctly.

The buffer is 50 bytes: the big-endian 16-bit values 258 and 772, then 46 zero
bytes. Its first 40 bytes are taken as a new `Bytes` value, and a `map2` of two
`unsignedInt16 BE` reads is run on that, combining them as
`258 * 10000 + 772 = 2580772`.

## eco

Exercises a fused decoder over a `Tag_ByteBufferSlice` input. If the bytes-fusion pass
(`compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm`) fuses the `map2`, the decoder
cursor is set up by `bf.decoder.cursor.init`, lowered in
`runtime/src/codegen/Passes/BFToLLVM.cpp`, which once read the length through
`elm_bytebuffer_len` and asserted on slices (finding F3 / gap G7 in `plans/string-bytes-
testing-gap.md`). Assert-enabled builds then aborted; unfused reads were always slice-
safe.

-}

-- CHECK: fused_pair: 2580772

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        buffer =
            E.encode
                (E.sequence
                    (E.unsignedInt16 BE 258
                        :: E.unsignedInt16 BE 772
                        :: List.repeat 46 (E.unsignedInt8 0)
                    )
                )

        decoder =
            D.map2 (\a b -> a * 10000 + b) (D.unsignedInt16 BE) (D.unsignedInt16 BE)

        pair =
            D.decode (D.bytes 40) buffer
                |> Maybe.andThen (\s -> D.decode decoder s)
                |> Maybe.withDefault -1

        _ =
            Debug.log "fused_pair" pair
    in
    text "done"
