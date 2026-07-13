module HofSinkGuardTest exposing (main)

{-| HOF-elimination H1.1 sinking guard
(plans/hof-elimination-closure-alloc-reduction.md): a let-bound lambda whose
single use sits INSIDE another lambda must NOT be forwarded. The enclosing
closure's capture list was computed before forwarding; injecting the inner
lambda's free variables (`c`) into its body would violate CGEN_CLOSURE_003.
The guard keeps the let, so `helper`'s closure allocation must still be
present in the MLIR — this test pins the guard by asserting papCreate
SURVIVES (and, of course, that the output is correct).

Behavioral: List.map applies (helper x) = x + 9 over [1,2,3] → 10+11+12 = 33.

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
