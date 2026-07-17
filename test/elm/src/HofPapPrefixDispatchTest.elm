module HofPapPrefixDispatchTest exposing (main)

{-| E2 PAP-prefix fast dispatch (LSS_011, plans/lss-dispatch-value-extraction.md §6).

A capture-carrying lambda literal flows into a recursion-protected HOF
(never inlined; H5 loopification disqualified because the param is
under-applied, not single-saturated-call). Inside, `f 10` creates a PAP of
the lambda holding k=1 applied arg, and the TWO uses of `g` block both
let-callee forwarding and application merging (H2.5 only collapses
single-use partials) — so the `g acc` / `g 1` sites genuinely apply a
PAP-typed callee at runtime.

Flag-on status (ACTIVE since 2026-07-17, solver+LSS): spine injection
(LSS_013) puts the lambda's member on its inner arrow, the indirect-call
transport carries it through `f 10`'s result, and E4a
(`Translate.enrichLocalMultiUses`, plan §9.1) overlays it onto the `g`
use sites — so `g acc` / `g 1` are StampPap'd (`fastPapPrefix = Just 1`)
and lower to BARE fast calls loading the PAP's filled slot. The flag-on
corpus run of this test is therefore the live RUNTIME pin for the whole
chain (the CHECK below must print the same answer as the un-stamped
build). `f 10` (the PAP-CREATING partial whose static return is an
arrow) remains correctly DECLINED by the E2 suffix scan's return-layout
fence. Flag-off this still pins default-pipeline correctness of the
shape (LSS_005). The unit-level stamp pin is
compiler/tests/TestLogic/Generate/CodeGen/SpinePapDispatchTest.elm; the
lowering is pinned by test/codegen/fast_dispatch_pap_prefix.mlir.

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
