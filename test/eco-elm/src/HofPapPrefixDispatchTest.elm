module HofPapPrefixDispatchTest exposing (main)

{-| A partial application of a capturing lambda, made inside a recursive higher-order function and then called twice, returns the right values on every iteration.

`main` passes `\a b -> a * 100 + b * 10 + step` (with `step = 7`) to
`applyPartial`. Each round binds `g = f 10`, a function still waiting for `b`,
and uses it twice, as `g acc` and `g 1`. Starting from `n = 2` and `acc = 3`:
the first round gives 1037 + 1017 = 2054, and the second gives
21547 + 1017 = 22564.

## eco

Exercises PAP-prefix fast dispatch (LSS_011 in design_docs/invariants.csv;
the dispatch-value extraction work, plans/lss-dispatch-value-extraction.md).
The capturing lambda flows into a self-recursive higher-order function, which
is never inlined and is not loopified because `f` is under-applied. Inside,
`f 10` creates a PAP holding one argument, and the two uses of `g` block both
let-callee forwarding and application merging, so `g acc` and `g 1` really
apply a PAP-typed callee at runtime.

With the solver and LSS enabled, spine injection (LSS_013) puts the lambda's
member on its inner arrow and it is carried through `f 10`'s result to the `g`
use sites, which lower to fast calls that load the PAP's filled slot; the
answer must match the unstamped build. `f 10` itself, whose static return is
an arrow, is correctly declined. Without the flag this pins default-pipeline
correctness of the shape (LSS_005). The stamp is unit-tested in
compiler/tests/Compiler/Monomorphize/Solver/SpinePapDispatchTest.elm and the
lowering in test/codegen/fast_dispatch_pap_prefix.mlir.

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
