module Http.Server.Internal exposing (Body(..), Response(..))

{-| The constructors of the HTTP server's response type, kept in a module the package does not
expose. `Http.Server` imports them to build and take apart responses, while a program using the
package sees `Http.Server.Response` only as an alias it cannot open.

A response answers one request. It carries that request's _response key_: the kernel's id for a
request that is waiting for an answer. The kernel releases the key when the request is answered,
when `Http.Server.upgradeRequest` takes it over, and when its connection goes away. It is
therefore the key, not the `Response` value, that decides whether sending writes anything: a
second `send` of the same response, or a `send` after an upgrade, writes nothing.

A body is turned into bytes only when the response is sent, not when it is set. For an HTML
body that is also when it is turned into text.

-}

import Bytes exposing (Bytes)
import Html.Dom as Dom


{-| An HTTP response being built for one request.

`key` is the response key of the request the response answers. `headers` pairs each header name
with all of its values.

-}
type Response
    = Response
        { key : Int
        , status : Int
        , headers : List ( String, List String )
        , body : Body
        }


{-| The body of a response: a string, bytes or HTML.

A `StringBody` is sent encoded as UTF-8, except that the backends write a lone surrogate
differently: the JS backend as U+FFFD, the native one in its 3-byte form, which is not valid
UTF-8. A `BytesBody` is sent as it is.

An `HtmlBody` holds the HTML as an `Html.Dom.Node` and is not serialized until the response is
sent, when the kernel writes the node's HTML text into the response, encoded as UTF-8 with the
same lone-surrogate difference as a `StringBody`. `Html.Dom` describes that text, and
`Http.Server.setBodyAsHtml` what the server adds to the response with it.

-}
type Body
    = StringBody String
    | BytesBody Bytes
    | HtmlBody Dom.Node
