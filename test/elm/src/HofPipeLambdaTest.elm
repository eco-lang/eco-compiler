module HofPipeLambdaTest exposing (main)

{-| HOF-elimination H1 (plans/hof-elimination-closure-alloc-reduction.md):
`|>` pipelines with lambda literals. Each `apR` call inlines (its body cost
is under the default threshold), which let-binds the lambda argument; the
H1.1 let-callee forwarding rule then beta-reduces the lambda into the call
site. The whole chain must compile to straight-line arithmetic with no
closure allocations at all.

Behavioral: ((7 + 3) * 2 - 5) = 15, then 15 * 15 = 225.

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
