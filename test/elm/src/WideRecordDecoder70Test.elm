module WideRecordDecoder70Test exposing (main)

{-| E9: a 70-field mixed record built with andMap: papCreate arity 70 (> 63) and
field_count 70 (> 32).
-}

-- CHECK: f0000: Just 1000
-- CHECK: f0019: Just False
-- CHECK: f0020: Just 1020
-- CHECK: f0024: Just True
-- CHECK: f0025: Just 1025
-- CHECK: f0031: Just 31.5
-- CHECK: f0032: Just 'g'
-- CHECK: f0033: Just "33s"
-- CHECK: f0062: Just 'k'
-- CHECK: f0063: Just "63s"
-- CHECK: f0064: Just True
-- CHECK: f0069: Just False

import Html exposing (text)

type alias R =
    { f0000 : Int
    , f0001 : Float
    , f0002 : Char
    , f0003 : String
    , f0004 : Bool
    , f0005 : Int
    , f0006 : Float
    , f0007 : Char
    , f0008 : String
    , f0009 : Bool
    , f0010 : Int
    , f0011 : Float
    , f0012 : Char
    , f0013 : String
    , f0014 : Bool
    , f0015 : Int
    , f0016 : Float
    , f0017 : Char
    , f0018 : String
    , f0019 : Bool
    , f0020 : Int
    , f0021 : Float
    , f0022 : Char
    , f0023 : String
    , f0024 : Bool
    , f0025 : Int
    , f0026 : Float
    , f0027 : Char
    , f0028 : String
    , f0029 : Bool
    , f0030 : Int
    , f0031 : Float
    , f0032 : Char
    , f0033 : String
    , f0034 : Bool
    , f0035 : Int
    , f0036 : Float
    , f0037 : Char
    , f0038 : String
    , f0039 : Bool
    , f0040 : Int
    , f0041 : Float
    , f0042 : Char
    , f0043 : String
    , f0044 : Bool
    , f0045 : Int
    , f0046 : Float
    , f0047 : Char
    , f0048 : String
    , f0049 : Bool
    , f0050 : Int
    , f0051 : Float
    , f0052 : Char
    , f0053 : String
    , f0054 : Bool
    , f0055 : Int
    , f0056 : Float
    , f0057 : Char
    , f0058 : String
    , f0059 : Bool
    , f0060 : Int
    , f0061 : Float
    , f0062 : Char
    , f0063 : String
    , f0064 : Bool
    , f0065 : Int
    , f0066 : Float
    , f0067 : Char
    , f0068 : String
    , f0069 : Bool
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
        |> andMap (Just (toFloat b + 1.5 - 1))
        |> andMap (Just (Char.fromCode (b + 98)))
        |> andMap (Just (String.fromInt (b + 2) ++ "s"))
        |> andMap (Just (modBy 2 (b + 3) == 0))
        |> andMap (Just (b + 1004))
        |> andMap (Just (toFloat b + 6.5 - 1))
        |> andMap (Just (Char.fromCode (b + 103)))
        |> andMap (Just (String.fromInt (b + 7) ++ "s"))
        |> andMap (Just (modBy 2 (b + 8) == 0))
        |> andMap (Just (b + 1009))
        |> andMap (Just (toFloat b + 11.5 - 1))
        |> andMap (Just (Char.fromCode (b + 108)))
        |> andMap (Just (String.fromInt (b + 12) ++ "s"))
        |> andMap (Just (modBy 2 (b + 13) == 0))
        |> andMap (Just (b + 1014))
        |> andMap (Just (toFloat b + 16.5 - 1))
        |> andMap (Just (Char.fromCode (b + 113)))
        |> andMap (Just (String.fromInt (b + 17) ++ "s"))
        |> andMap (Just (modBy 2 (b + 18) == 0))
        |> andMap (Just (b + 1019))
        |> andMap (Just (toFloat b + 21.5 - 1))
        |> andMap (Just (Char.fromCode (b + 118)))
        |> andMap (Just (String.fromInt (b + 22) ++ "s"))
        |> andMap (Just (modBy 2 (b + 23) == 0))
        |> andMap (Just (b + 1024))
        |> andMap (Just (toFloat b + 26.5 - 1))
        |> andMap (Just (Char.fromCode (b + 97)))
        |> andMap (Just (String.fromInt (b + 27) ++ "s"))
        |> andMap (Just (modBy 2 (b + 28) == 0))
        |> andMap (Just (b + 1029))
        |> andMap (Just (toFloat b + 31.5 - 1))
        |> andMap (Just (Char.fromCode (b + 102)))
        |> andMap (Just (String.fromInt (b + 32) ++ "s"))
        |> andMap (Just (modBy 2 (b + 33) == 0))
        |> andMap (Just (b + 1034))
        |> andMap (Just (toFloat b + 36.5 - 1))
        |> andMap (Just (Char.fromCode (b + 107)))
        |> andMap (Just (String.fromInt (b + 37) ++ "s"))
        |> andMap (Just (modBy 2 (b + 38) == 0))
        |> andMap (Just (b + 1039))
        |> andMap (Just (toFloat b + 41.5 - 1))
        |> andMap (Just (Char.fromCode (b + 112)))
        |> andMap (Just (String.fromInt (b + 42) ++ "s"))
        |> andMap (Just (modBy 2 (b + 43) == 0))
        |> andMap (Just (b + 1044))
        |> andMap (Just (toFloat b + 46.5 - 1))
        |> andMap (Just (Char.fromCode (b + 117)))
        |> andMap (Just (String.fromInt (b + 47) ++ "s"))
        |> andMap (Just (modBy 2 (b + 48) == 0))
        |> andMap (Just (b + 1049))
        |> andMap (Just (toFloat b + 51.5 - 1))
        |> andMap (Just (Char.fromCode (b + 96)))
        |> andMap (Just (String.fromInt (b + 52) ++ "s"))
        |> andMap (Just (modBy 2 (b + 53) == 0))
        |> andMap (Just (b + 1054))
        |> andMap (Just (toFloat b + 56.5 - 1))
        |> andMap (Just (Char.fromCode (b + 101)))
        |> andMap (Just (String.fromInt (b + 57) ++ "s"))
        |> andMap (Just (modBy 2 (b + 58) == 0))
        |> andMap (Just (b + 1059))
        |> andMap (Just (toFloat b + 61.5 - 1))
        |> andMap (Just (Char.fromCode (b + 106)))
        |> andMap (Just (String.fromInt (b + 62) ++ "s"))
        |> andMap (Just (modBy 2 (b + 63) == 0))
        |> andMap (Just (b + 1064))
        |> andMap (Just (toFloat b + 66.5 - 1))
        |> andMap (Just (Char.fromCode (b + 111)))
        |> andMap (Just (String.fromInt (b + 67) ++ "s"))
        |> andMap (Just (modBy 2 (b + 68) == 0))


main =
    let
        base =
            1 + List.length [ () ] - 1

        r =
            build base

        _ =
            Debug.log "f0000" (Maybe.map .f0000 r)

        _ =
            Debug.log "f0019" (Maybe.map .f0019 r)

        _ =
            Debug.log "f0020" (Maybe.map .f0020 r)

        _ =
            Debug.log "f0024" (Maybe.map .f0024 r)

        _ =
            Debug.log "f0025" (Maybe.map .f0025 r)

        _ =
            Debug.log "f0031" (Maybe.map .f0031 r)

        _ =
            Debug.log "f0032" (Maybe.map .f0032 r)

        _ =
            Debug.log "f0033" (Maybe.map .f0033 r)

        _ =
            Debug.log "f0062" (Maybe.map .f0062 r)

        _ =
            Debug.log "f0063" (Maybe.map .f0063 r)

        _ =
            Debug.log "f0064" (Maybe.map .f0064 r)

        _ =
            Debug.log "f0069" (Maybe.map .f0069 r)

    in
    text "done"
