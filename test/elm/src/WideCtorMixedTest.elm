module WideCtorMixedTest exposing (main)

{-| 60-field mixed constructor: case match on fields 23/24/55/59, ==, Debug.toString.
-}

-- CHECK: field23: "23s"
-- CHECK: field24: True
-- CHECK: field55: 1055
-- CHECK: field59: False
-- CHECK: eq self: True
-- CHECK: eq other: False
-- CHECK: show: W 1000 1.5 'c' "3s" True 1005 6.5 'h' "8s" False 1010 11.5 'm' "13s" True 1015 16.5 'r' "18s" False 1020 21.5 'w' "23s" True 1025 26.5 'b' "28s" False 1030 31.5 'g' "33s" True 1035 36.5 'l' "38s" False 1040 41.5 'q' "43s" True 1045 46.5 'v' "48s" False 1050 51.5 'a' "53s" True 1055 56.5 'f' "58s" False

import Html exposing (text)

type W
    = W Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool Int Float Char String Bool


make : Int -> W
make base =
    W (base + 999) (toFloat base + 1.5 - 1) (Char.fromCode (base + 98)) (String.fromInt (base + 2) ++ "s") (modBy 2 (base + 3) == 0) (base + 1004) (toFloat base + 6.5 - 1) (Char.fromCode (base + 103)) (String.fromInt (base + 7) ++ "s") (modBy 2 (base + 8) == 0) (base + 1009) (toFloat base + 11.5 - 1) (Char.fromCode (base + 108)) (String.fromInt (base + 12) ++ "s") (modBy 2 (base + 13) == 0) (base + 1014) (toFloat base + 16.5 - 1) (Char.fromCode (base + 113)) (String.fromInt (base + 17) ++ "s") (modBy 2 (base + 18) == 0) (base + 1019) (toFloat base + 21.5 - 1) (Char.fromCode (base + 118)) (String.fromInt (base + 22) ++ "s") (modBy 2 (base + 23) == 0) (base + 1024) (toFloat base + 26.5 - 1) (Char.fromCode (base + 97)) (String.fromInt (base + 27) ++ "s") (modBy 2 (base + 28) == 0) (base + 1029) (toFloat base + 31.5 - 1) (Char.fromCode (base + 102)) (String.fromInt (base + 32) ++ "s") (modBy 2 (base + 33) == 0) (base + 1034) (toFloat base + 36.5 - 1) (Char.fromCode (base + 107)) (String.fromInt (base + 37) ++ "s") (modBy 2 (base + 38) == 0) (base + 1039) (toFloat base + 41.5 - 1) (Char.fromCode (base + 112)) (String.fromInt (base + 42) ++ "s") (modBy 2 (base + 43) == 0) (base + 1044) (toFloat base + 46.5 - 1) (Char.fromCode (base + 117)) (String.fromInt (base + 47) ++ "s") (modBy 2 (base + 48) == 0) (base + 1049) (toFloat base + 51.5 - 1) (Char.fromCode (base + 96)) (String.fromInt (base + 52) ++ "s") (modBy 2 (base + 53) == 0) (base + 1054) (toFloat base + 56.5 - 1) (Char.fromCode (base + 101)) (String.fromInt (base + 57) ++ "s") (modBy 2 (base + 58) == 0)


get23 : W -> String
get23 w =
    case w of
        W x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 x31 x32 x33 x34 x35 x36 x37 x38 x39 x40 x41 x42 x43 x44 x45 x46 x47 x48 x49 x50 x51 x52 x53 x54 x55 x56 x57 x58 x59 ->
            x23


get24 : W -> Bool
get24 w =
    case w of
        W x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 x31 x32 x33 x34 x35 x36 x37 x38 x39 x40 x41 x42 x43 x44 x45 x46 x47 x48 x49 x50 x51 x52 x53 x54 x55 x56 x57 x58 x59 ->
            x24


get55 : W -> Int
get55 w =
    case w of
        W x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 x31 x32 x33 x34 x35 x36 x37 x38 x39 x40 x41 x42 x43 x44 x45 x46 x47 x48 x49 x50 x51 x52 x53 x54 x55 x56 x57 x58 x59 ->
            x55


get59 : W -> Bool
get59 w =
    case w of
        W x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 x18 x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30 x31 x32 x33 x34 x35 x36 x37 x38 x39 x40 x41 x42 x43 x44 x45 x46 x47 x48 x49 x50 x51 x52 x53 x54 x55 x56 x57 x58 x59 ->
            x59


main =
    let
        base =
            1 + List.length [ () ] - 1

        w =
            make base

        _ =
            Debug.log "field23" (get23 w)

        _ =
            Debug.log "field24" (get24 w)

        _ =
            Debug.log "field55" (get55 w)

        _ =
            Debug.log "field59" (get59 w)

        _ =
            Debug.log "eq self" (w == make base)

        _ =
            Debug.log "eq other" (w == make (base + 1))

        _ =
            Debug.log "show" (w)

    in
    text "done"
