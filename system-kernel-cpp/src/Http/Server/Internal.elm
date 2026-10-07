module Http.Server.Internal exposing (Body(..), Response(..))

{-| Internal; not exposed.

`Response` is defined here so that both `Http.Server` and `Http.Server.Response` can build it,
while users only see the alias exposed by `Http.Server.Response`.

-}

import Bytes exposing (Bytes)


{-| An HTTP response under construction. `key` identifies the request it answers.
-}
type Response
    = Response
        { key : Int
        , status : Int
        , headers : List ( String, List String )
        , body : Body
        }


{-| The body of a response.
-}
type Body
    = StringBody String
    | BytesBody Bytes
