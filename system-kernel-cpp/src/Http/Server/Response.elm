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
import Eco.Kernel.HttpServer
import Eco.Kernel.Stream
import Http.Server.Internal as Internal exposing (Body(..))
import System
import Task exposing (Task)


{-| An HTTP response to a single request. You receive one from
[`Http.Server.onRequest`](Http-Server#onRequest) together with the request it answers.
-}
type alias Response =
    Internal.Response


{-| Command to send an HTTP response.

The response is written with a `Content-Length` header and the connection is closed afterwards.
Send each response only once.

-}
send : Response -> Cmd msg
send (Internal.Response r) =
    System.endSimpleProgram (kRespond r.key r.status r.headers (bodyBytes r.body))


bodyBytes : Body -> Bytes
bodyBytes body =
    case body of
        StringBody s ->
            kStringToUtf8 s

        BytesBody b ->
            b


{-| Set the HTTP status code of a response.

    response |> Http.Server.Response.setStatus 404

-}
setStatus : Int -> Response -> Response
setStatus status (Internal.Response r) =
    Internal.Response { r | status = status }


{-| Set a header on a response, replacing any values it already has.
-}
setHeader : String -> String -> Response -> Response
setHeader key value (Internal.Response r) =
    Internal.Response { r | headers = updateHeader key (\_ -> [ value ]) r.headers }


{-| Append a value to an existing header. If the header does not exist yet, it will be created.
Use this for headers that may appear more than once, such as `Set-Cookie`.
-}
appendHeader : String -> String -> Response -> Response
appendHeader key value (Internal.Response r) =
    Internal.Response { r | headers = updateHeader key (\old -> old ++ [ value ]) r.headers }


{-| Replace the values of header `key` (the name matches exactly, as in gren's `Dict`), keeping
its position, or append it with `f []` if it is not there yet.
-}
updateHeader : String -> (List String -> List String) -> List ( String, List String ) -> List ( String, List String )
updateHeader key f headers =
    if List.any (\( k, _ ) -> k == key) headers then
        List.map
            (\( k, vs ) ->
                if k == key then
                    ( k, f vs )

                else
                    ( k, vs )
            )
            headers

    else
        headers ++ [ ( key, f [] ) ]


{-| Alias for [`setBodyAsString`](#setBodyAsString).
-}
setBody : String -> Response -> Response
setBody =
    setBodyAsString


{-| Set the body of the response to a string. It is sent encoded as UTF-8.
-}
setBodyAsString : String -> Response -> Response
setBodyAsString body (Internal.Response r) =
    Internal.Response { r | body = StringBody body }


{-| Set the body of the response to some bytes.
-}
setBodyAsBytes : Bytes -> Response -> Response
setBodyAsBytes body (Internal.Response r) =
    Internal.Response { r | body = BytesBody body }



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.6).


kRespond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
kRespond =
    Eco.Kernel.HttpServer.respond


kStringToUtf8 : String -> Bytes
kStringToUtf8 =
    Eco.Kernel.Stream.stringToUtf8
