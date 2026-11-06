module BytesLoopDoneLengthTest exposing (main)

{-| A count-based `Bytes.Decode.loop` whose `Done` returns the length of the accumulated list gives that `Int`, not the list.

The loop reads three unsigned bytes, `1 2 3`, consing each onto the
accumulator, and `Done (List.length acc)` yields `3`. Sibling tests run the same
loop with `Done acc` and `Done (List.reverse acc)`.

## eco

Exercises the soundness of `Bytes.Decode.loop` fusion: `reifyLoop` in
compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm must honour the `Done` expression, so that `Done acc`,
`Done (List.reverse acc)` and `Done (List.length acc)` are fused to distinct, correct forms or
not fused at all. An earlier recogniser looked only at the item decoder and would have fused all
three to the same list. This one is not fused (`reifyLoop` fuses only `Done acc` and `Done (List.reverse acc)`); the CHECK-MLIR-NOT line asserts no `bf.read.u8` appears. The siblings are
test/eco-mlir/src/BytesLoopDoneAccTest.elm, test/eco-mlir/src/BytesLoopDoneReverseTest.elm and
test/eco-mlir/src/BytesLoopDoneLengthTest.elm.

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
