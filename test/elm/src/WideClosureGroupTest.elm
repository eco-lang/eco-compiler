module WideClosureGroupTest exposing (main)

{-| B15: three mutually recursive let-bound closures (one papCreateGroup), each
capturing 22 boxed Strings: 66 flat captures, more than one 64-slot root range.
-}

-- CHECK: group: 849

import Html exposing (text)

run : String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> Int -> Int
run s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15 s16 s17 s18 s19 s20 s21 s22 s23 s24 s25 s26 s27 s28 s29 s30 s31 s32 s33 s34 s35 s36 s37 s38 s39 s40 s41 s42 s43 s44 s45 s46 s47 s48 s49 s50 s51 s52 s53 s54 s55 s56 s57 s58 s59 s60 s61 s62 s63 s64 s65 k =
    let
        f0 n =
            if n <= 0 then
                String.length s0 + String.length s1 + String.length s2 + String.length s3 + String.length s4 + String.length s5 + String.length s6 + String.length s7 + String.length s8 + String.length s9 + String.length s10 + String.length s11 + String.length s12 + String.length s13 + String.length s14 + String.length s15 + String.length s16 + String.length s17 + String.length s18 + String.length s19 + String.length s20 + String.length s21

            else
                f1 (n - 1) + 1

        f1 n =
            if n <= 0 then
                String.length s22 + String.length s23 + String.length s24 + String.length s25 + String.length s26 + String.length s27 + String.length s28 + String.length s29 + String.length s30 + String.length s31 + String.length s32 + String.length s33 + String.length s34 + String.length s35 + String.length s36 + String.length s37 + String.length s38 + String.length s39 + String.length s40 + String.length s41 + String.length s42 + String.length s43

            else
                f2 (n - 1) + 10

        f2 n =
            if n <= 0 then
                String.length s44 + String.length s45 + String.length s46 + String.length s47 + String.length s48 + String.length s49 + String.length s50 + String.length s51 + String.length s52 + String.length s53 + String.length s54 + String.length s55 + String.length s56 + String.length s57 + String.length s58 + String.length s59 + String.length s60 + String.length s61 + String.length s62 + String.length s63 + String.length s64 + String.length s65

            else
                f0 (n - 1) + 100
    in
    f0 k


main =
    let
        base =
            1 + List.length [ () ] - 1

        _ =
            Debug.log "group" (run (String.repeat (base + 0) "a") (String.repeat (base + 1) "a") (String.repeat (base + 2) "a") (String.repeat (base + 3) "a") (String.repeat (base + 4) "a") (String.repeat (base + 5) "a") (String.repeat (base + 6) "a") (String.repeat (base + 7) "a") (String.repeat (base + 8) "a") (String.repeat (base + 9) "a") (String.repeat (base + 10) "a") (String.repeat (base + 11) "a") (String.repeat (base + 12) "a") (String.repeat (base + 13) "a") (String.repeat (base + 14) "a") (String.repeat (base + 15) "a") (String.repeat (base + 16) "a") (String.repeat (base + 17) "a") (String.repeat (base + 18) "a") (String.repeat (base + 19) "a") (String.repeat (base + 20) "a") (String.repeat (base + 21) "a") (String.repeat (base + 22) "a") (String.repeat (base + 23) "a") (String.repeat (base + 24) "a") (String.repeat (base + 25) "a") (String.repeat (base + 26) "a") (String.repeat (base + 27) "a") (String.repeat (base + 28) "a") (String.repeat (base + 29) "a") (String.repeat (base + 30) "a") (String.repeat (base + 31) "a") (String.repeat (base + 32) "a") (String.repeat (base + 33) "a") (String.repeat (base + 34) "a") (String.repeat (base + 35) "a") (String.repeat (base + 36) "a") (String.repeat (base + 37) "a") (String.repeat (base + 38) "a") (String.repeat (base + 39) "a") (String.repeat (base + 40) "a") (String.repeat (base + 41) "a") (String.repeat (base + 42) "a") (String.repeat (base + 43) "a") (String.repeat (base + 44) "a") (String.repeat (base + 45) "a") (String.repeat (base + 46) "a") (String.repeat (base + 47) "a") (String.repeat (base + 48) "a") (String.repeat (base + 49) "a") (String.repeat (base + 50) "a") (String.repeat (base + 51) "a") (String.repeat (base + 52) "a") (String.repeat (base + 53) "a") (String.repeat (base + 54) "a") (String.repeat (base + 55) "a") (String.repeat (base + 56) "a") (String.repeat (base + 57) "a") (String.repeat (base + 58) "a") (String.repeat (base + 59) "a") (String.repeat (base + 60) "a") (String.repeat (base + 61) "a") (String.repeat (base + 62) "a") (String.repeat (base + 63) "a") (String.repeat (base + 64) "a") (String.repeat (base + 65) "a") 4)

    in
    text "done"
