module BytesLoopDoneLengthTest exposing (main)

{-| Guard (bytes fusion soundness): a count-based `Decode.loop` whose `Done`
returns `List.length acc`, an `Int` rather than the list: `3`.

It is not fused (`Reify.reifyLoop` fuses only `Done acc` and
`Done (List.reverse acc)`) and must print the value elm/bytes gives.

Guards the soundness of loop fusion: `Reify.reifyLoop` (src/Compiler/Generate/
MLIR/BytesFusion/Reify.elm) must honour the `Done` expression, so that
`Done acc`, `Done (List.reverse acc)` and `Done (List.length acc)` are fused to
distinct, correct forms or not fused at all. An earlier recogniser looked only
at the item decoder and would have fused all three to the same list.

-}

-- CHECK: BytesLoopDoneLengthTest: "3"
-- CHECK-MLIR-NOT: bf.read.u8

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
                                D.succeed (D.Done (List.length acc))

                            else
                                D.map (\x -> D.Loop ( n - 1, x :: acc )) D.unsignedInt8
                        )
                    )
                    bytes
            of
                Just v ->
                    String.fromInt v

                Nothing ->
                    "Nothing"

        _ =
            Debug.log "BytesLoopDoneLengthTest" output
    in
    text output
