module WideClosureBoxed27Test exposing (main)

{-| A function given 27 `String` arguments at once returns a working one-argument
function that still sees all 27 strings.

`mk` returns `\x -> x * 7` plus the lengths of its strings. The strings are 1
to 27 characters long, adding 378, so mapping the result over `[ 1, 2 ]` gives
`[385,392]`.

## eco

Part of the wide-object work (plans/wide-object-tail-kind-words-phase-1.md,
plans/wide-object-tail-kind-words-phase-2.md): closures past 20 slots keep
their slot kinds in tail kind words (HEAP_019 in design_docs/invariants.csv)
and papCreate/papExtend carry `slot_kinds` (CGEN_003).

Passes 27 boxed (`String`) new arguments in one extension. Before Phase 2
this was rejected by the 25-newarg count cap in `eco_pap_extend`
(runtime/src/allocator/RuntimeExports.cpp).

-}

-- CHECK: res: [385,392]

import Html exposing (text)

mk : String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> (Int -> Int)
mk a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 =
    \x -> x * 7 + String.length a0 + String.length a1 + String.length a2 + String.length a3 + String.length a4 + String.length a5 + String.length a6 + String.length a7 + String.length a8 + String.length a9 + String.length a10 + String.length a11 + String.length a12 + String.length a13 + String.length a14 + String.length a15 + String.length a16 + String.length a17 + String.length a18 + String.length a19 + String.length a20 + String.length a21 + String.length a22 + String.length a23 + String.length a24 + String.length a25 + String.length a26


main =
    let
        base =
            1 + List.length [ () ] - 1

        f =
            mk (String.repeat (base + 0) "a") (String.repeat (base + 1) "a") (String.repeat (base + 2) "a") (String.repeat (base + 3) "a") (String.repeat (base + 4) "a") (String.repeat (base + 5) "a") (String.repeat (base + 6) "a") (String.repeat (base + 7) "a") (String.repeat (base + 8) "a") (String.repeat (base + 9) "a") (String.repeat (base + 10) "a") (String.repeat (base + 11) "a") (String.repeat (base + 12) "a") (String.repeat (base + 13) "a") (String.repeat (base + 14) "a") (String.repeat (base + 15) "a") (String.repeat (base + 16) "a") (String.repeat (base + 17) "a") (String.repeat (base + 18) "a") (String.repeat (base + 19) "a") (String.repeat (base + 20) "a") (String.repeat (base + 21) "a") (String.repeat (base + 22) "a") (String.repeat (base + 23) "a") (String.repeat (base + 24) "a") (String.repeat (base + 25) "a") (String.repeat (base + 26) "a")

        _ =
            Debug.log "res" (List.map f [ 1, 2 ])

    in
    text "done"
