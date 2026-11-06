module BytesLoopFusionRealOrderTest exposing (main)

{-| A count-based `Bytes.Decode.loop`, with the initial state first and the step function second, decodes three bytes into the accumulated list.

The step function uses `Bytes.Decode.map` to read one unsigned byte and cons it
onto the accumulator, and `Bytes.Decode.succeed` to finish with `Done acc`
after three reads. The input `1 2 3` therefore decodes to `[3,2,1]`.

## eco

Exercises `Bytes.Decode.loop` fusion with elm/bytes' real argument order
(`loop : state -> (state -> Decoder (Step state a)) -> Decoder a`). The CHECK-MLIR lines assert
it is fused: a `bf.decoder.cursor.init` cursor, an `scf.while` reading `bf.read.u8`, and one
`bf.require` checking the bytes of all items first.

`reifyBytesDecodeCall` in compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm once matched the step function
first, so no real loop was ever fused; it also had to learn the form the inliner leaves
`Bytes.Decode.map` and `Bytes.Decode.succeed` in inside the step function. The other `Done`
results are checked by test/eco-mlir/src/BytesLoopDoneAccTest.elm,
test/eco-mlir/src/BytesLoopDoneReverseTest.elm and test/eco-mlir/src/BytesLoopDoneLengthTest.elm.

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
