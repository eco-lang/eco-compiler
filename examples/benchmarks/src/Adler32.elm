module Adler32 exposing (bench)

{-| Adler-32 (the zlib checksum) over a generated `Bytes` buffer of `n` bytes, read one byte at a
time with a `Decode.loop` that carries the two running sums, so this prices the decoder's
per-step cost on the general path (the loop's state is not a list, so eco does not fuse it).

Every run checks the standard example, `Adler32("Wikipedia") = 0x11E60398`, and at the sizes in
`known` the checksum must match Python's `zlib.adler32` of the same bytes.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode exposing (Step(..))
import Bytes.Encode as Encode


adler32 : Bytes -> Int
adler32 bytes =
    Decode.decode
        (Decode.loop ( Bytes.width bytes, 1, 0 )
            (\( left, a, b ) ->
                if left <= 0 then
                    Decode.succeed (Done (b * 65536 + a))

                else
                    Decode.map
                        (\x ->
                            let
                                a2 =
                                    modBy 65521 (a + x)
                            in
                            Loop ( left - 1, a2, modBy 65521 (b + a2) )
                        )
                        Decode.unsignedInt8
            )
        )
        bytes
        |> Maybe.withDefault -1


input : Int -> Bytes
input n =
    Encode.encode (Encode.sequence (List.map (\i -> Encode.unsignedInt8 (modBy 256 (i * 7919 + i // 251))) (List.range 0 (n - 1))))


{-| `( n, Adler-32 of input n )`, from Python's `zlib.adler32`.
-}
known : List ( Int, Int )
known =
    [ ( 1000, 3470849018 ), ( 10000, 4011095890 ), ( 1000000, 2570185600 ) ]


bench : Int -> Bool
bench n =
    let
        result =
            adler32 (input n)

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    result == expected

                [] ->
                    True
    in
    adler32 (Encode.encode (Encode.string "Wikipedia")) == 0x11E60398 && matchesKnown
