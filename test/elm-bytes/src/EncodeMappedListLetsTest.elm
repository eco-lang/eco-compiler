module EncodeMappedListLetsTest exposing (main)

{-| A fused `Bytes.Encode.sequence (List.map f xs)` loop whose item encoder binds lets.

`encodeTile` reads a `let tile = Maybe.withDefault ...` record, while `areas` binds an Int
`let` of the same name, so the loop must use its own `tile`, not the first one in the
program. `encodeNormalized` starts with a destructuring `let (Shape s) = normalize shape`,
whose path names a generated variable that the loop must bind too.

-}

-- CHECK: areas: [48,20736,186624]
-- CHECK: tiles: [(1,2,196613),(3,4,0)]
-- CHECK: normalized: [(2,2,196613),(6,4,0)]

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Tile =
    { left : Int, top : Int }


type Shape
    = Shape { x : Float, color : Int, tile : Maybe Tile }


areas : List Int -> List Int
areas ns =
    List.map
        (\n ->
            let
                tile =
                    n * 16
            in
            if tile > 100 then
                tile * tile

            else
                tile
        )
        ns


encodeTile : Shape -> E.Encoder
encodeTile (Shape s) =
    let
        f =
            E.float32 LE

        tile =
            Maybe.withDefault { left = 0, top = 0 } s.tile
    in
    E.sequence
        [ f s.x
        , E.unsignedInt32 LE s.color
        , E.unsignedInt32 LE (tile.left + tile.top * 65536)
        ]


normalize : Shape -> Shape
normalize (Shape s) =
    Shape { s | x = s.x * 2 }


encodeNormalized : Shape -> E.Encoder
encodeNormalized shape =
    let
        (Shape s) =
            normalize shape

        tile =
            Maybe.withDefault { left = 0, top = 0 } s.tile
    in
    E.sequence
        [ E.float32 LE s.x
        , E.unsignedInt32 LE s.color
        , E.unsignedInt32 LE (tile.left + tile.top * 65536)
        ]


encodeTiles : List Shape -> Bytes
encodeTiles shapes =
    E.encode (E.sequence (List.map encodeTile shapes))


encodeAllNormalized : List Shape -> Bytes
encodeAllNormalized shapes =
    E.encode (E.sequence (List.map encodeNormalized shapes))


decodeAll : Int -> Bytes -> List ( Float, Int, Int )
decodeAll n bytes =
    let
        item =
            D.map3 (\x color tile -> ( x, color, tile ))
                (D.float32 LE)
                (D.unsignedInt32 LE)
                (D.unsignedInt32 LE)

        step ( left, acc ) =
            if left == 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.map (\i -> D.Loop ( left - 1, i :: acc )) item
    in
    D.decode (D.loop ( n, [] ) step) bytes
        |> Maybe.withDefault []


main =
    let
        shapes =
            [ Shape { x = 1, color = 2, tile = Just { left = 5, top = 3 } }
            , Shape { x = 3, color = 4, tile = Nothing }
            ]

        _ =
            Debug.log "areas" (areas [ 3, 9, 27 ])

        _ =
            Debug.log "tiles" (decodeAll 2 (encodeTiles shapes))

        _ =
            Debug.log "normalized" (decodeAll 2 (encodeAllNormalized shapes))
    in
    text "done"
