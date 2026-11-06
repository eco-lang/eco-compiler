module ListMapTemplateCapturedDebugTest exposing (main)

{-| Checks that `List.map` applies its callback to the elements from last to
first when the callback logs through a function value it was given rather than
calling `Debug.log` directly.

elm/core defines `List.map` with `List.foldr`, which, on a list this short,
applies the callback to the last element first. `mapWith` maps `\x -> g x`,
and `main` passes it `Debug.log "g"`, so mapping `[10, 20, 30]` logs 30, 20 and
10 in that order, and the mapped values still sum to 60. A compiler that
applied the callback from first to last would print the same values in the
opposite order.

-}

-- CHECK: g: 30
-- CHECK-NEXT: g: 20
-- CHECK-NEXT: g: 10
-- CHECK: sum: 60

import Html exposing (text)


{-| Maps `\x -> g x` over `xs`. The module never names `Debug` here; any
logging comes from the `g` it is given.
-}
mapWith : (Int -> Int) -> List Int -> List Int
mapWith g xs =
    List.map (\x -> g x) xs


main : Html.Html msg
main =
    let
        logger : Int -> Int
        logger =
            Debug.log "g"

        mapped =
            mapWith logger [ 10, 20, 30 ]

        _ =
            Debug.log "sum" (List.sum mapped)
    in
    text "done"
