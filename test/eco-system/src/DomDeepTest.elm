module DomDeepTest exposing (main)

{-| A 10k-deep and a 200k-wide tree through both serializers
(plans/elm-html-native-kernel.md P5, D17): neither the C++ writer, the Elm
`render` nor (on JS) the twin's conversion recurses with the tree size.
-}

-- CHECK: deep: 110004 True
-- CHECK-NEXT: wide: 2800011 True
-- EXIT: 0

import Html exposing (Html)
import Http.Dom as Dom
import Stream.Log
import System


deep : Int -> Html msg -> Html msg
deep n inner =
    if n <= 0 then
        inner

    else
        deep (n - 1) (Html.div [] [ inner ])


wide : Int -> Html msg
wide n =
    Html.div [] (List.repeat n (Html.span [] [ Html.text "x" ]))


line : String -> Html msg -> String
line label h =
    let
        native =
            Dom.toString h

        reference =
            Dom.render (Dom.fromNode h)
    in
    label
        ++ ": "
        ++ String.fromInt (String.length native)
        ++ " "
        ++ (if native == reference then
                "True"

            else
                "False"
           )


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.Log.line env.stdout
                    (line "deep" (deep 10000 (Html.text "leaf")) ++ "\n" ++ line "wide" (wide 200000))
                )
        )
