module DebugInternalsTest exposing (main)

{-| Debug.toString on kernel-built values whose heap shape differs from their
declared type prints `<internals>`, as on JS, instead of asserting
(plans/elm-html-native-kernel.md D19, P0.1).
-}

-- CHECK: html: <internals>
-- CHECK: text: <internals>
-- CHECK: json: <internals>
-- CHECK: pair: (<internals>, 1)

import Html
import Html.Attributes
import Json.Encode


main =
    let
        _ =
            Debug.log "html" (Html.div [ Html.Attributes.id "x" ] [ Html.text "x" ])

        _ =
            Debug.log "text" (Html.text "x")

        _ =
            Debug.log "json" (Json.Encode.string "x")

        _ =
            Debug.log "pair" ( Html.text "y", 1 )
    in
    Html.text "done"
