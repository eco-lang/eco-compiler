module BytesRows exposing (benchF32, benchU8)

{-| Encode `n` rows of 384 values, then decode them back into a list of rows with one count loop
(`Decode.loop`) per row inside a count loop over the rows: the shape of an embedding store read
from disk. Two workloads:

  - `bytes-f32-rows` reads every value with `Decode.float32 LE` into a `List (List Float)`.
  - `bytes-u8-rows` reads every value with `Decode.unsignedInt8` into a `List (List Int)`.

On eco neither shape was fused, and both allocated heavily (`eco-bugs.md`, number 7);
`bytes-static` covers a single flat `unsignedInt8` loop. Every value is a whole number below 4,096
divided by 8, which a `float32` holds exactly, so the decoded rows must equal the generated ones
exactly, and the buffer must be `n` rows long, at every size.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode


width : Int
width =
    384


rows : (Int -> Int -> a) -> Int -> List (List a)
rows value n =
    List.map (\r -> List.map (value r) (List.range 0 (width - 1))) (List.range 0 (n - 1))


f32Value : Int -> Int -> Float
f32Value r i =
    toFloat (modBy 4096 (r * 31 + i * 17)) / 8


u8Value : Int -> Int -> Int
u8Value r i =
    modBy 256 (r * 31 + i * 17)


row : Decoder a -> Decoder (List a)
row item =
    Decode.loop ( width, [] )
        (\( left, acc ) ->
            if left <= 0 then
                Decode.succeed (Done (List.reverse acc))

            else
                Decode.map (\x -> Loop ( left - 1, x :: acc )) item
        )


table : Int -> Decoder a -> Decoder (List (List a))
table n item =
    Decode.loop ( n, [] )
        (\( left, acc ) ->
            if left <= 0 then
                Decode.succeed (Done (List.reverse acc))

            else
                Decode.map (\x -> Loop ( left - 1, x :: acc )) (row item)
        )


run : Int -> Int -> (a -> Encode.Encoder) -> Decoder a -> List (List a) -> Bool
run n itemWidth encodeItem item generated =
    let
        bytes =
            Encode.encode (Encode.sequence (List.map encodeItem (List.concat generated)))
    in
    Bytes.width bytes == n * width * itemWidth && Decode.decode (table n item) bytes == Just generated


benchF32 : Int -> Bool
benchF32 n =
    run n 4 (Encode.float32 LE) (Decode.float32 LE) (rows f32Value n)


benchU8 : Int -> Bool
benchU8 n =
    run n 1 Encode.unsignedInt8 Decode.unsignedInt8 (rows u8Value n)
