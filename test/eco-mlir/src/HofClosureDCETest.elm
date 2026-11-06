module HofClosureDCETest exposing (main)

{-| A let-bound lambda that is never used does not affect the result of the function it is defined in.

In `compute`, `deadHelper` refers to the argument `n` but is never called or
referred to; the result is `n * factor`, so `compute 6` is 42.

## eco

Exercises chain-aware dead closure elimination from the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md), in the let simplifier in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm: a let-bound lambda with no
use anywhere is dropped, so its closure is never allocated. The CHECK-MLIR-NOT
lines assert no `eco.papCreate` or `eco.papExtend` remains. Before this the
simplifier never eliminated closure bindings.

-}

-- CHECK: result: 42
-- CHECK-MLIR-NOT: eco.papCreate
-- CHECK-MLIR-NOT: eco.papExtend


import Html exposing (text)


compute : Int -> Int
compute n =
    let
        deadHelper =
            \x -> x * n + 100

        factor =
            7
    in
    n * factor


main =
    let
        _ =
            Debug.log "result" (compute 6)
    in
    text "done"
