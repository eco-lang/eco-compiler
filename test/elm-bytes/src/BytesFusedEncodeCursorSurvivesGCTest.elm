module BytesFusedEncodeCursorSurvivesGCTest exposing (main)

{-| SD-22 (review-bug-list.md): a fused encoder's cursor is a pair of raw
pointers into the buffer it allocated with `bf.alloc`. A buffer under the
8 KiB large-object threshold lives in the nursery, and the per-item value
expression of a fused length-prefixed list encoder
`E.sequence (E.unsignedInt32 BE (List.length xs) :: List.map encodeItem xs)`
(the shape `Reify.reifyLengthPrefixedLoop` fuses) is compiled INSIDE the
`scf.while` write loop, after `bf.alloc`. When that expression allocates, a minor GC can
run mid-encode: it moves the (rooted) buffer, but the cursor keeps writing
into the evacuated nursery memory, so every byte written after the GC is
lost from the returned `Bytes` (and lands on whatever the nursery reuses
that memory for).

Each of the 4,000 items here allocates a 3,000-cell list (about 100 KB), so
one 4,000-byte encode allocates about 400 MB, which is several minor GCs at
any default nursery size (64 MB eden), all with the cursor live. The bytes
are then read back one at a time (`byteAt`, which allocates little, so the
read-back itself almost never meets a GC) and compared with the values
computed directly.

Observed 2026-10-24 (AOT, default heap config): "mismatches=3671 width=4004"
with 31 minor GCs.

Fixed 2026-10-24 (BFOPS\_039): BFToLLVM re-derives the cursor from the
relocated buffer after each GC point, and makes the buffer a builder while it
is filled, so the concurrent tenure job never copies it from under the writes
(HEAP\_SNAPSHOT\_001). Re-deriving alone left one inter-GC window of bytes
lost ("mismatches=376").

-}

-- CHECK: BytesFusedEncodeCursorSurvivesGCTest: "mismatches=0 width=4004"
-- CHECK-MLIR: bf.write.u8

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


{-| Allocates a list of 3,000 cells, then folds it to a byte. Opaque enough
that no optimisation removes the allocation.
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
