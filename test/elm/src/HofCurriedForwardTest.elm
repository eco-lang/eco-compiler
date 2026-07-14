module HofCurriedForwardTest exposing (main)

{-| H2.5 step 2 (plans/hof-elimination-closure-alloc-reduction.md): a
let-bound CURRIED lambda whose single use is a saturated callee-position
application of its first stage. Pre-step-2 the ground-result guard refused
this (function-typed result); with the faithful residual type the forward,
hoisting, and beta cascade collapse the whole thing to arithmetic.

Behavioral: makeAdder 5 10 with c=2 -> 10 + 5 + 2 = 17.

-}

-- CHECK: result: 17
-- CHECK-MLIR-NOT: eco.papCreate


import Html exposing (text)


compute : Int -> Int
compute c =
    let
        makeAdder =
            \bonus -> \x -> x + bonus + c
    in
    (makeAdder 5) 10


main =
    let
        _ =
            Debug.log "result" (compute 2)
    in
    text "done"
