effect module Http.Server where { subscription = MySub } exposing
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
import Eco.Kernel.HttpServer
import Eco.Kernel.Stream
import Http.Server.Internal as Internal
import Http.Server.Response
import Json.Decode
import Platform
import Process
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
    kCreateServer options.host options.port_
        |> Task.map Server
        |> Task.mapError (\( code, message ) -> ServerError { code = code, message = message })



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
    case method of
        GET ->
            "GET"

        HEAD ->
            "HEAD"

        POST ->
            "POST"

        PUT ->
            "PUT"

        DELETE ->
            "DELETE"

        CONNECT ->
            "CONNECT"

        TRACE ->
            "TRACE"

        PATCH ->
            "PATCH"

        UNKNOWN value ->
            value


toMethod : String -> Method
toMethod s =
    case s of
        "GET" ->
            GET

        "HEAD" ->
            HEAD

        "POST" ->
            POST

        "PUT" ->
            PUT

        "DELETE" ->
            DELETE

        "CONNECT" ->
            CONNECT

        "TRACE" ->
            TRACE

        "PATCH" ->
            PATCH

        _ ->
            UNKNOWN s


{-| Build a `Request` from the pieces handed over by the server (C.5): the URL is absolute
(Appendix E.5) and falls back to gren's default record if it does not parse; each header
occurrence is one `( name, [ value ] )` entry in arrival order, and the last one wins.
-}
toRequest : String -> String -> List ( String, List String ) -> Bytes -> Request
toRequest method url headers body =
    { headers = List.foldl insertHeader Dict.empty headers
    , method = toMethod method
    , body = body
    , url =
        Url.fromString url
            |> Maybe.withDefault
                { protocol = Url.Http
                , host = ""
                , port_ = Nothing
                , path = ""
                , query = Nothing
                , fragment = Nothing
                }
    }


insertHeader : ( String, List String ) -> Dict String String -> Dict String String
insertHeader ( name, values ) dict =
    case List.head (List.reverse values) of
        Just value ->
            Dict.insert name value dict

        Nothing ->
            dict


{-| Get the request body as a string. Returns `Nothing` if the body is not valid UTF-8.
-}
bodyAsString : Request -> Maybe String
bodyAsString request =
    kUtf8ToString request.body


{-| Decode the request body as JSON. A body that is not valid UTF-8 is treated as the empty
string, so the decoder fails.
-}
bodyFromJson : Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a
bodyFromJson decoder request =
    request
        |> bodyAsString
        |> Maybe.withDefault ""
        |> Json.Decode.decodeString decoder


{-| Get a string representation of the request, for example `"GET http://localhost:8080/"`.

Good for logging.

-}
requestInfo : Request -> String
requestInfo request =
    let
        method =
            case request.method of
                UNKNOWN m ->
                    "UNKNOWN(" ++ m ++ ")"

                known ->
                    methodToString known
    in
    method ++ " " ++ Url.toString request.url


{-| Subscribe to incoming HTTP requests on a server. For every request you receive the
[`Request`](#Request) and a fresh [`Response`](Http-Server-Response#Response) that answers it.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Http.Server.onRequest model.server GotRequest

-}
onRequest : Server -> (Request -> Http.Server.Response.Response -> msg) -> Sub msg
onRequest (Server id) toMsg =
    subscription
        (OnRequest id
            (\( ( method, url ), ( headers, body ), key ) ->
                toMsg (toRequest method url headers body) (freshResponse key)
            )
        )


{-| A fresh response: status 200, no headers, empty body.
-}
freshResponse : Int -> Http.Server.Response.Response
freshResponse key =
    Internal.Response
        { key = key
        , status = 200
        , headers = []
        , body = Internal.StringBody ""
        }



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "Http.Server"
-- (src/eco-system/HttpServer/HttpServerManager.{hpp,cpp}, plans/eco-system-library.md
-- Appendix C.5) and ignores the Elm functions below. The JS backend runs them
-- (plans/eco-system-library.md Phase 10, D15): every server with subscribers keeps one
-- listener process (a never-completing kernel binding, killed when the server's last
-- subscription goes away) that notifies the manager through `Platform.sendToSelf`; the
-- manager hands each request to every tagger of that server. Requests for a server
-- without subscribers are held by the kernel until one appears, as natively. The
-- constructor layout of MySub is mirrored by HttpServerManager.hpp: keep them in sync.
-- The tagger argument is ( ( method, absoluteUrl ), ( headers, body ), responseKey ).


type MySub msg
    = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), Int ) -> msg)


subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnRequest id tagger) =
    OnRequest id (tagger >> f)


type alias RequestArg =
    ( ( String, String ), ( List ( String, List String ), Bytes ), Int )


{-| Per server id: its taggers in subscription order, and the process running its listener.
-}
type alias State msg =
    Dict Int (ServerListeners msg)


type alias ServerListeners msg =
    { taggers : List (RequestArg -> msg)
    , listener : Process.Id
    }


type Event
    = Incoming Int RequestArg


init : Task Never (State msg)
init =
    Task.succeed Dict.empty


onEffects : Platform.Router msg Event -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router subs state =
    let
        -- Effects arrive in reverse order of declaration.
        grouped =
            List.foldr
                (\(OnRequest id tagger) dict ->
                    Dict.update id (\old -> Just (tagger :: Maybe.withDefault [] old)) dict
                )
                Dict.empty
                (List.reverse subs)

        stopped =
            Dict.diff state grouped
                |> Dict.values
                |> List.map (\entry -> Process.kill entry.listener)

        running =
            Dict.toList grouped
                |> List.map
                    (\( id, taggers ) ->
                        case Dict.get id state of
                            Just entry ->
                                Task.succeed ( id, { taggers = taggers, listener = entry.listener } )

                            Nothing ->
                                Process.spawn (kAttachRequestListener id (\arg -> Platform.sendToSelf router (Incoming id arg)))
                                    |> Task.map (\pid -> ( id, { taggers = taggers, listener = pid } ))
                    )
    in
    Task.sequence stopped
        |> Task.andThen (\_ -> Task.sequence running)
        |> Task.map Dict.fromList


onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router (Incoming id (( _, _, key ) as arg)) state =
    case Dict.get id state of
        Just entry ->
            entry.taggers
                |> List.map (\tagger -> Platform.sendToApp router (tagger arg))
                |> Task.sequence
                |> Task.map (\_ -> state)

        Nothing ->
            -- The last subscriber went away after the listener sent this request.
            kHoldRequest id key
                |> Task.map (\_ -> state)



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.6).


kCreateServer : String -> Int -> Task ( String, String ) Int
kCreateServer =
    Eco.Kernel.HttpServer.createServer


kUtf8ToString : Bytes -> Maybe String
kUtf8ToString =
    Eco.Kernel.Stream.utf8ToString



-- JS-only kernels, used by the effect-manager bodies above (the native backend drops those
-- bodies, so these have no C++ counterpart).


kAttachRequestListener : Int -> (RequestArg -> Task Never ()) -> Task Never ()
kAttachRequestListener =
    Eco.Kernel.HttpServer.attachRequestListener


kHoldRequest : Int -> Int -> Task Never ()
kHoldRequest =
    Eco.Kernel.HttpServer.holdRequest
