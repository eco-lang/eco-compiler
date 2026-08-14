module ListMapTemplateNestedTest exposing (main)

{-| Scratch-stack nesting and downstream-consumer coverage for the `List.map`
forward template (plans/list-map-mlir-template.md).

**Nesting is the sharp edge.** The template brackets each map with
`eco_scratch_mark` / `eco_scratch_finish_fwd`, and a licensed map INSIDE a
licensed map's callback nests those brackets. HEAP_040's discipline says that
balances by construction — the inner finish pops to its own mark before the
outer loop's next push — but only if the outer push really does happen after
the inner finish. A `List.map` whose callback itself maps exercises exactly
that, at two and three levels deep.

The callback may also allocate and GC freely between pushes (the scratch stack
is GC-visible; boxed entries are external-scanner roots evacuated in place), so
the callbacks here allocate strings, tuples and lists on purpose.

Also pins the **downstream-consumer** shapes: a mapped result fed into
`sortBy` / `take` / `foldl`, where the chunk spine the template builds meets
code that walks it. A result built as a `ConsChunk` run rather than per-element
`Cons` cells must be indistinguishable to every consumer.

**No emission directive here, deliberately.** The plan asked one E2E fixture to
pin emission with an MLIR-shape check. The harness cannot express that: it
scans a fixture's directives once and runs one flag state per battery, so a
directive asserting the op's PRESENCE fails the flag-off battery and one
asserting its ABSENCE fails the flag-on battery. (Writing the directive inside
prose does not help — the scanner finds it there too, which is how this note
came to be written.) Emission is pinned where it can be: `test/codegen/`
`list_map_template_{expand,kinds,statepoint_free}.mlir` pin the op's shape and
expansion directly, and the `[map-template]` licence stats reconcile
`licensed + declined* == recognized` per the plan's Gate 3. This file pins
BEHAVIOUR, which must be identical in both flag states.

-}

-- CHECK: nested2: [[1, 2], [2, 4], [3, 6]]
-- CHECK: nested3: 18
-- CHECK: allocating: ["a-1", "b-2", "c-3"]
-- CHECK: sorted: [1, 2, 3, 5, 9]
-- CHECK: taken: [2, 4, 6]
-- CHECK: folded: 55
-- CHECK: chained: 24
-- CHECK: tuples: [(1, "1"), (2, "2")]

import Html exposing (text)


{-| Two levels: the outer callback runs a whole inner map.
-}
nested2 : List (List Int)
nested2 =
    List.map (\n -> List.map (\k -> n * k) [ 1, 2 ]) [ 1, 2, 3 ]


{-| Three levels, summed so the check is a single number.
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


{-| Callbacks that ALLOCATE between pushes — strings here, which the scratch
stack must survive as GC roots.
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

        -- Downstream consumers of a chunk-built spine.
        _ =
            Debug.log "sorted" (List.sort (List.map (\x -> x) [ 5, 1, 9, 2, 3 ]))

        _ =
            Debug.log "taken" (List.take 3 (List.map (\x -> x * 2) [ 1, 2, 3, 4, 5 ]))

        _ =
            Debug.log "folded" (List.foldl (+) 0 (List.map (\x -> x) (List.range 1 10)))

        -- map of a map: the outer input IS a template-built spine.
        _ =
            Debug.log "chained"
                (List.sum (List.map (\x -> x + 1) (List.map (\x -> x * 2) [ 1, 2, 3, 4 ])))

        _ =
            Debug.log "tuples"
                (List.map (\x -> ( x, String.fromInt x )) [ 1, 2 ])
    in
    text "done"
