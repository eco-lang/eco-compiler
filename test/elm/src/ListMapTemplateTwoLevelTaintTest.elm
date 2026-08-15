module ListMapTemplateTwoLevelTaintTest exposing (main)

{-| The TWO-LEVEL canary for the `List.map` template licence
(`plans/list-map-mlir-template.md`, F-3/F-4 joint-architecture section).

Shape: `\x -> hof sorter x` where `hof h v = h v` is ctor-free (so
`CsePurity` puts its spec IN `safeSpecs` — it treats the local callee `h`
as inert) and `sorter` launders `Debug` through a kernel HOF's argument
position.

The callee is a clean global; the poison rides in through `sorter`, an
ARGUMENT. This pins that the member table's ARG-EDGES propagate: asking the
table about `sorter` must return the poison its body earned, not `Clean`.

Same `[1, 1]` / `[2, 2]` construction as the other taint canaries. Expected
order is foldr's right-to-left.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1, 1], [2, 2]]

import Html exposing (text)


loggingCompare : Int -> Int -> Order
loggingCompare a b =
    let
        _ =
            Debug.log "cmp" a
    in
    compare a b


{-| Ctor-free and `Debug`-free by inspection: `CsePurity` admits this spec.
-}
hof : (List Int -> List Int) -> List Int -> List Int
hof h v =
    h v


main : Html.Html msg
main =
    let
        cmp : Int -> Int -> Order
        cmp =
            loggingCompare

        sorter : List Int -> List Int
        sorter =
            \ys -> List.sortWith cmp ys

        sorted =
            List.map (\x -> hof sorter x) [ [ 1, 1 ], [ 2, 2 ] ]

        _ =
            Debug.log "sorted" sorted
    in
    text "done"
