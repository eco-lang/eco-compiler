module HofResidualPartialTest exposing (main)

{-| H2.5 step 2 (plans/hof-elimination-closure-alloc-reduction.md): a
literal partial application whose RESIDUAL closure survives to runtime
(multi-use through a HOF parameter, so no forwarding or merging applies).
This exercises betaReduce's partial-rebuild path end-to-end: the residual's
type must be the PEELED arrow, not the historical double-wrapped one —
result-kind/arity metadata from the double wrap is what tripped CGEN_056
and the runtime typed-apply arity assert.

Behavioral: partial = \a b -> a*100 + b + c with a=7, c=3;
applyBoth g = g 1 + g 2 -> (700+1+3) + (700+2+3) = 1409.

-}

-- CHECK: result: 1409


import Html exposing (text)


applyBoth : (Int -> Int) -> Int
applyBoth g =
    g 1 + g 2


compute : Int -> Int
compute c =
    let
        partial =
            (\a b -> a * 100 + b + c) 7
    in
    applyBoth partial


main =
    let
        _ =
            Debug.log "result" (compute 3)
    in
    text "done"
