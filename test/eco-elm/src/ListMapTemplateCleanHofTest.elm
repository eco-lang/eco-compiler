module ListMapTemplateCleanHofTest exposing (main)

{-| Checks `List.map` with a callback that passes a top-level comparison function
to `List.sortWith`, sorting each inner list of `[[2, 1], [4, 3]]`.

Nothing is logged from inside the callback, so the output depends only on the
values: each inner list comes back in ascending order.

## eco

Clean-HOF non-regression fixture for the argument-position taint rule of
the `List.map` forward template (plans/list-map-mlir-template.md, item F-4).
The taint rule must not decline every callback that hands a function value to
a higher-order function: `cleanCompare` is a constructor-free wrapper over
kernel `compare`, so the shape-dispatch rows of `argProvenance` in
compiler/src/Compiler/MonoOpt/MapTemplate.elm answer it directly. Without those
rows the decision falls to the annotation route, where LTop makes it False and
this map would stop being licensed.

The output is order-insensitive on purpose: a licensed map (`eco.list.map`) and
a declined one must give the same values. That the map is actually licensed is
checked by compiling and grepping the template statistics, not by this output.

`cleanCompare`'s spec is in `safeSpecs` of
compiler/src/Compiler/MonoOpt/CsePurity.elm.

-}

-- CHECK: sorted: [[1,2],[3,4]]

import Html exposing (text)


{-| Compares two integers with `compare`.
-}
cleanCompare : Int -> Int -> Order
cleanCompare a b =
    compare a b


main : Html.Html msg
main =
    let
        sorted =
            List.map (\x -> List.sortWith cleanCompare x) [ [ 2, 1 ], [ 4, 3 ] ]

        _ =
            Debug.log "sorted" sorted
    in
    text "done"
