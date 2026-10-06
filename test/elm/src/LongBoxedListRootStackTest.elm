module LongBoxedListRootStackTest exposing (main)

{-| BUG PIN (plans/staging-honesty-and-production-test-pipeline.md §4, "shadow-root
overflow"): list kernels that rebuild a list of BOXED elements push one GC
shadow-root range per element, so a list longer than the 65,536-slot root stack
overflows it.

`Elm::alloc::listFromUnboxables` (runtime/src/allocator/HeapHelpers.hpp) roots
every boxed element separately before consing the result; `List.sortBy` reaches
it through `listFromPermutation` (this is the backtrace of the
`ECO_MONO_LSS_REPORT=1` self-compile abort, a 142,895-element sort). The
`map`/`filter` accumulators in runtime/src/allocator/ListOps.cpp root each boxed
result the same way. Builds with assertions (`!NDEBUG` or ECO_HEAP_VALIDATE)
abort with "FATAL: GC shadow root stack overflow at depth 65536"; an NDEBUG
build has no check and writes past the stack's slack.

70,000 `String`s (boxed) go through `List.map`, `List.sortBy` and `List.filter`.

-}

-- CHECK: sorted: 70000
-- CHECK: first: "00000"
-- CHECK: last: "69999"
-- CHECK: kept: 35000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


main =
    let
        strings =
            List.map pad (List.range 0 69999)

        sorted =
            List.sortBy identity (List.reverse strings)

        kept =
            List.filter (\s -> modBy 2 (Maybe.withDefault 0 (String.toInt s)) == 0) sorted

        _ =
            Debug.log "sorted" (List.length sorted)

        _ =
            Debug.log "first" (Maybe.withDefault "" (List.head sorted))

        _ =
            Debug.log "last" (Maybe.withDefault "" (List.head (List.reverse sorted)))

        _ =
            Debug.log "kept" (List.length kept)
    in
    text "done"
