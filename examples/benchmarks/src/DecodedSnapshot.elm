module DecodedSnapshot exposing (bench)

{-| Decode a binary snapshot of `n` records into a `Dict String Entry` and keep all of it live
while it is checked: the shape of a program that loads an index from disk at start-up. Each
record holds a name, one to four tags, and a vector of 96 `float32`s read into an `Array Float`.

This prices decoding, but mostly the memory the decoded values take, which `run.mjs` reports as
peak RSS. On eco decoded data has been measured at about 8 times its encoded size, about 50
bytes per `Float` (`eco-bugs.md`, number 8).

Every vector value is a whole number below 4,096 divided by 8, which a `float32` holds exactly.
The check rebuilds every total from the generator with `Int`s: the number of entries, the sum of
every vector, the number of tags and the total length of the names, and looks up the first and
last names. All must agree exactly, at every size.

-}

import Array exposing (Array)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode
import Dict exposing (Dict)


type alias Entry =
    { name : String
    , tags : List String
    , vector : Array Float
    }


dims : Int
dims =
    96


name : Int -> String
name r =
    "entry-" ++ String.fromInt r


tags : Int -> List String
tags r =
    List.map (\t -> "tag" ++ String.fromInt (modBy 50 (r + t * 7))) (List.range 0 (modBy 4 r))


valueCode : Int -> Int -> Int
valueCode r i =
    modBy 4096 (r * 31 + i * 17)



-- ENCODE


encodeString : String -> Encode.Encoder
encodeString s =
    Encode.sequence [ Encode.unsignedInt16 BE (Encode.getStringWidth s), Encode.string s ]


encodeRecord : Int -> Encode.Encoder
encodeRecord r =
    let
        ts =
            tags r
    in
    Encode.sequence
        [ encodeString (name r)
        , Encode.unsignedInt8 (List.length ts)
        , Encode.sequence (List.map encodeString ts)
        , Encode.sequence (List.map (\i -> Encode.float32 LE (toFloat (valueCode r i) / 8)) (List.range 0 (dims - 1)))
        ]


snapshot : Int -> Bytes
snapshot n =
    Encode.encode
        (Encode.sequence (Encode.unsignedInt32 BE n :: List.map encodeRecord (List.range 0 (n - 1))))



-- DECODE


string : Decoder String
string =
    Decode.unsignedInt16 BE |> Decode.andThen Decode.string


count : Int -> Decoder a -> Decoder (List a)
count n item =
    Decode.loop ( n, [] )
        (\( left, acc ) ->
            if left <= 0 then
                Decode.succeed (Done (List.reverse acc))

            else
                Decode.map (\x -> Loop ( left - 1, x :: acc )) item
        )


entry : Decoder Entry
entry =
    Decode.map3 Entry
        string
        (Decode.unsignedInt8 |> Decode.andThen (\k -> count k string))
        (Decode.map Array.fromList (count dims (Decode.float32 LE)))


index : Decoder (Dict String Entry)
index =
    Decode.unsignedInt32 BE
        |> Decode.andThen
            (\n ->
                Decode.loop ( n, Dict.empty )
                    (\( left, acc ) ->
                        if left <= 0 then
                            Decode.succeed (Done acc)

                        else
                            Decode.map (\e -> Loop ( left - 1, Dict.insert e.name e acc )) entry
                    )
            )



-- CHECK


type alias Totals =
    { entries : Int
    , valueCodes : Int
    , tagCount : Int
    , nameLength : Int
    }


fromIndex : Dict String Entry -> ( Totals, Float )
fromIndex dict =
    Dict.foldl
        (\_ e ( t, values ) ->
            ( { entries = t.entries + 1
              , valueCodes = t.valueCodes
              , tagCount = t.tagCount + List.length e.tags
              , nameLength = t.nameLength + String.length e.name
              }
            , Array.foldl (+) values e.vector
            )
        )
        ( Totals 0 0 0 0, 0 )
        dict


fromGenerator : Int -> Totals
fromGenerator n =
    List.foldl
        (\r t ->
            { entries = t.entries + 1
            , valueCodes = t.valueCodes + List.sum (List.map (valueCode r) (List.range 0 (dims - 1)))
            , tagCount = t.tagCount + List.length (tags r)
            , nameLength = t.nameLength + String.length (name r)
            }
        )
        (Totals 0 0 0 0)
        (List.range 0 (n - 1))


bench : Int -> Bool
bench n =
    case Decode.decode index (snapshot n) of
        Just dict ->
            let
                ( got, values ) =
                    fromIndex dict

                want =
                    fromGenerator n
            in
            { got | valueCodes = want.valueCodes } == want
                && values == toFloat want.valueCodes / 8
                && Maybe.map .name (Dict.get (name 0) dict) == Just (name 0)
                && Maybe.map .tags (Dict.get (name (n - 1)) dict) == Just (tags (n - 1))

        Nothing ->
            False
