module HofSinkGuardTest exposing (main)

{-| A let-bound lambda whose only use is inside another let-bound lambda keeps its captured value when the outer lambda runs.

`helper = \y -> y + c` captures `c`, and `applyAll` calls it from the lambda
it passes to `List.map`. With `c = 9`, `applyAll [ 1, 2, 3 ]` sums 10, 11 and 12
to 33.

## eco

Exercises the sinking guard of let-callee forwarding from the HOF-elimination
work (plans/hof-elimination-closure-alloc-reduction.md), in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm: a let-bound lambda whose
single use is inside another lambda must not be forwarded, because the outer
closure's capture list was computed already and injecting `c` into its body
would break CGEN_CLOSURE_003 in design_docs/invariants.csv. The guard keeps
the let, so the CHECK-MLIR line asserts `helper`'s `eco.papCreate` survives.

-}

-- CHECK: result: 33
-- CHECK-MLIR: eco.papCreate


import Html exposing (text)


compute : Int -> Int
compute c =
    let
        helper =
            \y -> y + c

        applyAll =
            \xs -> List.sum (List.map (\x -> helper x) xs)
    in
    applyAll [ 1, 2, 3 ]


main =
    let
        _ =
            Debug.log "result" (compute 9)
    in
    text "done"
