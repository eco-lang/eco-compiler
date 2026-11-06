module BytesLoopDoneReverseTest exposing (main)

{-| A count-based `Bytes.Decode.loop` whose `Done` reverses the accumulator gives the items in read order.

The loop reads three unsigned bytes, `1 2 3`, consing each onto the
accumulator, so `Done (List.reverse acc)` yields `[1,2,3]`. Sibling tests run
the same loop with `Done acc` and `Done (List.length acc)`.

## eco

Exercises the soundness of `Bytes.Decode.loop` fusion: `reifyLoop` in
compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm must honour the `Done` expression, so that `Done acc`,
`Done (List.reverse acc)` and `Done (List.length acc)` are fused to distinct, correct forms or
not fused at all. An earlier recogniser looked only at the item decoder and would have fused all
three to the same list. This one is fused to a loop whose list is reversed into read order; the CHECK-MLIR line asserts the fused `bf.read.u8`. The siblings are
test/eco-mlir/src/BytesLoopDoneAccTest.elm, test/eco-mlir/src/BytesLoopDoneReverseTest.elm and
test/eco-mlir/src/BytesLoopDoneLengthTest.elm.

-}

-- CHECK: BytesLoopDoneReverseTest: "[1,2,3]"
-- CHECK-MLIR: bf.read.u8

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
                                D.succeed (D.Done (List.reverse acc))

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
            Debug.log "BytesLoopDoneReverseTest" output
    in
    text output
