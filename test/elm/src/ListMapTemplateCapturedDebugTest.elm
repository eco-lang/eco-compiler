module ListMapTemplateCapturedDebugTest exposing (main)

{-| The higher-order-poison canary for the `List.map` template licence
(plans/list-map-mlir-template.md Phase 1.2; policy `D-4a`).

`Debug.log` reaches the callback through a **captured function value**, not
through a direct reference. The `CsePurity` oracle alone would license this:
its `scanBody` collects only `MonoVarGlobal` callees and treats a `MonoCall`
through a `MonoVarLocal` as inert, so the captured `g` contributes no poison
at all and the callback looks Debug-free.

`MapTemplate`'s third component — the higher-order poison arm — must decline
it. If that arm regresses, the map gets licensed, the template applies the
callback left-to-right, and these lines come out in the WRONG ORDER. This
fixture fails loudly in exactly that case, which is the whole point: an
order-only regression is otherwise invisible.

Expected order is foldr's right-to-left, same as
`ListMapTemplateOrderTest.elm`.

-}

-- CHECK: g: 30
-- CHECK-NEXT: g: 20
-- CHECK-NEXT: g: 10
-- CHECK: sum: 60

import Html exposing (text)


{-| Debug flows in as a VALUE. `mapWith` never mentions `Debug` itself.
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
