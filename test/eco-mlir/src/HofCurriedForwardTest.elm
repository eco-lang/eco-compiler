module HofCurriedForwardTest exposing (main)

{-| A let-bound curried lambda, applied first to one argument and the result then to a second, returns the sum of both arguments and a captured value.

`makeAdder` is `\bonus -> \x -> x + bonus + c`, defined inside `compute` so it
captures `c`. It is used once, as `(makeAdder 5) 10`. With `c = 2` the result is
10 + 5 + 2 = 17.

## eco

Exercises let-callee forwarding of a curried lambda from the HOF-elimination
work (plans/hof-elimination-closure-alloc-reduction.md), in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm. The single use is a
saturated application of the first stage whose result is a function; with a
faithful residual type the forwarding, hoisting and beta steps collapse the
whole expression to arithmetic, so the CHECK-MLIR-NOT line asserts no
`eco.papCreate`. An earlier guard refused forwarding when the result type was
a function.

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
