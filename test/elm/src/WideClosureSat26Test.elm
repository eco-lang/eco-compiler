module WideClosureSat26Test exposing (main)

{-| E5: 26 typed newargs at once to an arity-27 function (eta-flattened mk).
-}

-- CHECK: res: [6208, 6215]

import Html exposing (text)

mk : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> (Int -> Int)
mk a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 =
    \x -> x * 7 + a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20 + a20 * 21 + a21 * 22 + a22 * 23 + a23 * 24 + a24 * 25 + a25 * 26


main =
    let
        base =
            1 + List.length [ () ] - 1

        f =
            mk (base + 0) (base + 1) (base + 2) (base + 3) (base + 4) (base + 5) (base + 6) (base + 7) (base + 8) (base + 9) (base + 10) (base + 11) (base + 12) (base + 13) (base + 14) (base + 15) (base + 16) (base + 17) (base + 18) (base + 19) (base + 20) (base + 21) (base + 22) (base + 23) (base + 24) (base + 25)

        _ =
            Debug.log "res" (List.map f [ 1, 2 ])

    in
    text "done"
