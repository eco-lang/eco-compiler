module HofLetClosureForwardTest exposing (main)

{-| HOF-elimination H1.1 (let-callee forwarding,
plans/hof-elimination-closure-alloc-reduction.md): a let-bound lambda whose
single use is the callee of a saturated call is beta-reduced into the call
site, so no closure is ever allocated for it. The lambda captures an Int, a
Float-derived Int, and a Bool (Bool must stay boxed per FORBID_CLOSURE_001 —
capture-representation coverage). The call sits under an `if` branch to pin
that forwarding descends into branches (they execute at most once).

Behavioral: 3*10 + 4 + 1 = 35 when flag is True.

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
