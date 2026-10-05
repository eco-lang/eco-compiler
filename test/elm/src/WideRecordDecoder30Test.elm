module WideRecordDecoder30Test exposing (main)

{-| E8, mixed kinds at declaration positions >= 25 (30 fields).
-}

-- CHECK: f0000: Just 1000
-- CHECK: f0024: Just 1024
-- CHECK: f0025: Just 25.5
-- CHECK: f0026: Just 'a'
-- CHECK: f0027: Just 1027
-- CHECK: f0028: Just "28s"
-- CHECK: f0029: Just 1029

import Html exposing (text)

type alias R =
    { f0000 : Int
    , f0001 : Int
    , f0002 : Int
    , f0003 : Int
    , f0004 : Int
    , f0005 : Int
    , f0006 : Int
    , f0007 : Int
    , f0008 : Int
    , f0009 : Int
    , f0010 : Int
    , f0011 : Int
    , f0012 : Int
    , f0013 : Int
    , f0014 : Int
    , f0015 : Int
    , f0016 : Int
    , f0017 : Int
    , f0018 : Int
    , f0019 : Int
    , f0020 : Int
    , f0021 : Int
    , f0022 : Int
    , f0023 : Int
    , f0024 : Int
    , f0025 : Float
    , f0026 : Char
    , f0027 : Int
    , f0028 : String
    , f0029 : Int
    }


andMap : Maybe a -> Maybe (a -> b) -> Maybe b
andMap ma mf =
    case ( mf, ma ) of
        ( Just f, Just a ) ->
            Just (f a)

        _ ->
            Nothing


build : Int -> Maybe R
build b =
    Just R
        |> andMap (Just (b + 999))
        |> andMap (Just (b + 1000))
        |> andMap (Just (b + 1001))
        |> andMap (Just (b + 1002))
        |> andMap (Just (b + 1003))
        |> andMap (Just (b + 1004))
        |> andMap (Just (b + 1005))
        |> andMap (Just (b + 1006))
        |> andMap (Just (b + 1007))
        |> andMap (Just (b + 1008))
        |> andMap (Just (b + 1009))
        |> andMap (Just (b + 1010))
        |> andMap (Just (b + 1011))
        |> andMap (Just (b + 1012))
        |> andMap (Just (b + 1013))
        |> andMap (Just (b + 1014))
        |> andMap (Just (b + 1015))
        |> andMap (Just (b + 1016))
        |> andMap (Just (b + 1017))
        |> andMap (Just (b + 1018))
        |> andMap (Just (b + 1019))
        |> andMap (Just (b + 1020))
        |> andMap (Just (b + 1021))
        |> andMap (Just (b + 1022))
        |> andMap (Just (b + 1023))
        |> andMap (Just (toFloat b + 25.5 - 1))
        |> andMap (Just (Char.fromCode (b + 96)))
        |> andMap (Just (b + 1026))
        |> andMap (Just (String.fromInt (b + 27) ++ "s"))
        |> andMap (Just (b + 1028))


main =
    let
        base =
            1 + List.length [ () ] - 1

        r =
            build base

        _ =
            Debug.log "f0000" (Maybe.map .f0000 r)

        _ =
            Debug.log "f0024" (Maybe.map .f0024 r)

        _ =
            Debug.log "f0025" (Maybe.map .f0025 r)

        _ =
            Debug.log "f0026" (Maybe.map .f0026 r)

        _ =
            Debug.log "f0027" (Maybe.map .f0027 r)

        _ =
            Debug.log "f0028" (Maybe.map .f0028 r)

        _ =
            Debug.log "f0029" (Maybe.map .f0029 r)

    in
    text "done"
