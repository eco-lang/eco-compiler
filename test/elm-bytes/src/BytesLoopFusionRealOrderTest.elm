module BytesLoopFusionRealOrderTest exposing (main)

{-| Guard (bytes fusion, `Bytes.Decode.loop` argument order): a count-based
`Decode.loop` written in elm/bytes' real argument order
(`loop : state -> (state -> Decoder (Step state a)) -> Decoder a`) is fused:
decoded by a `bf.decoder.cursor.init` cursor and an `scf.while` reading
`bf.read.u8`, with the bytes of all items checked by one `bf.require` first.

`Reify.reifyBytesDecodeCall` (src/Compiler/Generate/MLIR/BytesFusion/
Reify.elm) used to match the arguments step function first, so no real loop
was ever fused; it also had to learn the form the inliner leaves `Decode.map`
and `Decode.succeed` in inside the step function. The decoded value,
`[3,2,1]` (`Done acc`, the accumulator built with `::`), must be what elm/bytes
gives; `BytesLoopDoneAccTest`, `BytesLoopDoneReverseTest` and
`BytesLoopDoneLengthTest` check the other `Done` results.

-}

-- CHECK: BytesLoopFusionRealOrderTest: "[3,2,1]"
-- CHECK-MLIR: bf.decoder.cursor.init
-- CHECK-MLIR: bf.read.u8
-- CHECK-MLIR: bf.require

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.sequence [ E.unsignedInt8 1, E.unsignedInt8 2, E.unsignedInt8 3 ])

        output =
            case
                D.decode
                    (D.loop ( 3, [] )
                        (\( n, acc ) ->
                            if n <= 0 then
                                D.succeed (D.Done acc)

                            else
                                D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                        )
                    )
                    bytes
            of
                Just v ->
                    "[" ++ String.join "," (List.map String.fromInt v) ++ "]"

                Nothing ->
                    "Nothing"

        _ =
            Debug.log "BytesLoopFusionRealOrderTest" output
    in
    text output
