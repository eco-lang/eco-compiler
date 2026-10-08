module Http.Server.Internal exposing (Body(..), Response(..))

{-| Internal; not exposed.

`Response` is defined here so that both `Http.Server` and `Http.Server.Response` can build it,
while users only see the alias exposed by `Http.Server.Response`.

-}

import Bytes exposing (Bytes)
import Http.Dom as Dom


{-| An HTTP response under construction. `key` identifies the request it answers.
-}
type Response
    = Response
        { key : Int
        , status : Int
        , headers : List ( String, List String )
        , body : Body
        }


{-| The body of a response. An `HtmlBody` is serialized when the response is sent
(plans/elm-html-native-kernel.md §7.3).
-}
type Body
    = StringBody String
    | BytesBody Bytes
    | HtmlBody Dom.Node
