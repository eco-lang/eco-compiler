module BytesLoopFusionShapesTest exposing (main)

{-| Count-based and sentinel-terminated `Bytes.Decode.loop` decoders give the expected lists, including the edge cases where the input runs out or the count is not positive.

The count loops take their count as a state and end with
`Done (List.reverse acc)`, so they return items in read order:

  - `count_first2`: reading 2 unsigned bytes from `5 6 7` gives `[5,6]`.
  - `count_too_many`: reading 5 from 3 bytes fails, giving `Nothing`.
  - `count_negative` and `count_zero`: a count of -1 or 0 reads nothing and
    gives `[]`.
  - `count_u16le`: two `unsignedInt16 LE` reads from `2 1 4 3` give `[258,772]`.
  - `count_f64be`: two `float64 BE` reads give `[1.5,-2.25]`.

The sentinel loops read unsigned bytes with `andThen` and stop at a `0`:

  - `sentinel_in_order`: `1 2 0 9` gives `[1,2]`, in read order; the trailing
    byte is left unread.
  - `sentinel_reversed`: `1 2 0` with `Done acc` gives `[2,1]`.
  - `sentinel_missing`: `1 2 3` has no `0`, so the decode fails with `Nothing`.

## eco

Exercises the loop shapes `reifyLoop` in compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm fuses, including the
failure and edge cases the fused code must reproduce. The CHECK-MLIR lines assert that the
`unsignedInt8` loops (one count loop and the two sentinel loops) were fused. The
`unsignedInt16 LE` and `float64 BE` loops are checked for their values only: the inliner turns
those item decoders into a `Decoder` around a kernel read, which `reifyDecoder` in the same file
does not recognise, so they are not fused.

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
