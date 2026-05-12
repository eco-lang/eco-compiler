module SortByAlwaysEmptyStringKeyTest exposing (main)

{-| `List.sortBy (always "")` — every key extracted is the embedded
constant `""`. The F3 bug: `Allocator::resolve(keys[i])` in the
comparator asserts on `constant != 0`. Expected to FAIL (assert)
or crash today.

`always` is forced through a non-inlinable helper to defeat any
intrinsic shortcut that might fold `sortBy (always _)` to `identity`.
-}

-- CHECK: result: [3, 1, 2]

import Html exposing (text)


emptyKey : Int -> String
emptyKey _ =
    ""


main =
    let
        result : List Int
        result = List.sortBy emptyKey [ 3, 1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"
