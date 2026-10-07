module Http.Server exposing
    ( Server, ServerError(..), createServer
    , Request, Method(..), methodToString, bodyAsString, bodyFromJson, requestInfo
    , onRequest
    )

{-| Create a server that can respond to HTTP requests.

You write your server using The Elm Architecture: create a [`Server`](#Server) with
[`createServer`](#createServer), subscribe to its requests with [`onRequest`](#onRequest), and
answer each request with a command built from [`Http.Server.Response`](Http-Server-Response) in
your `update` function.

This first version speaks HTTP/1.1 without keep-alive: every response closes its connection.

Unlike gren-node's `HttpServer` module, there is no permission value and no `initialize`.


## Servers

@docs Server, ServerError, createServer


## Requests

@docs Request, Method, methodToString, bodyAsString, bodyFromJson, requestInfo


## Responding to requests

@docs onRequest

See [`Http.Server.Response`](Http-Server-Response) for more details on responding to requests.

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Http.Server.Response
import Json.Decode
import Task exposing (Task)
import Url exposing (Url)



-- SERVERS


{-| An HTTP server listening on a host and port.
-}
type Server
    = Server Int


{-| Error code and message from the operating system, most likely from a failed attempt to start
the server. The code is the name of the system error, for example `"EADDRINUSE"` when the port is
already taken.
-}
type ServerError
    = ServerError { code : String, message : String }


{-| Task to create a [`Server`](#Server) listening on the given host and port.

    Http.Server.createServer { host = "127.0.0.1", port_ = 8080 }

A listening server keeps the program running.

-}
createServer : { host : String, port_ : Int } -> Task ServerError Server
createServer options =
    Debug.todo "Implement System API"



-- REQUESTS


{-| An incoming HTTP request.

  - `headers` holds the request headers. If a header appears more than once, the last value wins.
  - `method` is the HTTP method.
  - `body` is the complete request body.
  - `url` is the absolute URL of the request, built from the `Host` header (or the server's own
    host and port) and the request target.

-}
type alias Request =
    { headers : Dict String String
    , method : Method
    , body : Bytes
    , url : Url
    }


{-| HTTP request methods. Methods not listed here are represented by `UNKNOWN`, holding the
method name as it was sent.
-}
type Method
    = GET
    | HEAD
    | POST
    | PUT
    | DELETE
    | CONNECT
    | TRACE
    | PATCH
    | UNKNOWN String


{-| String representation of a method, for example `"GET"`. `UNKNOWN m` becomes `m`.
-}
methodToString : Method -> String
methodToString method =
    Debug.todo "Implement System API"


{-| Get the request body as a string. Returns `Nothing` if the body is not valid UTF-8.
-}
bodyAsString : Request -> Maybe String
bodyAsString request =
    Debug.todo "Implement System API"


{-| Decode the request body as JSON. A body that is not valid UTF-8 is treated as the empty
string, so the decoder fails.
-}
bodyFromJson : Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a
bodyFromJson decoder request =
    Debug.todo "Implement System API"


{-| Get a string representation of the request, for example `"GET http://localhost:8080/"`.

Good for logging.

-}
requestInfo : Request -> String
requestInfo request =
    Debug.todo "Implement System API"


{-| Subscribe to incoming HTTP requests on a server. For every request you receive the
[`Request`](#Request) and a fresh [`Response`](Http-Server-Response#Response) that answers it.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Http.Server.onRequest model.server GotRequest

-}
onRequest : Server -> (Request -> Http.Server.Response.Response -> msg) -> Sub msg
onRequest server toMsg =
    Debug.todo "Implement System API"
