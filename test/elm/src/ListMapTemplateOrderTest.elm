module ListMapTemplateOrderTest exposing (main)

{-| Pins the UNLICENSED fallback of the `List.map` forward template
(plans/list-map-mlir-template.md; policy `D-4a`).

A callback that references `Debug.*` can never be licensed, so this map keeps
today's elm/core foldr lowering — which applies the callback **right to left**
(`foldrHelper`'s `fn a (fn b (fn c (fn d res)))` evaluates the innermost call
first). The emitted order must therefore be `e, d, c, b, a` with the template
flag ON and OFF alike: that identity IS the fallback guarantee, and it is the
pinnable half of D-4a.

The `Debug.log` sits INSIDE the mapped callback on purpose — that is the
position the licence walk inspects. `DebugLogOrderingTest.elm` pins D-3 over a
wildcard statement chain; this file pins per-element application order under a
combinator, which is a different rule.

-}

-- CHECK: m: "e"
-- CHECK-NEXT: m: "d"
-- CHECK-NEXT: m: "c"
-- CHECK-NEXT: m: "b"
-- CHECK-NEXT: m: "a"
-- CHECK: len: 5

import Html exposing (text)


{-| A logging callback: never licensable, so the lowering must stay foldr's.
-}
logged : List String -> List String
logged xs =
    List.map (\x -> Debug.log "m" x) xs


main : Html.Html msg
main =
    let
        mapped =
            logged [ "a", "b", "c", "d", "e" ]

        _ =
            Debug.log "len" (List.length mapped)
    in
    text "done"
