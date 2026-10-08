module HtmlLargeTreeTest exposing (main)

{-| GC pressure on the VirtualDom constructors: a 200k-node wide tree and a
10k-deep nesting through `Html.div` / `Html.map` / `Html.Keyed`.
-}

-- CHECK: wide: 200000
-- CHECK: deep: 10000

import Html exposing (Html)
import Html.Attributes as A
import Html.Keyed as Keyed


wide : Int -> Html msg
wide n =
    Html.div [ A.class "wide" ]
        (List.map
            (\i ->
                if modBy 3 i == 0 then
                    Html.span [ A.id (String.fromInt i), A.style "color" "red" ] [ Html.text (String.fromInt i) ]

                else if modBy 3 i == 1 then
                    Keyed.ul [] [ ( String.fromInt i, Html.li [] [ Html.text "k" ] ) ]

                else
                    Html.map identity (Html.text "m")
            )
            (List.range 1 n)
        )


deep : Int -> Html msg -> Html msg
deep n inner =
    if n <= 0 then
        inner

    else
        deep (n - 1) (Html.map identity (Html.div [ A.title "d" ] [ inner ]))


main =
    let
        w =
            wide 200000

        _ =
            Debug.log "wide" (always 200000 w)

        d =
            deep 10000 (Html.text "leaf")

        _ =
            Debug.log "deep" (always 10000 d)
    in
    Html.div [] [ w, d ]
