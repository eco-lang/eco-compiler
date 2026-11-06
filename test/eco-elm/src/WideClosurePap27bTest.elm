module WideClosurePap27bTest exposing (main)

{-| A 28-parameter function can be partially applied to 20 arguments, then to 7
more inside a mapped function, then to the last one, and gives the right sum.

`big` returns `a0 * 1 + a1 * 2 + ... + a27 * 28`. `h` supplies the first 20
arguments, `step7 h b` the next 7 (from `b + 20`), and the final call the last
(5). With `b` of 100 and 200 the results are `[23702,40502]`.

## eco

Part of the wide-object work (plans/wide-object-tail-kind-words-phase-1.md,
plans/wide-object-tail-kind-words-phase-2.md): closures past 20 slots keep
their slot kinds in tail kind words (HEAP_019 in design_docs/invariants.csv)
and papCreate/papExtend carry `slot_kinds` (CGEN_003).

An arity-28 closure is extended 20 + 7 + 1 through `eco_pap_extend`
(runtime/src/allocator/RuntimeExports.cpp). Before Phase 2 the parameter
kinds at slots 25 and 26 were truncated to boxed, so the typed consumer read
HPointers instead of numbers.

-}

-- CHECK: res: [23702,40502]

import Html exposing (text)

big : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
big a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 a27 =
    a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20 + a20 * 21 + a21 * 22 + a22 * 23 + a23 * 24 + a24 * 25 + a25 * 26 + a26 * 27 + a27 * 28


step7 : (Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int) -> Int -> (Int -> Int)
step7 h b =
    h (b + 20) (b + 21) (b + 22) (b + 23) (b + 24) (b + 25) (b + 26)


main =
    let
        base =
            1 + List.length [ () ] - 1

        h =
            big (base + 0) (base + 1) (base + 2) (base + 3) (base + 4) (base + 5) (base + 6) (base + 7) (base + 8) (base + 9) (base + 10) (base + 11) (base + 12) (base + 13) (base + 14) (base + 15) (base + 16) (base + 17) (base + 18) (base + 19)

        gs =
            List.map (step7 h) [ 100, 200 ]

        _ =
            Debug.log "res" (List.map (\g -> g 5) gs)

    in
    text "done"
