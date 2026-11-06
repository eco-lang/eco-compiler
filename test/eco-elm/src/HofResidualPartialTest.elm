module HofResidualPartialTest exposing (main)

{-| A lambda of two arguments, applied inline to its first argument and then passed to a higher-order function that calls the result twice, returns the right values.

`partial` is `(\a b -> a * 100 + b + c) 7` with `c = 3`, a function of `b`.
`applyBoth partial` computes `partial 1 + partial 2` = 704 + 705 = 1409.

## eco

Exercises step H2.5 of the HOF-elimination work (plans/hof-elimination-closure-alloc-reduction.md):
a literal partial application whose residual closure survives to runtime
(it is used twice through a HOF parameter, so neither forwarding nor merging
applies). This drives the partial-rebuild path of `betaReduce` in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm: the residual's type must be
the peeled arrow, not a doubly wrapped one, whose result-kind and arity
metadata once tripped CGEN_056 (design_docs/invariants.csv) and the runtime
typed-apply arity assert.

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
