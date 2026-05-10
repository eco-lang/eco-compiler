module ArrayBuilderStress exposing (main)

-- CHECK: ArrayBuilderStress: True
--
-- Regression for HEAP_BUILDER_001/002/003: exercises Array.indexedMap and
-- Array.initialize with mapping closures that allocate heavily on every
-- invocation. The mapping closures force the runtime to enter
-- Elm_Kernel_JsArray_indexedMap_Int / Elm_Kernel_JsArray_initialize_Int
-- and the per-call allocations make minor GC fire multiple times mid-loop.
-- Without the builder bit, the half-built result array would be promoted
-- to old gen and subsequent slot writes would plant nursery HPointers in
-- an old-gen parent — caught by the phase-3 promotion invariant assertion
-- under ECO_HEAP_VALIDATE.

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


-- Allocate a small list per call to give the nursery something to chew on.
heavyMap : Int -> Int -> Int
heavyMap idx value =
    let
        scratch =
            List.range 0 7

        sumScratch =
            List.foldl (+) 0 scratch
    in
    idx + value + sumScratch


-- Build an array by initialize with a heavy-allocating closure: every slot
-- write happens after a closure call that itself allocates. Without the
-- builder bit, the kernel's result array can promote between iterations
-- and the next slot write produces an old-gen → young pointer.
buildViaInitialize : Int -> Array Int
buildViaInitialize size =
    Array.initialize size (\i -> heavyMap i (i + 1))


-- Same shape but via indexedMap: forces Elm_Kernel_JsArray_indexedMap_Int.
mapWithIndex : Array Int -> Array Int
mapWithIndex arr =
    Array.indexedMap heavyMap arr


-- Round-trip: building via initialize then mapping via indexedMap exercises
-- both kernels in sequence on the same data.
cycle : Int -> Bool
cycle size =
    let
        viaInit =
            buildViaInitialize size

        mapped =
            mapWithIndex viaInit

        -- viaInit[i] = heavyMap i (i+1) = i + (i+1) + 28 = 2i + 29
        -- mapped[i]  = heavyMap i (viaInit[i]) = i + (2i + 29) + 28 = 3i + 57
        expectedLast =
            3 * (size - 1) + 57

        actualLast =
            Maybe.withDefault 0 (Array.get (size - 1) mapped)
    in
    Array.length viaInit == size && Array.length mapped == size && actualLast == expectedLast


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        size =
            flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle size))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayBuilderStress"
        , run = run
        }
