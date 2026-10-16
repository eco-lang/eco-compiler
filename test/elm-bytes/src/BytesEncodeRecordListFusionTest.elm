module BytesEncodeRecordListFusionTest exposing (main)

{-| Guard (bytes fusion, `Encode.sequence (header :: List.map encodeRecord records)`): the
fused loop's item is the list element, here a RECORD whose fields the body writes at mixed widths
(u32, f64, i16, u8). The loop used to project every head as `i64` (or `f64` when all writes were
floats), because the body's writes are always primitive; for a record element that made
`eco.project.record` take an `i64` operand and the module failed to parse. The head must be
projected at the element's SSA type (REP_BOUNDARY_003), `!eco.value` for a record.

The bytes are decoded field by field (unfused) and must give back every record.

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
