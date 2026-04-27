module GetCommentsRepro exposing (main)

-- CHECK: GetCommentsRepro: True
{-| Reduced reproducer for the Stage-7 `Allocator::resolve` "Pointer above
heap end" crash that fires inside `Compiler.Parse.Module.getComments_$_16433`.
See:

  - /work/bootstrap-stage7-crash-analysis.md   (the original trace)
  - /work/bootstrap-stage7-getcomments-shape-analysis.md
                                              (the shape hypothesis)


# Bisection result

The original `getComments` shape (`Decl` Custom + `Maybe Comment` + nested
`Located`) is NOT actually required to trigger the bug. Bisecting from the
full mirror of `getComments` down to the smallest crash:

  - Removing the `Decl` Custom: still crashes.
  - Removing the `Maybe Comment` payload: still crashes.
  - Removing the source-text `String` field: still crashes.
  - Reducing to a 5-Int record: still crashes.
  - Bypassing `StressHarness.loopWhile`: still crashes.
  - Hard-coding the size to 5000 (ignoring `flags.maxSize`): **PASSES**.
  - Reading `flags.maxSize` and using it as the size: crashes at size ≥ 3000.

The trigger is therefore:

    a runtime-derived `Int` (here: a record-field load `flags.maxSize`)
    feeding the size of a heap-allocated tail-recursive list whose elements
    are records whose data ages past at least one minor GC boundary.

The bug fires at `RuntimeExports.cpp:1353` in `eco_closure_call_saturated`
with the assertion:

    closure->n_values + num_newargs == max_values
        "eco_closure_call_saturated: argument count mismatch"

— which is exactly the **closure-arity / saturation mismatch** flagged as
hypothesis §5.3 in `bootstrap-stage7-getcomments-shape-analysis.md`. In a
release build (assertions stripped) the same path would silently pack the
wrong number of args into the evaluator argument array, leaving stack-resident
HPointer slots either uninitialised or holding stale heap bytes. A subsequent
`eco_resolve_hptr` on one of those slots would then trip the
`Pointer above heap end` assert in `Allocator::resolve` — exactly what
production Stage 7 hits.

Same `eco_apply_segmentation_unknown` / `eco_closure_call_saturated` frames
appear on both backtraces.


# How to reproduce

The default `--max-size 100` is below the crash threshold, so the test
PASSES under the default `stress-test` invocation (does not break the
existing 98-test suite). To see the crash:

    /work/build/test/stress-test --filter GetCommentsRepro -n 1 -m 3000

— SIGABRT with the assertion above. PASSES at `-m 2000` and below.


# Once a fix lands

With the closure-arity bug fixed, this test should pass at any `-m`. The
inner cycle is a simple round-trip on a list of records, so the verdict
is meaningful (either the build / walk machinery works at scale or it
doesn't).
-}

import StressHarness exposing (StressFlags)
import Task


type alias R =
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    }


mkRs : Int -> List R -> List R
mkRs i acc =
    if i <= 0 then
        acc

    else
        mkRs (i - 1) ({ a = i, b = i, c = i, d = i, e = i } :: acc)


sumA : List R -> Int -> Int
sumA rs acc =
    case rs of
        [] ->
            acc

        r :: rest ->
            sumA rest (acc + r.a)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        -- Read flags.maxSize (record-field load on the StressFlags record)
        -- and use it as the list length. The record-field-derived length
        -- is the trigger that distinguishes this from a hard-coded
        -- variant that PASSES.
        size : Int
        size =
            flags.maxSize

        rs : List R
        rs =
            mkRs size []

        expected : Int
        expected =
            (size * (size + 1)) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (sumA rs 0 == expected))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "GetCommentsRepro"
        , run = run
        }
