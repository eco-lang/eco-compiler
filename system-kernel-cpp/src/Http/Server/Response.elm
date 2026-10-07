module Http.Server.Response exposing
    ( Response, send
    , setStatus, setHeader, appendHeader
    , setBody, setBodyAsString, setBodyAsBytes
    )

{-| Build up a response to an HTTP request and send it as a command.

Usually this will look something like this in your `update` function, assuming you
[subscribed](Http-Server#onRequest) with a `GotRequest` message:

    GotRequest request response ->
        ( model
        , response
            |> Http.Server.Response.setHeader "Content-Type" "text/html"
            |> Http.Server.Response.setBody "<html>Hello there!</html>"
            |> Http.Server.Response.send
        )

A fresh response has status `200`, no headers and an empty body.

@docs Response, send


## Status and headers

@docs setStatus, setHeader, appendHeader


## Body

@docs setBody, setBodyAsString, setBodyAsBytes

-}

import Bytes exposing (Bytes)
import Http.Server.Internal


{-| An HTTP response to a single request. You receive one from
[`Http.Server.onRequest`](Http-Server#onRequest) together with the request it answers.
-}
type alias Response =
    Http.Server.Internal.Response


{-| Command to send an HTTP response.

The response is written with a `Content-Length` header and the connection is closed afterwards.
Send each response only once.

-}
send : Response -> Cmd msg
send response =
    Debug.todo "Implement System API"


{-| Set the HTTP status code of a response.

    response |> Http.Server.Response.setStatus 404

-}
setStatus : Int -> Response -> Response
setStatus status response =
    Debug.todo "Implement System API"


{-| Set a header on a response, replacing any values it already has.
-}
setHeader : String -> String -> Response -> Response
setHeader key value response =
    Debug.todo "Implement System API"


{-| Append a value to an existing header. If the header does not exist yet, it will be created.
Use this for headers that may appear more than once, such as `Set-Cookie`.
-}
appendHeader : String -> String -> Response -> Response
appendHeader key value response =
    Debug.todo "Implement System API"


{-| Alias for [`setBodyAsString`](#setBodyAsString).
-}
setBody : String -> Response -> Response
setBody body response =
    Debug.todo "Implement System API"


{-| Set the body of the response to a string. It is sent encoded as UTF-8.
-}
setBodyAsString : String -> Response -> Response
setBodyAsString body response =
    Debug.todo "Implement System API"


{-| Set the body of the response to some bytes.
-}
setBodyAsBytes : Bytes -> Response -> Response
setBodyAsBytes body response =
    Debug.todo "Implement System API"
