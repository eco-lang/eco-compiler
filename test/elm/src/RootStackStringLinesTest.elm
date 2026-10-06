module RootStackStringLinesTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `String.lines` into a long list of lines.

It reaches `listFromPointers` (runtime/src/allocator/HeapHelpers.hpp), which pushes one root
record per boxed element. `String.lines` also roots its parts in 64-element chunks.
-}

-- CHECK: lines: 70000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


main =
    let
        _ =
            Debug.log "lines" (List.length (String.lines (String.join "\n" strs)))

    in
    text "done"
