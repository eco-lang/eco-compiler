module BytesFrame exposing (bench, benchPrefixed)

{-| Encode the same scene of 2,000 triangle records `n` times, as a renderer sends an unchanged
frame: `Encode.encode (Encode.sequence (List.map encodeTriangle triangles))`, each triangle a
`u32` id and three `float32` coordinates (16 bytes), written by a function whose parameter is a
pattern. Two workloads do the same work:

  - `bytes-frame` writes the list alone, with no length before it.
  - `bytes-frame-prefixed` writes `unsignedInt32 (List.length triangles)` first, the shape
    eco's encoder fusion has long recognised, so the ratio between the two shows what the
    plain shape costs.

Every frame's width must be the scene's, and the last frame must decode back to the scene
exactly (the coordinates are multiples of 1/4 below 1,024, which `float32` holds exactly), at
every size.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode


type Triangle
    = Triangle { id : Int, x : Float, y : Float, z : Float }


triangleCount : Int
triangleCount =
    2000


scene : List Triangle
scene =
    List.map
        (\i ->
            Triangle
                { id = i * 2654435761 |> modBy 4294967296
                , x = toFloat (modBy 4096 (i * 37)) / 4
                , y = toFloat (modBy 4096 (i * 101 + 5)) / 4
                , z = toFloat (modBy 4096 (i * 7 + 11)) / 4
                }
        )
        (List.range 0 (triangleCount - 1))


encodeTriangle : Triangle -> Encode.Encoder
encodeTriangle (Triangle t) =
    Encode.sequence
        [ Encode.unsignedInt32 LE t.id
        , Encode.float32 LE t.x
        , Encode.float32 LE t.y
        , Encode.float32 LE t.z
        ]


encodeFrame : List Triangle -> Bytes
encodeFrame triangles =
    Encode.encode (Encode.sequence (List.map encodeTriangle triangles))


encodeFramePrefixed : List Triangle -> Bytes
encodeFramePrefixed triangles =
    Encode.encode
        (Encode.sequence
            (Encode.unsignedInt32 LE (List.length triangles) :: List.map encodeTriangle triangles)
        )


decodeTriangle : Decoder Triangle
decodeTriangle =
    Decode.map4 (\id x y z -> Triangle { id = id, x = x, y = y, z = z })
        (Decode.unsignedInt32 LE)
        (Decode.float32 LE)
        (Decode.float32 LE)
        (Decode.float32 LE)


decodeTriangles : Int -> Decoder (List Triangle)
decodeTriangles count =
    Decode.loop ( count, [] )
        (\( left, acc ) ->
            if left <= 0 then
                Decode.succeed (Done (List.reverse acc))

            else
                Decode.map (\t -> Loop ( left - 1, t :: acc )) decodeTriangle
        )


{-| Encodes the scene `n` times with `encode`; true if every frame is `width` bytes and the last
one decodes back to the scene with `decoder`.
-}
run : (List Triangle -> Bytes) -> Int -> Decoder (List Triangle) -> Int -> Bool
run encode width decoder n =
    let
        triangles =
            scene

        go : Int -> Bool -> Maybe Bytes -> ( Bool, Maybe Bytes )
        go left ok last =
            if left <= 0 then
                ( ok, last )

            else
                let
                    bytes =
                        encode triangles
                in
                go (left - 1) (ok && Bytes.width bytes == width) (Just bytes)
    in
    case go n True Nothing of
        ( True, Just bytes ) ->
            Decode.decode decoder bytes == Just triangles

        ( ok, Nothing ) ->
            ok

        ( False, _ ) ->
            False


bench : Int -> Bool
bench n =
    run encodeFrame (16 * triangleCount) (decodeTriangles triangleCount) n


benchPrefixed : Int -> Bool
benchPrefixed n =
    run encodeFramePrefixed
        (4 + 16 * triangleCount)
        (Decode.unsignedInt32 LE |> Decode.andThen decodeTriangles)
        n
