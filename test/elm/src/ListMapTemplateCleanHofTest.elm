module ListMapTemplateCleanHofTest exposing (main)

{-| The clean-HOF NON-REGRESSION fixture for F-4's argument-position taint
(`plans/list-map-mlir-template.md` F-4, "the clean-HOF NON-regression
fixture").

The taint rule must not mass-decline every callback that passes a function
value to a HOF. `cleanCompare` is a ctor-free wrapper over kernel `compare`,
so `argProvenance`'s SHAPE-DISPATCH rows answer it directly. Deleting those
rows sends the decision down the annotation route, where LTop (~89% of
zonked arrows on this corpus) makes it False and this fixture stops being
licensed.

The behavioural CHECK is order-INSENSITIVE by construction — nothing here
logs from inside the callback — because a licensed map and a declined map
must produce the same values. The positive pin is the compile-and-grep in
the F-4 landing note (`licensed >= 1` on this compile, `eco.list.map`
present in the artifact), not this output.

-}

-- CHECK: sorted: [[1, 2], [3, 4]]

import Html exposing (text)


{-| Ctor-free wrapper over the kernel comparison: its spec IS in `safeSpecs`.
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
