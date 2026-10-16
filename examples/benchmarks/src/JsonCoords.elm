module JsonCoords exposing (Coordinate, averages, bench, decoder, document)

{-| The kostya/benchmarks JSON benchmark: encode a document of `n` coordinate objects
(`{"x", "y", "z", "name", "opts"}`) with `Json.Encode`, decode the text back with
`Json.Decode`, and average x, y and z. Text building, float formatting and parsing, and decoding
objects field by field.

kostya's own test case must decode to 2.0, 0.5 and 0.25 at every size. The averages must equal,
exactly, the averages computed straight from the generator: every float survives the text
round trip unchanged (both backends print the shortest text that reads back as the same float),
and both sums add in the same order.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias Coordinate =
    { x : Float
    , y : Float
    , z : Float
    }


{-| Coordinate `i`: fractions with long decimal expansions, so float printing does real work.
-}
coordinate : Int -> Coordinate
coordinate i =
    let
        part k =
            toFloat (modBy 1000003 (i * k + 17)) / 1000003
    in
    Coordinate (part 7919 * 2 - 1) (part 104729 * 100) (part 1299709 / 3)


encodeCoordinate : Int -> Encode.Value
encodeCoordinate i =
    let
        c =
            coordinate i
    in
    Encode.object
        [ ( "x", Encode.float c.x )
        , ( "y", Encode.float c.y )
        , ( "z", Encode.float c.z )
        , ( "name", Encode.string ("coord " ++ String.fromInt i) )
        , ( "opts", Encode.object [ ( "1", Encode.list identity [ Encode.int 1, Encode.bool True ] ) ] )
        ]


document : Int -> String
document n =
    Encode.encode 0
        (Encode.object
            [ ( "coordinates", Encode.list encodeCoordinate (List.range 0 (n - 1)) )
            , ( "info", Encode.string "some info" )
            ]
        )


decoder : Decoder (List Coordinate)
decoder =
    Decode.field "coordinates"
        (Decode.list
            (Decode.map3 Coordinate
                (Decode.field "x" Decode.float)
                (Decode.field "y" Decode.float)
                (Decode.field "z" Decode.float)
            )
        )


averages : List Coordinate -> Coordinate
averages coordinates =
    let
        count =
            toFloat (List.length coordinates)

        sum =
            List.foldl (\c s -> Coordinate (s.x + c.x) (s.y + c.y) (s.z + c.z)) (Coordinate 0 0 0) coordinates
    in
    Coordinate (sum.x / count) (sum.y / count) (sum.z / count)


bench : Int -> Bool
bench n =
    let
        decoded =
            Decode.decodeString decoder (document n)

        kostya =
            Decode.decodeString decoder """{"coordinates":[{"x":2.0,"y":0.5,"z":0.25}]}"""
    in
    kostya
        == Ok [ Coordinate 2.0 0.5 0.25 ]
        && Result.map averages decoded
        == Ok (averages (List.map coordinate (List.range 0 (n - 1))))
