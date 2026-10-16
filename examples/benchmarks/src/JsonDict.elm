module JsonDict exposing (bench)

{-| JSON objects as maps: an object of `n` generated keys, each holding a small record, decoded
three ways, with `Decode.dict` into a `Dict String`, with `Decode.keyValuePairs` into a list, and
with `Decode.dict` of just one field. Building string-keyed dicts from objects field by field.

Checked at every size against the generator: every decoded dict and list has `n` entries, and
the sums of the decoded numbers equal those taken straight from the generated values.

-}

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias Entry =
    { count : Int
    , label : String
    , weight : Float
    }


entry : Int -> ( String, Entry )
entry k =
    ( "key" ++ String.fromInt (k * 7919)
    , Entry (modBy 10007 (k * 31)) ("label " ++ String.fromInt k) (toFloat (modBy 1000 k) / 8)
    )


document : Int -> String
document n =
    Encode.encode 0
        (Encode.object
            (List.map
                (\k ->
                    let
                        ( key, e ) =
                            entry k
                    in
                    ( key, Encode.object [ ( "count", Encode.int e.count ), ( "label", Encode.string e.label ), ( "weight", Encode.float e.weight ) ] )
                )
                (List.range 1 n)
            )
        )


entryDecoder : Decoder Entry
entryDecoder =
    Decode.map3 Entry (Decode.field "count" Decode.int) (Decode.field "label" Decode.string) (Decode.field "weight" Decode.float)


bench : Int -> Bool
bench n =
    let
        text =
            document n

        entries =
            List.map (entry >> Tuple.second) (List.range 1 n)

        countSum =
            List.sum (List.map .count entries)

        -- the weights are multiples of 1/8, so every partial sum is exact in any order
        weightSum =
            List.sum (List.map .weight entries)

        asDict =
            Decode.decodeString (Decode.dict entryDecoder) text

        asPairs =
            Decode.decodeString (Decode.keyValuePairs entryDecoder) text

        counts =
            Decode.decodeString (Decode.dict (Decode.field "count" Decode.int)) text
    in
    (Result.map (\d -> ( Dict.size d, Dict.foldl (\_ e s -> s + e.count) 0 d, Dict.foldl (\_ e s -> s + e.weight) 0 d )) asDict == Ok ( n, countSum, weightSum ))
        && (Result.map (\ps -> ( List.length ps, List.sum (List.map (Tuple.second >> .count) ps) )) asPairs == Ok ( n, countSum ))
        && (Result.map (\d -> ( Dict.size d, Dict.foldl (\_ c s -> s + c) 0 d )) counts == Ok ( n, countSum ))
