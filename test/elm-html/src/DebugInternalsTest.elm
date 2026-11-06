module DebugInternalsTest exposing (main)

{-| `Debug.toString` prints an `Html` node or a `Json.Encode.Value` as `<internals>`.

These are opaque values whose contents `Debug.toString` does not show. The test
logs an element with an attribute and a child, a bare text node, an encoded
JSON string, and a tuple holding a text node and an `Int`, where only the node
is replaced by `<internals>`.

-}

-- CHECK: html: <internals>
-- CHECK: text: <internals>
-- CHECK: json: <internals>
-- CHECK: pair: (<internals>,1)

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
