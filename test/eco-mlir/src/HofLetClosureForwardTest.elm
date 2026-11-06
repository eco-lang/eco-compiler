module HofLetClosureForwardTest exposing (main)

{-| A let-bound lambda capturing two Ints and a Bool, called once from inside an `if` branch, returns the right value.

In `compute 10`, `f` captures `scale = 3`, `offset = 4` and `flag = base > 5`,
which is `True`. The branch `base > 0` is taken and calls `f 10`, giving
3 * 10 + 4 + 1 = 35.

## eco

Exercises let-callee forwarding from the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md), in
compiler/src/Compiler/MonoOpt/InlineSimplify.elm: a let-bound lambda whose
single use is the callee of a saturated call is beta-reduced into the call
site, so no closure is allocated (the CHECK-MLIR-NOT lines). The captures
include a Bool, which must stay boxed in closures (FORBID_CLOSURE_001 in
design_docs/invariants.csv). The call sits under an `if` branch to check that
forwarding descends into branches, which run at most once.

-}

-- CHECK: result: 35
-- CHECK-MLIR-NOT: eco.papCreate
-- CHECK-MLIR-NOT: eco.papExtend


import Html exposing (text)


compute : Int -> Int
compute base =
    let
        scale =
            3

        offset =
            4

        flag =
            base > 5

        f =
            \x ->
                if flag then
                    scale * x + offset + 1

                else
                    scale * x + offset

        result =
            if base > 0 then
                f base

            else
                0
    in
    result


main =
    let
        _ =
            Debug.log "result" (compute 10)
    in
    text "done"
