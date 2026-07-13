module HofClosureDCETest exposing (main)

{-| HOF-elimination H1.2 (chain-aware dead closure elimination,
plans/hof-elimination-closure-alloc-reduction.md): a let-bound lambda that
is never used anywhere (no later sibling, no earlier sibling, no final-body
reference) is dropped, so its closure never allocates. Before H1.2 the let
simplifier categorically refused to eliminate closure bindings.

Behavioral: only the used path contributes: 6 * 7 = 42.

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
