module WideRecord40Test exposing (main)

{-| 40-field mixed record (second ext word boundary not reached; header + 1 ext word).
-}

-- CHECK: f0000: 1000
-- CHECK: f0031: 31.5
-- CHECK: f0032: 'g'
-- CHECK: f0039: False
-- CHECK: pattern: (1000, False)
-- CHECK: update: True
-- CHECK: eq self: True
-- CHECK: eq updated: False
-- CHECK: show: { f0000 = 1000, f0001 = 1.5, f0002 = 'c', f0005 = 1005, f0006 = 6.5, f0007 = 'h', f0010 = 1010, f0011 = 11.5, f0012 = 'm', f0015 = 1015, f0016 = 16.5, f0017 = 'r', f0020 = 1020, f0021 = 21.5, f0022 = 'w', f0025 = 1025, f0026 = 26.5, f0027 = 'b', f0030 = 1030, f0031 = 31.5, f0032 = 'g', f0035 = 1035, f0036 = 36.5, f0037 = 'l', f0003 = "3s", f0004 = True, f0008 = "8s", f0009 = False, f0013 = "13s", f0014 = True, f0018 = "18s", f0019 = False, f0023 = "23s", f0024 = True, f0028 = "28s", f0029 = False, f0033 = "33s", f0034 = True, f0038 = "38s", f0039 = False }

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
    }


make : Int -> R
make base =
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


viaPat : R -> ( Int, Bool )
viaPat { f0000, f0039 } =
    ( f0000, f0039 )


upd : R -> R
upd r =
    { r | f0039 = not r.f0039 }


main =
    let
        base =
            1 + List.length [ () ] - 1

        r =
            make base

        _ =
            Debug.log "f0000" (r.f0000)

        _ =
            Debug.log "f0031" (r.f0031)

        _ =
            Debug.log "f0032" (r.f0032)

        _ =
            Debug.log "f0039" (r.f0039)

        _ =
            Debug.log "pattern" (viaPat r)

        _ =
            Debug.log "update" ((upd r).f0039)

        _ =
            Debug.log "eq self" (r == make base)

        _ =
            Debug.log "eq updated" (r == upd r)

        _ =
            Debug.log "show" (r)

    in
    text "done"
