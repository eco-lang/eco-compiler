module ListMapTemplateNestedTest exposing (main)

{-| Checks `List.map` calls nested inside other `List.map` callbacks, and mapped
lists consumed by other list functions.

  - `nested2` maps over `[1, 2, 3]` with a callback that maps over `[1, 2]`.
  - `nested3` nests three maps and sums at each level, giving 18.
  - `allocating` builds strings with `List.map2`.
  - `sorted`, `taken` and `folded` pass a mapped list to `List.sort`,
    `List.take` and `List.foldl`.
  - `chained` maps over the result of another map and sums it, giving 24.
  - `tuples` maps each integer to a tuple of the integer and its string.

## eco

Covers scratch-stack nesting for the `List.map` forward template
(plans/list-map-mlir-template.md). The template brackets each map with
`eco_scratch_mark` / `eco_scratch_finish_fwd`
(runtime/src/allocator/RuntimeExports.cpp), and a licensed map inside a
licensed map's callback nests those brackets. HEAP_040 in
design_docs/invariants.csv says they balance by construction, since the inner
finish pops to its own mark before the outer loop's next push; the nested maps
here exercise that at two and three levels.

The callbacks allocate strings, tuples and lists on purpose: the scratch stack
is GC-visible and its boxed entries are roots evacuated in place, so it must
survive collections between pushes. The `sort`, `take`, `foldl` and
map-of-map cases check that a result built as `ConsChunk` runs is
indistinguishable from per-element `Cons` cells to every consumer.

There is deliberately no MLIR directive: the E2E harness runs one flag state per
battery, so asserting the op's presence or absence would fail one of them.
Emission is pinned by test/codegen/list_map_template_expand.mlir,
test/codegen/list_map_template_kinds.mlir and
test/codegen/list_map_template_statepoint_free.mlir; this file pins behaviour,
which must be identical with the template on or off.

-}

-- CHECK: nested2: [[1,2],[2,4],[3,6]]
-- CHECK: nested3: 18
-- CHECK: allocating: ["a-1","b-2","c-3"]
-- CHECK: sorted: [1,2,3,5,9]
-- CHECK: taken: [2,4,6]
-- CHECK: folded: 55
-- CHECK: chained: 24
-- CHECK: tuples: [(1,"1"),(2,"2")]

import Html exposing (text)


{-| Maps over `[1, 2, 3]` with a callback that itself maps over `[1, 2]`.
-}
nested2 : List (List Int)
nested2 =
    List.map (\n -> List.map (\k -> n * k) [ 1, 2 ]) [ 1, 2, 3 ]


{-| Sums `a * b * c` over three nested maps, summing at each level so the
result is a single number.
-}
nested3 : Int
nested3 =
    List.map
        (\a ->
            List.map
                (\b -> List.map (\c -> a * b * c) [ 1 ] |> List.sum)
                [ 1, 2 ]
                |> List.sum
        )
        [ 1, 2, 3 ]
        |> List.sum


{-| Joins each letter with its number using `List.map2`.
-}
allocating : List String
allocating =
    List.map2 (\s n -> s ++ "-" ++ String.fromInt n)
        [ "a", "b", "c" ]
        [ 1, 2, 3 ]


main : Html.Html msg
main =
    let
        _ =
            Debug.log "nested2" nested2

        _ =
            Debug.log "nested3" nested3

        _ =
            Debug.log "allocating" allocating

        _ =
            Debug.log "sorted" (List.sort (List.map (\x -> x) [ 5, 1, 9, 2, 3 ]))

        _ =
            Debug.log "taken" (List.take 3 (List.map (\x -> x * 2) [ 1, 2, 3, 4, 5 ]))

        _ =
            Debug.log "folded" (List.foldl (+) 0 (List.map (\x -> x) (List.range 1 10)))

        _ =
            Debug.log "chained"
                (List.sum (List.map (\x -> x + 1) (List.map (\x -> x * 2) [ 1, 2, 3, 4 ])))

        _ =
            Debug.log "tuples"
                (List.map (\x -> ( x, String.fromInt x )) [ 1, 2 ])
    in
    text "done"
