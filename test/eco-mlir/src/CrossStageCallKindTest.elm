module CrossStageCallKindTest exposing (main)

{-| A function whose `case` returns lambdas of different shapes, some taking two
arguments at once and one curried, can be applied to all its arguments in a
single call.

`caseFunc` is defined with one parameter, fewer than its annotated type.
Its `case` on that value returns `\a b -> a + b`, `\a b -> a - b`, or
`\a -> \b -> a * b`, so the remaining two arguments of `caseFunc 0 5 3` are
applied to whichever lambda the `case` selects. With 0 it picks the addition, and
the expected result is 8. The scrutinee is passed through `Debug.log`, so the
program also prints `caseFunc: 0`.

## eco

Exercises cross-stage `eco.papExtend` batches over a `case` join of
differently staged lambdas (two flat `[2]`, one curried `[1,1]`). The second
batch extends a value computed at run time, so it must be fully generic, with
no `remaining_arity`, and tagged `_call_kind = "segmentation_unknown"`
(CGEN_052 and CGEN_060 in design_docs/invariants.csv). That tag makes the
lowering in runtime/src/codegen/Passes/EcoToLLVMClosures.cpp take the typed
argument buffer path without primitive boxing, and lets the CGEN_052 checks
tell it apart from an op that lost its arity claim. The CHECK-MLIR line pins
the tag; it was once dropped for every batch after the first in
`applyByStages` (compiler/src/Compiler/GenerateMlir/Expr.elm).

The scrutinee goes through `Debug.log` because pre-mono eta-expansion
(compiler/src/Compiler/PreMono/EtaExpand.elm,
plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md) would
otherwise push the two missing parameters into the branches and beta away the
staged lambdas, leaving no cross-stage batch to check. A `Debug.log` call is
never cheap, so the definition is left alone.

-}

-- CHECK-MLIR: segmentation_unknown
-- CHECK: result: 8

import Html exposing (text)


caseFunc : Int -> Int -> Int -> Int
caseFunc x0 =
    let
        x =
            Debug.log "caseFunc" x0
    in
    case x of
        0 ->
            \a b -> a + b

        1 ->
            \a b -> a - b

        _ ->
            \a -> \b -> a * b


main =
    let
        _ =
            Debug.log "result" (caseFunc 0 5 3)
    in
    text "done"
