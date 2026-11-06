module HofFoldlLoopifyTest exposing (main)

{-| A capturing lambda literal passed to a tail-recursive higher-order function, both a user-written one and `List.foldl`, gives the right sum when called repeatedly from an outer loop.

`round1` passes `\x acc -> acc + x * c` to `sumWith`, a tail-recursive fold
written in the test, over `List.range 1 10` with `c = 3`, giving 55 * 3 = 165.
`round2` passes `\x acc -> acc + x * d` to `List.foldl` over the same list with
`d = 2`, giving 110. `outer` runs both 200 times and sums the results:
200 * (165 + 110) = 55000.

## eco

Exercises loopification from the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md): a saturated call of a
tail-recursive higher-order function with a capturing lambda literal is
rewritten to a local specialized loop with the lambda beta-inlined, so the
lambda's closure is never allocated. The outer loop adds GC pressure. The
CHECK-MLIR line asserts that a loopified local tail function
(`_tail_mono_inline`) was produced; its own closure shell is removed later by
runtime/src/codegen/Passes/EcoPAPSimplify.cpp, which this front-end MLIR does
not show.

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
