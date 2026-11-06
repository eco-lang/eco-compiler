module BytesFusedEncodeCursorSurvivesGCTest exposing (main)

{-| A length-prefixed list encoder whose per-item byte is computed by an allocation-heavy function writes every byte correctly.

The encoder is `Bytes.Encode.sequence (count :: List.map encodeItem xs)` over
the 4,000 integers `0` to `3999`. Each item's byte is `heavy x`, which builds
and folds a 3,000-element list, so encoding the 4,004 bytes allocates a great
deal along the way.

The bytes after the 4-byte count are read back one at a time and compared with
`heavy` computed directly for each item; the test expects no mismatches and a
width of 4,004.

## eco

Exercises a minor GC while a fused encoder's write cursor is live. The cursor is a pair of raw
pointers into the buffer allocated by `bf.alloc`. For the length-prefixed list shape that
`reifyLengthPrefixedLoop` in compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm fuses,
the per-item expression is compiled inside the `scf.while` write loop, after `bf.alloc`, so an
allocating `heavy` can trigger a GC mid-encode. Each item allocates about 100 KB, about 400 MB
per encode: several minor GCs at the default 64 MB eden. The read-back (`byteAt`) allocates
little, so it rarely meets a GC itself.

Before the fix the GC moved the rooted buffer but the cursor kept writing into the evacuated
nursery memory ("mismatches=3671", review item SD-22 in plans/review-bug-list-fixes.md).
runtime/src/codegen/Passes/BFToLLVM.cpp now re-derives the cursor from the relocated buffer after
each GC point (BFOPS_039 in design_docs/invariants.csv) and marks the buffer as a builder while
it is filled, so the concurrent tenure job does not copy it from under the writes
(HEAP_SNAPSHOT_001). The CHECK-MLIR line asserts the encoder was fused.

-}

-- CHECK: BytesFusedEncodeCursorSurvivesGCTest: "mismatches=0 width=4004"
-- CHECK-MLIR: bf.write.u8

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


{-| Returns a byte (0 to 255) computed from `x` by building and folding a
3,000-element list.
-}
heavy : Int -> Int
heavy x =
    List.range 0 2999
        |> List.map (\i -> i * x + 1)
        |> List.foldl (\v acc -> modBy 251 (acc * 31 + v)) x
        |> modBy 256


items : List Int
items =
    List.range 0 3999


encodeItem : Int -> E.Encoder
encodeItem x =
    E.sequence [ E.unsignedInt8 (heavy x) ]


encodeAll : List Int -> Bytes
encodeAll xs =
    E.encode (E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map encodeItem xs))


{-| The byte at offset k: skip k bytes, then one `unsignedInt8`.
-}
byteAt : Bytes -> Int -> Int
byteAt bytes k =
    case D.decode (D.map2 (\_ b -> b) (D.bytes k) D.unsignedInt8) bytes of
        Just b ->
            b

        Nothing ->
            -1


main =
    let
        bytes =
            encodeAll items

        expected =
            List.map heavy items

        mismatches =
            List.map2 (\k e -> if byteAt bytes (4 + k) == e then 0 else 1) items expected
                |> List.sum

        output =
            "mismatches=" ++ String.fromInt mismatches ++ " width=" ++ String.fromInt (Bytes.width bytes)

        _ =
            Debug.log "BytesFusedEncodeCursorSurvivesGCTest" output
    in
    text output
