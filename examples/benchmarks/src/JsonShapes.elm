module JsonShapes exposing (bench)

{-| JSON in the three shapes of nativejson-benchmark's standard corpus, as synthetic look-alikes
generated in the program (a benchmark cannot read files), each scaled by `n`:

  - `canada.json`: GeoJSON-like features, each a list of polygons of `[lon, lat]` float pairs
    (floats in deeply nested arrays);
  - `twitter.json`: statuses with Unicode text, nested user objects, ints, bools and nulls
    (strings and mixed values);
  - `citm_catalog.json`: catalog objects keyed by id, decoded with `Decode.dict` (objects as
    maps).

Each document is encoded with `Json.Encode`, decoded back into Elm records with `Json.Decode`,
and must equal the generated value exactly, at every size (floats survive the text round trip
unchanged on every backend).

-}

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode



-- CANADA


type alias Feature =
    { name : String
    , polygons : List (List ( Float, Float ))
    }


feature : Int -> Feature
feature k =
    let
        point p =
            ( -180 + toFloat (modBy 3600000 (p * 7919 + k * 31)) / 10000, -90 + toFloat (modBy 1800000 (p * 104729 + k)) / 10000 )

        polygon q =
            List.map (\p -> point (q * 1000 + p)) (List.range 0 (20 + modBy 30 (q * 7)))
    in
    Feature ("feature " ++ String.fromInt k) (List.map (\q -> polygon (k * 10 + q)) (List.range 0 (modBy 4 k)))


encodeFeature : Feature -> Encode.Value
encodeFeature f =
    Encode.object
        [ ( "type", Encode.string "Feature" )
        , ( "properties", Encode.object [ ( "name", Encode.string f.name ) ] )
        , ( "geometry"
          , Encode.object
                [ ( "type", Encode.string "Polygon" )
                , ( "coordinates", Encode.list (Encode.list (\( a, b ) -> Encode.list Encode.float [ a, b ])) f.polygons )
                ]
          )
        ]


featureDecoder : Decoder Feature
featureDecoder =
    Decode.map2 Feature
        (Decode.at [ "properties", "name" ] Decode.string)
        (Decode.at [ "geometry", "coordinates" ]
            (Decode.list (Decode.list (Decode.map2 Tuple.pair (Decode.index 0 Decode.float) (Decode.index 1 Decode.float))))
        )



-- TWITTER


type alias User =
    { name : String
    , screenName : String
    , followers : Int
    , verified : Bool
    }


type alias Status =
    { id : Int
    , text : String
    , user : User
    , retweets : Int
    , inReplyTo : Maybe Int
    , hashtags : List String
    }


status : Int -> Status
status k =
    let
        words =
            [ "café", "東京", "naïve", "😀", "über", "Москва", "test", "#elm", "\"quoted\"", "line\nbreak" ]

        word i =
            Maybe.withDefault "" (List.head (List.drop (modBy 10 (i * 7 + k)) words))
    in
    { id = 1000000000000 + k * 7919
    , text = String.join " " (List.map word (List.range 0 (5 + modBy 10 k)))
    , user = User ("user " ++ String.fromInt (modBy 97 k)) ("u" ++ String.fromInt (modBy 97 k)) (k * 31) (modBy 3 k == 0)
    , retweets = modBy 1000 (k * 104729)
    , inReplyTo =
        if modBy 4 k == 0 then
            Nothing

        else
            Just (k - 1)
    , hashtags = List.map (\i -> "tag" ++ String.fromInt i) (List.range 0 (modBy 3 k))
    }


encodeStatus : Status -> Encode.Value
encodeStatus s =
    Encode.object
        [ ( "id", Encode.int s.id )
        , ( "text", Encode.string s.text )
        , ( "user"
          , Encode.object
                [ ( "name", Encode.string s.user.name )
                , ( "screen_name", Encode.string s.user.screenName )
                , ( "followers_count", Encode.int s.user.followers )
                , ( "verified", Encode.bool s.user.verified )
                ]
          )
        , ( "retweet_count", Encode.int s.retweets )
        , ( "in_reply_to_status_id", Maybe.withDefault Encode.null (Maybe.map Encode.int s.inReplyTo) )
        , ( "entities", Encode.object [ ( "hashtags", Encode.list (\t -> Encode.object [ ( "text", Encode.string t ) ]) s.hashtags ) ] )
        ]


statusDecoder : Decoder Status
statusDecoder =
    Decode.map6 Status
        (Decode.field "id" Decode.int)
        (Decode.field "text" Decode.string)
        (Decode.field "user"
            (Decode.map4 User
                (Decode.field "name" Decode.string)
                (Decode.field "screen_name" Decode.string)
                (Decode.field "followers_count" Decode.int)
                (Decode.field "verified" Decode.bool)
            )
        )
        (Decode.field "retweet_count" Decode.int)
        (Decode.field "in_reply_to_status_id" (Decode.nullable Decode.int))
        (Decode.at [ "entities", "hashtags" ] (Decode.list (Decode.field "text" Decode.string)))



-- CITM CATALOG


type alias Event =
    { name : String
    , topics : List Int
    , logo : Maybe String
    }


type alias Catalog =
    { events : Dict String Event
    , areaNames : Dict String String
    }


catalog : Int -> Catalog
catalog n =
    let
        event k =
            Event ("event " ++ String.fromInt k)
                (List.map (\t -> 100000 + modBy 50 (k * t)) (List.range 1 (1 + modBy 5 k)))
                (if modBy 2 k == 0 then
                    Just ("/images/logo" ++ String.fromInt k ++ ".png")

                 else
                    Nothing
                )
    in
    { events = Dict.fromList (List.map (\k -> ( String.fromInt (138586341 + k * 7), event k )) (List.range 0 (n - 1)))
    , areaNames = Dict.fromList (List.map (\k -> ( String.fromInt (205705993 + k), "area " ++ String.fromInt k )) (List.range 0 (n // 10)))
    }


encodeCatalog : Catalog -> Encode.Value
encodeCatalog c =
    Encode.object
        [ ( "events"
          , Encode.dict identity
                (\e ->
                    Encode.object
                        [ ( "name", Encode.string e.name )
                        , ( "topicIds", Encode.list Encode.int e.topics )
                        , ( "logo", Maybe.withDefault Encode.null (Maybe.map Encode.string e.logo) )
                        ]
                )
                c.events
          )
        , ( "areaNames", Encode.dict identity Encode.string c.areaNames )
        ]


catalogDecoder : Decoder Catalog
catalogDecoder =
    Decode.map2 Catalog
        (Decode.field "events"
            (Decode.dict
                (Decode.map3 Event
                    (Decode.field "name" Decode.string)
                    (Decode.field "topicIds" (Decode.list Decode.int))
                    (Decode.field "logo" (Decode.nullable Decode.string))
                )
            )
        )
        (Decode.field "areaNames" (Decode.dict Decode.string))


roundTrip : (a -> Encode.Value) -> Decoder a -> a -> Bool
roundTrip encoder decoder value =
    Decode.decodeString decoder (Encode.encode 0 (encoder value)) == Ok value


bench : Int -> Bool
bench n =
    let
        features =
            List.map feature (List.range 0 (n // 4))

        statuses =
            List.map status (List.range 0 n)
    in
    roundTrip (Encode.list encodeFeature) (Decode.list featureDecoder) features
        && roundTrip (Encode.list encodeStatus) (Decode.list statusDecoder) statuses
        && roundTrip encodeCatalog catalogDecoder (catalog n)
