module HofFoldlLoopifyTest exposing (main)

{-| H5 loopification (plans/hof-elimination-closure-alloc-reduction.md): a
saturated call of a tail-recursive HOF with a capturing lambda LITERAL is
rewritten to a local specialized loop with the lambda beta-inlined — the
lambda's closure is never allocated. Covers both a user-written tail
recursive HOF and the real `List.foldl`, under an outer accumulation loop
for GC pressure. The `_tail_mono_inline` CHECK-MLIR pins that a loopified
local tail function was actually minted (fresh inliner name compiled to a
`_tail_*` loop function); the loop's own closure shell is elided
downstream by EcoPAPSimplify P1 (not visible in this front-end dump).

Behavioral: sumWith (\x acc -> acc + x * c) over [1..10] with c=3 gives
55*3 = 165; List.foldl (\x acc -> acc + x * d) with d=2 gives 110.
Outer loop: 200 rounds of (165 + 110) = 55000.

-}

-- CHECK: result: 55000
-- CHECK-MLIR: _tail_mono_inline


import Html exposing (text)


sumWith : (Int -> Int -> Int) -> Int -> List Int -> Int
sumWith f acc xs =
    case xs of
        [] ->
            acc

        x :: rest ->
            sumWith f (f x acc) rest


round1 : Int -> Int
round1 c =
    sumWith (\x acc -> acc + x * c) 0 (List.range 1 10)


round2 : Int -> Int
round2 d =
    List.foldl (\x acc -> acc + x * d) 0 (List.range 1 10)


outer : Int -> Int -> Int
outer n acc =
    if n <= 0 then
        acc

    else
        outer (n - 1) (acc + round1 3 + round2 2)


main =
    let
        _ =
            Debug.log "result" (outer 200 0)
    in
    text "done"
