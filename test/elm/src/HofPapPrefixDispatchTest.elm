module HofPapPrefixDispatchTest exposing (main)

{-| E2 PAP-prefix fast dispatch (LSS_011, plans/lss-dispatch-value-extraction.md §6).

A capture-carrying lambda literal flows into a recursion-protected HOF
(never inlined; H5 loopification disqualified because the param is
under-applied, not single-saturated-call). Inside, `f 10` creates a PAP of
the lambda holding k=1 applied arg, and the TWO uses of `g` block both
let-callee forwarding and application merging (H2.5 only collapses
single-use partials) — so the `g acc` / `g 1` sites genuinely apply a
PAP-typed callee at runtime.

Flag-on status (verified 2026-07-16, solver+LSS): the `g` apply sites are
NOT stamped today — their peeled arrow types carry `LTop` because the v1
analysis grounds members only on HEAD arrows (the inner-arrow transport
gap, plan E0.5); and the one site that IS consulted (`f 10`, the
PAP-CREATING partial whose static return is an arrow) is correctly
DECLINED by the E2 suffix scan's return-layout fence — stamping it would
be a miscompile. When inner-arrow set transport lands (E4a/E5-class
work), the `g` sites become the activation pin for `stampedPapPrefix=2`.
Until then this test pins (a) default-pipeline correctness of the shape
(LSS_005 — output identical with or without LSS), and (b) that the shape
survives forwarding/merging/loopification so the PAP dispatch is real.
The E2 lowering itself is pinned end-to-end by
test/codegen/fast_dispatch_pap_prefix.mlir.

-}

-- CHECK: result: 22564

import Html exposing (text)


applyPartial : (Int -> Int -> Int) -> Int -> Int -> Int
applyPartial f n acc =
    if n <= 0 then
        acc

    else
        let
            g =
                f 10
        in
        applyPartial f (n - 1) (g acc + g 1)


main =
    let
        step =
            7

        _ =
            Debug.log "result" (applyPartial (\a b -> a * 100 + b * 10 + step) 2 3)
    in
    text "done"
