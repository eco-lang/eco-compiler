module BinaryFormat exposing (bench)

{-| A PNG-like chunked binary file through `elm/bytes`: an 8-byte signature, then `n` chunks, each
a big-endian 32-bit length, a 4-byte type, a body of mixed fields (an unsigned 32-bit int
little-endian, a signed 16-bit int big-endian, a `float32` and a `float64` in both byte orders,
then a run of raw bytes) and a CRC-32 of type and body. Encoded with `Bytes.Encode`, decoded with
`Decode.andThen` on each chunk's length and `Decode.loop` over the chunks, so the mixed widths
(which eco's decoder fusion does not cover yet) go through the general decoder.

Checked at every size: decoding must give back every generated chunk exactly, and every stored
CRC must equal the CRC recomputed from the decoded type and body (`Crc32.crc`).

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode exposing (Encoder)
import Crc32


type alias Body =
    { id : Int
    , delta : Int
    , single : Float
    , double : Float
    , raw : List Int
    }


type alias Chunk =
    { kind : String
    , body : Body
    , crc : Int
    }


signature : List Int
signature =
    [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ]


kinds : List String
kinds =
    [ "IHDR", "tEXt", "IDAT", "zTXt", "pHYs" ]


body : Int -> Body
body k =
    Body (modBy 4294967296 (k * 40503 + 7))
        (modBy 65536 (k * 31) - 32768)
        -- a float32 holds this exactly: a small integer over a power of two
        (toFloat (modBy 4096 k) / 16)
        (toFloat k / 3)
        (List.map (\i -> modBy 256 (k * 7 + i * 13)) (List.range 0 (modBy 24 k)))


kindOf : Int -> String
kindOf k =
    Maybe.withDefault "IDAT" (List.head (List.drop (modBy 5 k) kinds))


encodeBody : Body -> Encoder
encodeBody b =
    Encode.sequence
        ([ Encode.unsignedInt32 LE b.id
         , Encode.signedInt16 BE b.delta
         , Encode.float32 BE b.single
         , Encode.float32 LE b.single
         , Encode.float64 BE b.double
         , Encode.float64 LE b.double
         ]
            ++ List.map Encode.unsignedInt8 b.raw
        )


bodyBytes : Body -> List Int
bodyBytes b =
    bytesOf (Encode.encode (encodeBody b))


bytesOf : Bytes -> List Int
bytesOf bytes =
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) byteStep) bytes |> Maybe.withDefault []


byteStep : ( Int, List Int ) -> Decoder (Step ( Int, List Int ) (List Int))
byteStep ( left, acc ) =
    if left <= 0 then
        Decode.succeed (Done (List.reverse acc))

    else
        Decode.map (\x -> Loop ( left - 1, x :: acc )) Decode.unsignedInt8


ascii : String -> List Int
ascii s =
    List.map Char.toCode (String.toList s)


chunk : Int -> Chunk
chunk k =
    let
        b =
            body k

        kind =
            kindOf k
    in
    Chunk kind b (Crc32.crc (ascii kind ++ bodyBytes b))


encodeChunk : Chunk -> Encoder
encodeChunk c =
    let
        b =
            Encode.encode (encodeBody c.body)
    in
    Encode.sequence
        [ Encode.unsignedInt32 BE (Bytes.width b)
        , Encode.string c.kind
        , Encode.bytes b
        , Encode.unsignedInt32 BE c.crc
        ]


file : List Chunk -> Bytes
file chunks =
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 signature ++ List.map encodeChunk chunks))


bodyDecoder : Int -> Decoder Body
bodyDecoder length =
    Decode.map4 (\id delta single ( double, raw ) -> Body id delta single double raw)
        (Decode.unsignedInt32 LE)
        (Decode.signedInt16 BE)
        (Decode.float32 BE
            |> Decode.andThen
                (\fromBe ->
                    Decode.float32 LE
                        |> Decode.andThen
                            (\fromLe ->
                                if fromBe == fromLe then
                                    Decode.succeed fromBe

                                else
                                    Decode.fail
                            )
                )
        )
        (Decode.map3 (\be le raw -> ( if be == le then be else 0 / 0, raw ))
            (Decode.float64 BE)
            (Decode.float64 LE)
            (Decode.loop ( length - 30, [] ) byteStep)
        )


chunkDecoder : Decoder Chunk
chunkDecoder =
    Decode.unsignedInt32 BE
        |> Decode.andThen
            (\length ->
                Decode.map3 Chunk
                    (Decode.string 4)
                    (bodyDecoder length)
                    (Decode.unsignedInt32 BE)
            )


fileDecoder : Int -> Decoder (List Chunk)
fileDecoder count =
    Decode.loop ( 8, [] ) byteStep
        |> Decode.andThen
            (\sig ->
                if sig /= signature then
                    Decode.fail

                else
                    Decode.loop ( count, [] )
                        (\( left, acc ) ->
                            if left <= 0 then
                                Decode.succeed (Done (List.reverse acc))

                            else
                                Decode.map (\c -> Loop ( left - 1, c :: acc )) chunkDecoder
                        )
            )


bench : Int -> Bool
bench n =
    let
        chunks =
            List.map chunk (List.range 1 n)

        decoded =
            Decode.decode (fileDecoder n) (file chunks)

        crcOk c =
            c.crc == Crc32.crc (ascii c.kind ++ bodyBytes c.body)
    in
    decoded == Just chunks && List.all crcOk (Maybe.withDefault [] decoded)
