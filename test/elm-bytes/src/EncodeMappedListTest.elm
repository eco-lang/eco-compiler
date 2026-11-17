module EncodeMappedListTest exposing (main)

{-| `Bytes.Encode.sequence (List.map f xs)`, with no length prefix, writes each element
in order, for a list of any length.

The mapped function takes a pattern, binds a `let` of its own and writes fixed-width
numbers, so the encoder is fused into one loop that counts the list at run time. The
`_ =` bindings after it check that the loop's names do not leak into the code after it.

-}

-- CHECK: widths: (36,0)
-- CHECK: decoded: [(1,1.5,4294967295),(2,-2.25,0),(3,0,7)]
-- CHECK: after: 3

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Point
    = Point { id : Int, x : Float, tag : Int }


encodePoint : Point -> E.Encoder
encodePoint (Point p) =
    let
        f =
            E.float32 LE
    in
    E.sequence [ E.unsignedInt16 BE p.id, E.unsignedInt16 LE 0, f p.x, E.unsignedInt32 LE p.tag ]


encodeAll : List Point -> Bytes
encodeAll points =
    E.encode (E.sequence (List.map encodePoint points))


decodePoint : D.Decoder ( Int, Float, Int )
decodePoint =
    D.map4 (\id _ x tag -> ( id, x, tag ))
        (D.unsignedInt16 BE)
        (D.unsignedInt16 LE)
        (D.float32 LE)
        (D.unsignedInt32 LE)


main =
    let
        points =
            [ Point { id = 1, x = 1.5, tag = 4294967295 }
            , Point { id = 2, x = -2.25, tag = 0 }
            , Point { id = 3, x = 0, tag = 7 }
            ]

        bytes =
            encodeAll points

        decoded =
            D.decode (D.loop ( 3, [] ) (\( n, acc ) -> if n == 0 then D.succeed (D.Done (List.reverse acc)) else D.map (\p -> D.Loop ( n - 1, p :: acc )) decodePoint)) bytes

        _ =
            Debug.log "widths" ( Bytes.width bytes, Bytes.width (encodeAll []) )

        _ =
            Debug.log "decoded" (Maybe.withDefault [] decoded)

        _ =
            Debug.log "after" (List.length points)
    in
    text "done"
