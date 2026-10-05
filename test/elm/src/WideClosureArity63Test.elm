module WideClosureArity63Test exposing (main)

{-| Arity-63 closure extended 1 + 7 + 20 + 20 + 15 through eco_pap_extend, with
Float/Char params on both sides of slots 20, 25 and 52.
-}

-- CHECK: res: [72873]

import Html exposing (text)

big : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Float -> Char -> Int -> Int -> Int -> Float -> Char -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> String -> Int -> Int -> Int -> Int -> Int -> Int -> Bool -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Float -> Char -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Float -> Int
big a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 a27 a28 a29 a30 a31 a32 a33 a34 a35 a36 a37 a38 a39 a40 a41 a42 a43 a44 a45 a46 a47 a48 a49 a50 a51 a52 a53 a54 a55 a56 a57 a58 a59 a60 a61 a62 =
    a0 * 1
    + a1 * 2
    + a2 * 3
    + a3 * 4
    + a4 * 5
    + a5 * 6
    + a6 * 7
    + a7 * 8
    + a8 * 9
    + a9 * 10
    + a10 * 11
    + a11 * 12
    + a12 * 13
    + a13 * 14
    + a14 * 15
    + a15 * 16
    + a16 * 17
    + a17 * 18
    + a18 * 19
    + round (a19 * 10)
    + Char.toCode a20
    + a21 * 22
    + a22 * 23
    + a23 * 24
    + round (a24 * 10)
    + Char.toCode a25
    + a26 * 27
    + a27 * 28
    + a28 * 29
    + a29 * 30
    + a30 * 31
    + a31 * 32
    + a32 * 33
    + String.length a33
    + a34 * 35
    + a35 * 36
    + a36 * 37
    + a37 * 38
    + a38 * 39
    + a39 * 40
    + (if a40 then 40 else 0)
    + a41 * 42
    + a42 * 43
    + a43 * 44
    + a44 * 45
    + a45 * 46
    + a46 * 47
    + a47 * 48
    + a48 * 49
    + a49 * 50
    + a50 * 51
    + round (a51 * 10)
    + Char.toCode a52
    + a53 * 54
    + a54 * 55
    + a55 * 56
    + a56 * 57
    + a57 * 58
    + a58 * 59
    + a59 * 60
    + a60 * 61
    + a61 * 62
    + round (a62 * 10)


step0 h b =
    h (b + 0)

step1 h b =
    h (b + 1) (b + 2) (b + 3) (b + 4) (b + 5) (b + 6) (b + 7)

step2 h b =
    h (b + 8) (b + 9) (b + 10) (b + 11) (b + 12) (b + 13) (b + 14) (b + 15) (b + 16) (b + 17) (b + 18) (toFloat b + 19.5 - 1) (Char.fromCode (b + 116)) (b + 21) (b + 22) (b + 23) (toFloat b + 24.5 - 1) (Char.fromCode (b + 121)) (b + 26) (b + 27)

step3 h b =
    h (b + 28) (b + 29) (b + 30) (b + 31) (b + 32) (String.repeat (b + 33) "a") (b + 34) (b + 35) (b + 36) (b + 37) (b + 38) (b + 39) (modBy 2 (b + 39) == 0) (b + 41) (b + 42) (b + 43) (b + 44) (b + 45) (b + 46) (b + 47)

step4 h b =
    h (b + 48) (b + 49) (b + 50) (toFloat b + 51.5 - 1) (Char.fromCode (b + 96)) (b + 53) (b + 54) (b + 55) (b + 56) (b + 57) (b + 58) (b + 59) (b + 60) (b + 61) (toFloat b + 62.5 - 1)


main =
    let
        base =
            1 + List.length [ () ] - 1

        fs0 =
            [ big ]

        fs1 =
            List.map (\h -> step0 h base) fs0

        fs2 =
            List.map (\h -> step1 h base) fs1

        fs3 =
            List.map (\h -> step2 h base) fs2

        fs4 =
            List.map (\h -> step3 h base) fs3

        fs5 =
            List.map (\h -> step4 h base) fs4

        _ =
            Debug.log "res" (fs5)

    in
    text "done"
