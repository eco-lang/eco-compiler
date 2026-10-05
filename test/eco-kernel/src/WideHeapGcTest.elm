module WideHeapGcTest exposing (main)

{-| 200 40-field records and 200 60-field constructors (mixed kinds) live across a
minor and a major GC. Green at P3D.
-}

-- CHECK: WideHeapGcTest minor: 1
-- CHECK: WideHeapGcTest major: 1
-- CHECK: WideHeapGcTest value: 842495

import Eco.GC as GC
import Platform
import Task


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
    }


type W
    = W Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool


mkR : Int -> R
mkR base =
    { f0000 = (base + 999)
        , f0001 = (toFloat base + 1.5 - 1)
        , f0002 = (Char.fromCode (base + 98))
        , f0003 = (String.fromInt (base + 2) ++ "s")
        , f0004 = (modBy 2 (base + 3) == 0)
        , f0005 = (base + 1004)
        , f0006 = (toFloat base + 6.5 - 1)
        , f0007 = (Char.fromCode (base + 103))
        , f0008 = (String.fromInt (base + 7) ++ "s")
        , f0009 = (modBy 2 (base + 8) == 0)
        , f0010 = (base + 1009)
        , f0011 = (toFloat base + 11.5 - 1)
        , f0012 = (Char.fromCode (base + 108))
        , f0013 = (String.fromInt (base + 12) ++ "s")
        , f0014 = (modBy 2 (base + 13) == 0)
        , f0015 = (base + 1014)
        , f0016 = (toFloat base + 16.5 - 1)
        , f0017 = (Char.fromCode (base + 113))
        , f0018 = (String.fromInt (base + 17) ++ "s")
        , f0019 = (modBy 2 (base + 18) == 0)
        , f0020 = (base + 1019)
        , f0021 = (toFloat base + 21.5 - 1)
        , f0022 = (Char.fromCode (base + 118))
        , f0023 = (String.fromInt (base + 22) ++ "s")
        , f0024 = (modBy 2 (base + 23) == 0)
        , f0025 = (base + 1024)
        , f0026 = (toFloat base + 26.5 - 1)
        , f0027 = (Char.fromCode (base + 97))
        , f0028 = (String.fromInt (base + 27) ++ "s")
        , f0029 = (modBy 2 (base + 28) == 0)
        , f0030 = (base + 1029)
        , f0031 = (toFloat base + 31.5 - 1)
        , f0032 = (Char.fromCode (base + 102))
        , f0033 = (String.fromInt (base + 32) ++ "s")
        , f0034 = (modBy 2 (base + 33) == 0)
        , f0035 = (base + 1034)
        , f0036 = (toFloat base + 36.5 - 1)
        , f0037 = (Char.fromCode (base + 107))
        , f0038 = (String.fromInt (base + 37) ++ "s")
        , f0039 = (modBy 2 (base + 38) == 0)
    }


mkW : Int -> W
mkW base =
    W (base + 999) (toFloat base + 1.5 - 1) (Char.fromCode (base + 98)) (String.fromInt (base + 2) ++ "s") (modBy 2 (base + 3) == 0) (base + 1004) (toFloat base + 6.5 - 1) (Char.fromCode (base + 103)) (String.fromInt (base + 7) ++ "s") (modBy 2 (base + 8) == 0) (base + 1009) (toFloat base + 11.5 - 1) (Char.fromCode (base + 108)) (String.fromInt (base + 12) ++ "s") (modBy 2 (base + 13) == 0) (base + 1014) (toFloat base + 16.5 - 1) (Char.fromCode (base + 113)) (String.fromInt (base + 17) ++ "s") (modBy 2 (base + 18) == 0) (base + 1019) (toFloat base + 21.5 - 1) (Char.fromCode (base + 118)) (String.fromInt (base + 22) ++ "s") (modBy 2 (base + 23) == 0) (base + 1024) (toFloat base + 26.5 - 1) (Char.fromCode (base + 97)) (String.fromInt (base + 27) ++ "s") (modBy 2 (base + 28) == 0) (base + 1029) (toFloat base + 31.5 - 1) (Char.fromCode (base + 102)) (String.fromInt (base + 32) ++ "s") (modBy 2 (base + 33) == 0) (base + 1034) (toFloat base + 36.5 - 1) (Char.fromCode (base + 107)) (String.fromInt (base + 37) ++ "s") (modBy 2 (base + 38) == 0) (base + 1039) (toFloat base + 41.5 - 1) (Char.fromCode (base + 112)) (String.fromInt (base + 42) ++ "s") (modBy 2 (base + 43) == 0) (base + 1044) (toFloat base + 46.5 - 1) (Char.fromCode (base + 117)) (String.fromInt (base + 47) ++ "s") (modBy 2 (base + 48) == 0) (base + 1049) (toFloat base + 51.5 - 1) (Char.fromCode (base + 96)) (String.fromInt (base + 52) ++ "s") (modBy 2 (base + 53) == 0) (base + 1054) (toFloat base + 56.5 - 1) (Char.fromCode (base + 101)) (String.fromInt (base + 57) ++ "s") (modBy 2 (base + 58) == 0)


readR : R -> Int
readR r =
    r.f0000
        + round (r.f0031 * 2)
        + Char.toCode r.f0032
        + String.length r.f0033
        + String.length r.f0038
        + (if r.f0039 then 1 else 0)


readW : W -> Int
readW w =
    case w of
        W x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 x31 x32 x33 x34 x35 x36 x37 x38 x39 x40 x41 x42 x43 x44 x45 x46 x47 x48 x49 x50 x51 x52 x53 x54 x55 x56 x57 x58 x59 ->
            x0
                + String.length x23
                + (if x24 then 1 else 0)
                + x25
                + round (x56 * 2)
                + (if x59 then 1 else 0)


type Msg
    = Done Int Int Int


churn : Int -> Int
churn k =
    List.range 1 (20000 + k) |> List.map String.fromInt |> List.length


init : () -> ( (), Cmd Msg )
init _ =
    let
        base =
            1 + List.length [ () ] - 1

        objs =
            List.map (\b -> ( mkR b, mkW b )) (List.range base 200)

        task =
            GC.minorGC
                |> Task.andThen (\mi -> GC.majorGC |> Task.map (\ma -> ( mi.collected, ma.collected )))
                |> Task.map (\( mi, ma ) -> Done mi ma (churn mi + List.sum (List.map (\( r, w ) -> readR r + readW w) objs)))
    in
    ( (), Task.perform identity task )


update : Msg -> () -> ( (), Cmd Msg )
update msg _ =
    case msg of
        Done mi ma v ->
            let
                _ =
                    Debug.log "WideHeapGcTest minor" mi

                _ =
                    Debug.log "WideHeapGcTest major" ma

                _ =
                    Debug.log "WideHeapGcTest value" v
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }
