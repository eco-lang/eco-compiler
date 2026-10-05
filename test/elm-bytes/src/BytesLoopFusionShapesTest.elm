module BytesLoopFusionShapesTest exposing (main)

{-| Guard (bytes fusion, `Decode.loop`): the loop shapes `Reify.reifyLoop`
fuses, each checked for the value elm/bytes gives, including the failure and
edge cases the fused code must reproduce:

  - count loops in read order from a function argument (`n` = 2 of 3 bytes,
    `n` larger than the input, which fails, `n` negative and `n` zero, both
    the empty list), with `unsignedInt16 LE` items and with `float64 BE` items;
  - sentinel loops (`andThen` on `unsignedInt8`, stopping at 0) in read order,
    in reverse read order, and with no sentinel before the input ends, which
    fails.

The CHECK-MLIR lines check that the `unsignedInt8` loops were fused (one count
loop and the two sentinel loops). The `unsignedInt16 LE` and `float64 BE` loops
are checked for their values only: the inliner turns those item decoders into
a `Decoder` around a kernel read, which `Reify.reifyDecoder` does not
recognise, so they are not fused today.

-}

-- CHECK: count_first2: "[5,6]"
-- CHECK: count_too_many: "Nothing"
-- CHECK: count_negative: "[]"
-- CHECK: count_zero: "[]"
-- CHECK: count_u16le: "[258,772]"
-- CHECK: count_f64be: "[1.5,-2.25]"
-- CHECK: sentinel_in_order: "[1,2]"
-- CHECK: sentinel_reversed: "[2,1]"
-- CHECK: sentinel_missing: "Nothing"
-- CHECK-MLIR: bf.read.u8
-- CHECK-MLIR: bf.require

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


bytesOf : List Int -> Bytes
bytesOf xs =
    E.encode (E.sequence (List.map E.unsignedInt8 xs))


showInts : Maybe (List Int) -> String
showInts result =
    case result of
        Just xs ->
            "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"

        Nothing ->
            "Nothing"


showFloats : Maybe (List Float) -> String
showFloats result =
    case result of
        Just xs ->
            "[" ++ String.join "," (List.map String.fromFloat xs) ++ "]"

        Nothing ->
            "Nothing"


countU8 : Int -> Bytes -> Maybe (List Int)
countU8 n bytes =
    D.decode
        (D.loop ( n, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) D.unsignedInt8
            )
        )
        bytes


countU16LE : Bytes -> Maybe (List Int)
countU16LE bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) (D.unsignedInt16 LE)
            )
        )
        bytes


countF64BE : Bytes -> Maybe (List Float)
countF64BE bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) (D.float64 BE)
            )
        )
        bytes


sentinelInOrder : Bytes -> Maybe (List Int)
sentinelInOrder bytes =
    D.decode
        (D.loop []
            (\acc ->
                D.unsignedInt8
                    |> D.andThen
                        (\b ->
                            if b == 0 then
                                D.succeed (D.Done (List.reverse acc))

                            else
                                D.succeed (D.Loop (b :: acc))
                        )
            )
        )
        bytes


sentinelReversed : Bytes -> Maybe (List Int)
sentinelReversed bytes =
    D.decode
        (D.loop []
            (\acc ->
                D.unsignedInt8
                    |> D.andThen
                        (\b ->
                            if b == 0 then
                                D.succeed (D.Done acc)

                            else
                                D.succeed (D.Loop (b :: acc))
                        )
            )
        )
        bytes


main =
    let
        _ =
            Debug.log "count_first2" (showInts (countU8 2 (bytesOf [ 5, 6, 7 ])))

        _ =
            Debug.log "count_too_many" (showInts (countU8 5 (bytesOf [ 5, 6, 7 ])))

        _ =
            Debug.log "count_negative" (showInts (countU8 -1 (bytesOf [ 5 ])))

        _ =
            Debug.log "count_zero" (showInts (countU8 0 (bytesOf [])))

        _ =
            Debug.log "count_u16le" (showInts (countU16LE (bytesOf [ 2, 1, 4, 3 ])))

        _ =
            Debug.log "count_f64be"
                (showFloats (countF64BE (E.encode (E.sequence [ E.float64 BE 1.5, E.float64 BE -2.25 ]))))

        _ =
            Debug.log "sentinel_in_order" (showInts (sentinelInOrder (bytesOf [ 1, 2, 0, 9 ])))

        _ =
            Debug.log "sentinel_reversed" (showInts (sentinelReversed (bytesOf [ 1, 2, 0 ])))

        _ =
            Debug.log "sentinel_missing" (showInts (sentinelInOrder (bytesOf [ 1, 2, 3 ])))
    in
    text "done"
