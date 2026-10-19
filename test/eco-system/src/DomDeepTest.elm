module DomDeepTest exposing (main)

{-| A 10k-deep and a 200k-wide tree through both serializers
(plans/elm-html-native-kernel.md P5, D17): neither the C++ writer, the Elm
`render` nor (on JS) the twin's conversion recurses with the tree size.
-}

-- CHECK: deep: 110004 True
-- CHECK-NEXT: wide: 2800011 True
-- EXIT: 0

import Html exposing (Html)
import Html.Dom as Dom
import Stream
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
            Dom.htmlToString h

        reference =
            Dom.toString (Dom.fromHtml h)
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


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine (line "deep" (deep 10000 (Html.text "leaf")) ++ "\n" ++ line "wide" (wide 200000)) env.stdout
        )
