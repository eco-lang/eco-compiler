module ListMapTemplateGlobalHofTaintTest exposing (main)

{-| The GLOBAL-HOF taint variant for F-4
(`plans/list-map-mlir-template.md` F-4, "A global-HOF variant").

The callback routes the tainted function value through an Elm-source
higher-order function instead of a kernel one. `applyTwice` is ctor-free
(so `CsePurity` admits its spec — the callee position answers Clean) and
carries enough branch bulk to survive threshold inlining; if it were
inlined the shape would collapse to direct application, which the
PRE-EXISTING higher-order arm already catches, and the fixture would pin
nothing new. That inlining hazard is why acceptance for this fixture is
counter attribution (`declinedArgTaint` one higher than the same compile
with a clean comparator), recorded in the F-4 landing note — the CHECK
lines below only pin that the ORDER is still foldr's.

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


{-| Ctor-free by construction — every branch either returns a parameter or
applies one. `modBy` is a kernel reference, not a global spec, so nothing
here drags a bodiless ctor spec into the purity answer.
-}
applyTwice : Int -> (List Int -> List Int) -> List Int -> List Int
applyTwice k h v =
    if k > 1000 then
        v

    else if modBy 2 k == 0 then
        h (h v)

    else if k < 0 then
        h v

    else
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
            List.map (\x -> applyTwice 1 sorter x) [ [ 1, 1 ], [ 2, 2 ] ]

        _ =
            Debug.log "sorted" sorted
    in
    text "done"
