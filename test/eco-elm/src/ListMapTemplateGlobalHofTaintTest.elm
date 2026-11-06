module ListMapTemplateGlobalHofTaintTest exposing (main)

{-| Checks that `List.map` applies its callback to the elements from last to
first when the callback hands a logging comparator, wrapped in a sorting
function, to a top-level higher-order function.

elm/core defines `List.map` with `List.foldr`, which, on a list this short,
applies the callback to the last element first. The callback calls
`applyTwice 1 sorter`, and with `k = 1` `applyTwice` applies `sorter` once.
`sorter` sorts with `loggingCompare`, which logs its first argument. The inner
lists are `[1, 1]` and `[2, 2]`, so the number logged names the list being
sorted whichever way the comparator's arguments are ordered: the expected
output is the log for `[2, 2]` immediately followed by the log for `[1, 1]`,
then the unchanged sorted lists.

## eco

Global-HOF variant of the argument-position taint rule of the `List.map`
forward template (plans/list-map-mlir-template.md, item F-4): the tainted
function value (a logging comparator) is routed through an Elm-source
higher-order function instead of a kernel one. The taint check lives in
compiler/src/Compiler/MonoOpt/MapTemplate.elm.

`applyTwice` is constructor-free, so its spec passes
compiler/src/Compiler/MonoOpt/CsePurity.elm and the callee position answers
Clean; it carries enough branch bulk to survive threshold inlining. If it were
inlined the shape would collapse to a direct application, which the existing
higher-order check already catches, and the fixture would pin nothing new.
`modBy` is a kernel reference, not a global spec, so it does not affect the
purity answer. The CHECK lines only pin that the callback order is still
`foldr`'s; acceptance was measured as one more `declinedArgTaint` than the same
compile with a clean comparator.

-}

-- CHECK: cmp: 2
-- CHECK-NEXT: cmp: 1
-- CHECK: sorted: [[1,1],[2,2]]

import Html exposing (text)


loggingCompare : Int -> Int -> Order
loggingCompare a b =
    let
        _ =
            Debug.log "cmp" a
    in
    compare a b


{-| Returns `v` unchanged when `k` is over 1000, `h` applied twice to `v` when
`k` is even, and `h` applied once otherwise.
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
