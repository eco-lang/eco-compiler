module BytesEncodeRecordListFusionTest exposing (main)

{-| A length-prefixed list of records, encoded as `Bytes.Encode.sequence (count :: List.map encodeRecord records)` with each record's fields at mixed widths, encodes to the right bytes.

Each record is written as an unsigned 32-bit big-endian `id`, a little-endian
64-bit `value`, a signed 16-bit big-endian `delta` and an unsigned 8-bit `flag`,
15 bytes in all. Two records after the 4-byte count make 34 bytes.

The bytes are decoded field by field and must give back the count and both
records, including the extreme values `4294967295`, `32767` and `255`.

## eco

Exercises bytes fusion of a length-prefixed list encoder whose list element is a record. The
fused loop's item is the list element, and the body projects the record's fields and writes
them at mixed widths. The loop once projected every head as `i64` (or `f64` when all writes were
floats), because the body's writes are always primitive; for a record element that made
`eco.project.record` take an `i64` operand and the module failed to parse. The head must be
projected at the element's SSA type, `!eco.value` for a record (REP_BOUNDARY_003 in
design_docs/invariants.csv).

The CHECK-MLIR line asserts the encoder was fused (a `bf.write.f64` for `value`). The read-back
is deliberately field by field, so it is not fused.

-}

-- CHECK: width: 34
-- CHECK: decoded: "count 2: 7 1.5 -3 9; 4294967295 -0.25 32767 255"
-- CHECK-MLIR: bf.write.f64

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Record =
    { id : Int
    , value : Float
    , delta : Int
    , flag : Int
    }


encodeRecord : Record -> E.Encoder
encodeRecord r =
    E.sequence
        [ E.unsignedInt32 BE r.id
        , E.float64 LE r.value
        , E.signedInt16 BE r.delta
        , E.unsignedInt8 r.flag
        ]


encode : List Record -> Bytes
encode records =
    E.encode (E.sequence (E.unsignedInt32 BE (List.length records) :: List.map encodeRecord records))


recordDecoder : D.Decoder Record
recordDecoder =
    D.map4 Record (D.unsignedInt32 BE) (D.float64 LE) (D.signedInt16 BE) D.unsignedInt8


show : Record -> String
show r =
    String.fromInt r.id ++ " " ++ String.fromFloat r.value ++ " " ++ String.fromInt r.delta ++ " " ++ String.fromInt r.flag


main =
    let
        bytes =
            encode [ Record 7 1.5 -3 9, Record 4294967295 -0.25 32767 255 ]

        decoded =
            D.decode (D.map3 (\count a b -> "count " ++ String.fromInt count ++ ": " ++ show a ++ "; " ++ show b) (D.unsignedInt32 BE) recordDecoder recordDecoder) bytes

        _ =
            Debug.log "width" (Bytes.width bytes)

        _ =
            Debug.log "decoded" (Maybe.withDefault "failed" decoded)
    in
    text "done"
