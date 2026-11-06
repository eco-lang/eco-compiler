module WideClosureCapture27Test exposing (main)

{-| An anonymous function passed to `List.map` can refer to all 27 arguments of
the function that defines it, whether they are `String`s or `Int`s.

  - `mkS` adds the lengths of 27 strings of 1 to 27 characters (378) to
    `x * 1000`, giving `[1378,2378]` for `[ 1, 2 ]`.
  - `mkI` adds `a0 * 1 + a1 * 2 + ... + a26 * 27` for arguments 1 to 27 (6930)
    to `x * 1000`, giving `[7930,8930]`.

## eco

Part of the wide-object work (plans/wide-object-tail-kind-words-phase-1.md,
plans/wide-object-tail-kind-words-phase-2.md): closures past 20 slots keep
their slot kinds in tail kind words (HEAP_019 in design_docs/invariants.csv)
and papCreate/papExtend carry `slot_kinds` (CGEN_003).

A lambda capturing 27 parameters (boxed and typed variants) is passed to
`List.map`, so `eco.papCreate` is emitted with 27 captures, above the
header's 20 inline slot kinds.

-}

-- CHECK: strings: [1378,2378]
-- CHECK: ints: [7930,8930]

import Html exposing (text)

mkS : String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> List Int -> List Int
mkS a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 xs =
    List.map (\x -> x * 1000 + String.length a0 + String.length a1 + String.length a2 + String.length a3 + String.length a4 + String.length a5 + String.length a6 + String.length a7 + String.length a8 + String.length a9 + String.length a10 + String.length a11 + String.length a12 + String.length a13 + String.length a14 + String.length a15 + String.length a16 + String.length a17 + String.length a18 + String.length a19 + String.length a20 + String.length a21 + String.length a22 + String.length a23 + String.length a24 + String.length a25 + String.length a26) xs


mkI : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> List Int -> List Int
mkI a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 xs =
    List.map (\x -> x * 1000 + a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20 + a20 * 21 + a21 * 22 + a22 * 23 + a23 * 24 + a24 * 25 + a25 * 26 + a26 * 27) xs


main =
    let
        base =
            1 + List.length [ () ] - 1

        _ =
            Debug.log "strings" (mkS (String.repeat (base + 0) "a") (String.repeat (base + 1) "a") (String.repeat (base + 2) "a") (String.repeat (base + 3) "a") (String.repeat (base + 4) "a") (String.repeat (base + 5) "a") (String.repeat (base + 6) "a") (String.repeat (base + 7) "a") (String.repeat (base + 8) "a") (String.repeat (base + 9) "a") (String.repeat (base + 10) "a") (String.repeat (base + 11) "a") (String.repeat (base + 12) "a") (String.repeat (base + 13) "a") (String.repeat (base + 14) "a") (String.repeat (base + 15) "a") (String.repeat (base + 16) "a") (String.repeat (base + 17) "a") (String.repeat (base + 18) "a") (String.repeat (base + 19) "a") (String.repeat (base + 20) "a") (String.repeat (base + 21) "a") (String.repeat (base + 22) "a") (String.repeat (base + 23) "a") (String.repeat (base + 24) "a") (String.repeat (base + 25) "a") (String.repeat (base + 26) "a") [ 1, 2 ])

        _ =
            Debug.log "ints" (mkI (base + 0) (base + 1) (base + 2) (base + 3) (base + 4) (base + 5) (base + 6) (base + 7) (base + 8) (base + 9) (base + 10) (base + 11) (base + 12) (base + 13) (base + 14) (base + 15) (base + 16) (base + 17) (base + 18) (base + 19) (base + 20) (base + 21) (base + 22) (base + 23) (base + 24) (base + 25) (base + 26) [ 1, 2 ])

    in
    text "done"
