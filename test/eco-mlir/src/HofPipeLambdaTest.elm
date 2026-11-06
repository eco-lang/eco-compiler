module HofPipeLambdaTest exposing (main)

{-| A chain of `|>` pipelines through lambda literals computes the same value as the arithmetic written out directly.

`compute 7` pipes 7 through `x + 3`, `x * 2` and `x - 5`, giving 15, and then
pipes that through `x * x`, giving 225.

## eco

Exercises the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md) on `|>`: each `apR` call
is inlined, which let-binds the lambda argument, and let-callee forwarding in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm then beta-reduces the lambda
into the call site. The chain must compile to straight-line arithmetic; the
CHECK-MLIR-NOT line asserts no `eco.papCreate`.

-}

-- CHECK: result: 225
-- CHECK-MLIR-NOT: eco.papCreate


import Html exposing (text)


compute : Int -> Int
compute n =
    let
        base =
            n
                |> (\x -> x + 3)
                |> (\x -> x * 2)
                |> (\x -> x - 5)
    in
    base |> (\x -> x * x)


main =
    let
        _ =
            Debug.log "result" (compute 7)
    in
    text "done"
