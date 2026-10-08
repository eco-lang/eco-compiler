effect module Http.Server where { subscription = MySub } exposing
    ( Server, ServerError(..), createServer
    , ServerOptions, defaultServerOptions, createServerWith, serverPort, closeServer, closeServerWithin
    , Request, Method(..), HttpVersion(..), methodToString, bodyAsString, bodyFromJson, requestInfo
    , onRequest
    , upgradeRequest
    )

{-| Create a server that can respond to HTTP requests.

You write your server using The Elm Architecture: create a [`Server`](#Server) with
[`createServer`](#createServer), subscribe to its requests with [`onRequest`](#onRequest), and
answer each request with a command built from [`Http.Server.Response`](Http-Server-Response) in
your `update` function.

The server speaks HTTP/1.1 (and HTTP/1.0) with keep-alive: a connection serves one request after
the other, and requests a client sends ahead of their answers (pipelining) are handed to you one
at a time, in order, each after the previous one was answered. Request sizes and the time a client
may take to send a request are limited (see [`ServerOptions`](#ServerOptions)); requests that break
the limits or the HTTP rules are answered by the server itself (400, 408, 413, 417, 431, 505) and
never reach your program.

Unlike gren-node's `HttpServer` module, there is no permission value and no `initialize`.


## Servers

@docs Server, ServerError, createServer
@docs ServerOptions, defaultServerOptions, createServerWith, serverPort, closeServer, closeServerWithin


## Requests

@docs Request, Method, HttpVersion, methodToString, bodyAsString, bodyFromJson, requestInfo


## Responding to requests

@docs onRequest

See [`Http.Server.Response`](Http-Server-Response) for more details on responding to requests.


## WebSockets

@docs upgradeRequest

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.HttpServer
import Eco.Kernel.Stream
import Eco.Kernel.WebSocket
import Http.Server.Internal as Internal
import Http.Server.Response
import Json.Decode
import Platform
import Process
import Socket
import Socket.Address exposing (Address)
import Socket.Internal
import Socket.Tls
import Task exposing (Task)
import Url exposing (Url)
import WebSocket
import WebSocket.Internal



-- SERVERS


{-| An HTTP server listening on a host and port.
-}
type Server
    = Server { id : Int, port_ : Int }


{-| Error code and message from the operating system, most likely from a failed attempt to start
the server. The code is the name of the system error, for example `"EADDRINUSE"` when the port is
already taken.
-}
type ServerError
    = ServerError { code : String, message : String }


{-| Task to create a [`Server`](#Server) listening on the given host and port, with the limits
and timeouts of [`defaultServerOptions`](#defaultServerOptions). Port 0 lets the system pick a
free port ([`serverPort`](#serverPort) tells which).

    Http.Server.createServer { host = "127.0.0.1", port_ = 8080 }

A listening server keeps the program running until it is closed with
[`closeServer`](#closeServer).

-}
createServer : { host : String, port_ : Int } -> Task ServerError Server
createServer options =
    kCreateServer options.host options.port_
        |> Task.map (\( id, port_ ) -> Server { id = id, port_ = port_ })
        |> Task.mapError toServerError


toServerError : ( String, String ) -> ServerError
toServerError ( code, message ) =
    ServerError { code = code, message = message }


{-| How to run a server, for [`createServerWith`](#createServerWith).

  - `address`, `port_`: where to listen. Port 0 lets the system pick a free port
    ([`serverPort`](#serverPort) tells which).
  - `tls`: serve HTTPS (and so `wss` WebSockets) with this certificate chain and key; request
    URLs then start with `https://`. Its `alpn` field is ignored: the server chooses the
    application protocol itself (ALPN `h2` and `http/1.1` with `http2`, else `http/1.1`), and a
    client that offers no protocol the server speaks still connects, without ALPN, and is served
    HTTP/1.1.
  - `http2`: also serve HTTP/2 to clients that ask for it (ALPN `h2`; there is no HTTP/2 without
    TLS). Requires `tls`. TLS 1.2 is then restricted to the cipher suites HTTP/2 allows. Requests
    over HTTP/2 have `version = Http2` and lower-case header names; several requests run at once
    on one connection, and each is answered on its own. A server with HTTP/2 and no
    `maxConcurrentStreams` limits a client that keeps cancelling its requests only by a reset
    rate (about 1000 at once, then 33 per second): set `maxConcurrentStreams` on a public server.
  - `maxConnections`: the most connections open at once; further clients wait until one closes.
    `Nothing` (the default) sets no limit.
  - `maxConcurrentStreams`: the most HTTP/2 requests (including WebSockets) in progress at once on
    one connection, advertised to the client. Natively, requests your program has not answered
    yet count, even when the client cancelled them: at the limit the server reads nothing more
    from that connection until you answer one (on the JS target, Node refuses the streams over
    the limit instead). `Nothing` (the default) sets no limit; public servers should set one.
  - `maxBodySize`: the largest request body, in bytes (larger requests are answered 413).
  - `maxHeaderSize`: the largest request header block, in bytes (larger ones are answered 431).
  - `keepAliveTimeout`: how long an idle connection stays open between requests, in milliseconds.
  - `headersTimeout`: the time allowed from the first byte of a request to the end of its headers
    (408 when exceeded), in milliseconds.
  - `requestTimeout`: the time allowed from the first byte of a request to the end of its body
    (408 when exceeded), in milliseconds.

A timeout of 0 or less is no timeout. There is no time limit on your program's answer: the
connection waits for it (a client that gives up just closes the connection).

-}
type alias ServerOptions =
    { address : Address
    , port_ : Int
    , tls : Maybe Socket.Tls.ServerOptions
    , http2 : Bool
    , maxConnections : Maybe Int
    , maxConcurrentStreams : Maybe Int
    , maxBodySize : Int
    , maxHeaderSize : Int
    , keepAliveTimeout : Int
    , headersTimeout : Int
    , requestTimeout : Int
    }


{-| Plain HTTP on an address and port, without connection or stream limits, with bodies up to
16 MiB, header blocks up to 64 KiB, a 5 second keep-alive timeout, a 60 second headers timeout and
a 300 second request timeout.

    Http.Server.defaultServerOptions (Socket.Address.loopback Socket.Address.IPv4) 8080

-}
defaultServerOptions : Address -> Int -> ServerOptions
defaultServerOptions address port_ =
    { address = address
    , port_ = port_
    , tls = Nothing
    , http2 = False
    , maxConnections = Nothing
    , maxConcurrentStreams = Nothing
    , maxBodySize = 16 * 1024 * 1024
    , maxHeaderSize = 64 * 1024
    , keepAliveTimeout = 5000
    , headersTimeout = 60000
    , requestTimeout = 300000
    }


{-| Task to create a [`Server`](#Server) with [`ServerOptions`](#ServerOptions).

Fails like [`createServer`](#createServer), with `EINVAL` when `http2` is set without `tls`, and
with an `"ERR_SSL_"` code when the certificate or key cannot be used.

    let
        options =
            Http.Server.defaultServerOptions (Socket.Address.loopback Socket.Address.IPv4) 8443
    in
    Http.Server.createServerWith
        { options | tls = Just { certificateChain = cert, privateKey = key, alpn = [] } }

-}
createServerWith : ServerOptions -> Task ServerError Server
createServerWith options =
    if options.http2 && options.tls == Nothing then
        Task.fail (ServerError { code = "EINVAL", message = "createServerWith: http2 requires tls" })

    else
        kCreateServerWith
            ( ( Socket.Address.toString options.address, options.port_ )
            , ( options.http2, limit options.maxConnections )
            )
            (Maybe.map (\tls -> ( tls.certificateChain, tls.privateKey )) options.tls)
            ( ( options.keepAliveTimeout, options.headersTimeout, options.requestTimeout )
            , ( options.maxBodySize, options.maxHeaderSize, limit options.maxConcurrentStreams )
            )
            |> Task.map (\( id, port_ ) -> Server { id = id, port_ = port_ })
            |> Task.mapError toServerError


{-| A limit for the kernel: -1 is none.
-}
limit : Maybe Int -> Int
limit value =
    case value of
        Just n ->
            max 0 n

        Nothing ->
            -1


{-| The port a server listens on: the one it was created with, or, for port 0, the one the system
picked.
-}
serverPort : Server -> Int
serverPort (Server s) =
    s.port_


{-| Stop a server gracefully, within 5 seconds: [`closeServerWithin`](#closeServerWithin) 5000.
-}
closeServer : Server -> Task x ()
closeServer =
    closeServerWithin 5000


{-| Stop a server gracefully, within the given number of milliseconds. The server stops accepting
connections at once (the port is free when the task completes) and closes its idle connections.
Requests that were received but not yet delivered are answered 503; requests already delivered can
still be answered (with `Connection: close`) until the deadline, when the remaining connections are
closed. WebSocket connections are not affected.

Closing a server twice is fine. A closed server no longer keeps the program running.

-}
closeServerWithin : Int -> Server -> Task x ()
closeServerWithin deadline (Server s) =
    kCloseServer s.id deadline
        |> Task.mapError never



-- REQUESTS


{-| An incoming HTTP request.

  - `headers` holds the request headers. If a header appears more than once, the last value wins.
    Names are as the client sent them, which over HTTP/2 is always lower case: look headers up
    case-insensitively (or by their lower-case name). Over HTTP/2 the pseudo-header fields
    (`:method`, `:path`, ...) are not included, and several `cookie` fields are joined into one
    with `"; "`.
  - `method` is the HTTP method.
  - `body` is the complete request body.
  - `url` is the absolute URL of the request, built from the `Host` header (HTTP/2: `:authority`),
    or the server's own host and port, and the request target.
  - `version` is the HTTP version the client speaks.
  - `upgrade` is the protocol the client asks to switch to, lower-cased, for example
    `Just "websocket"` (the HTTP/1.1 `Upgrade` header, or HTTP/2's `:protocol`). Answer a WebSocket
    request with [`upgradeRequest`](#upgradeRequest); any other response refuses the upgrade.

-}
type alias Request =
    { headers : Dict String String
    , method : Method
    , body : Bytes
    , url : Url
    , version : HttpVersion
    , upgrade : Maybe String
    }


{-| The HTTP version of a request.
-}
type HttpVersion
    = Http1_0
    | Http1_1
    | Http2


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


{-| Build a `Request` from the pieces handed over by the server (plans/eco-system-websockets.md
C.1): the URL is absolute (base plan Appendix E.5) and falls back to gren's default record if it
does not parse; each header occurrence is one `( name, [ value ] )` entry in arrival order, and
the last one wins; `flags` bits 0–1 are the version (0 = 1.0, 1 = 1.1, 2 = 2) and bit 2 is TLS;
an empty upgrade token is `Nothing`.
-}
toRequest : String -> String -> List ( String, List String ) -> Bytes -> Int -> String -> Request
toRequest method url headers body flags upgradeToken =
    { headers = List.foldl insertHeader Dict.empty headers
    , method = toMethod method
    , body = body
    , url =
        Url.fromString url
            |> Maybe.withDefault
                { protocol =
                    if modBy 8 flags >= 4 then
                        Url.Https

                    else
                        Url.Http
                , host = ""
                , port_ = Nothing
                , path = ""
                , query = Nothing
                , fragment = Nothing
                }
    , version =
        case modBy 4 flags of
            0 ->
                Http1_0

            2 ->
                Http2

            _ ->
                Http1_1
    , upgrade =
        if upgradeToken == "" then
            Nothing

        else
            Just upgradeToken
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
onRequest (Server s) toMsg =
    subscription
        (OnRequest s.id
            (\( ( method, url ), ( headers, body ), ( key, flags, upgradeToken ) ) ->
                toMsg (toRequest method url headers body flags upgradeToken) (freshResponse key)
            )
        )


{-| Answer a WebSocket opening request (a [`Request`](#Request) whose `upgrade` is
`Just "websocket"`, over HTTP/1.1 or HTTP/2) instead of sending its
[`Response`](Http-Server-Response#Response): the result is a
[`WebSocket.Upgrade`](WebSocket#Upgrade), to answer with
[`WebSocket.accept`](WebSocket#accept) or [`WebSocket.reject`](WebSocket#reject). The `Response`
is used up: sending it later does nothing.

    GotRequest request response ->
        if request.upgrade == Just "websocket" then
            ( model
            , Http.Server.upgradeRequest request response
                |> Task.andThen (WebSocket.accept WebSocket.defaultAcceptOptions)
                |> Task.attempt GotWebSocket
            )

        else
            ...

The opening request is checked by `WebSocket.accept` (which answers a request that breaks the
rules 400 or 426 itself), exactly as for [`WebSocket.upgradeRequest`](WebSocket#upgradeRequest).
Requests the client sent before this one on the same connection are answered first: the `101`
follows their responses. Over TLS the result is a `wss` WebSocket.

Over HTTP/2 (RFC 8441: an extended `CONNECT` with `:protocol websocket`, which a server with
`http2` allows) the WebSocket runs on that one stream of the connection, next to the connection's
other requests and WebSockets: `accept` answers `200` and the stream carries the frames; the close
handshake ends the stream (`END_STREAM`) and an aborted WebSocket resets it (`CANCEL`). Such a
WebSocket counts against `maxConcurrentStreams` like any request, when it is set. Another
`:protocol` is answered `501` by the server itself.

The WebSocket does not belong to the server: [`closeServer`](#closeServer) leaves it open (over
HTTP/2, until the close deadline, which ends the connection it shares).

Fails with `EINVAL` when the request does not ask for a WebSocket, or was already answered (or
upgraded), and with `ECANCELED` when its connection is gone.

-}
upgradeRequest : Request -> Http.Server.Response.Response -> Task Socket.Error WebSocket.Upgrade
upgradeRequest request (Internal.Response r) =
    if request.upgrade /= Just "websocket" then
        Task.fail
            (Socket.Internal.toError
                ( "EINVAL", "upgradeRequest EINVAL: the request does not ask for a WebSocket" )
            )

    else
        kTakeUpgrade r.key
            |> Task.map (WebSocket.Internal.toUpgrade kAcceptFor)
            |> Task.mapError Socket.Internal.toError


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
-- The tagger argument is ( ( method, absoluteUrl ), ( headers, body ), ( responseKey, flags,
-- upgradeToken ) ) (plans/eco-system-websockets.md Appendix C.1).


type MySub msg
    = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) ) -> msg)


subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnRequest id tagger) =
    OnRequest id (tagger >> f)


type alias RequestArg =
    ( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) )


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
onSelfMsg router (Incoming id (( _, _, ( key, _, _ ) ) as arg)) state =
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
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.6,
-- plans/eco-system-websockets.md Appendix B.2).


kCreateServer : String -> Int -> Task ( String, String ) ( Int, Int )
kCreateServer =
    Eco.Kernel.HttpServer.createServer


kCreateServerWith :
    ( ( String, Int ), ( Bool, Int ) )
    -> Maybe ( String, String )
    -> ( ( Int, Int, Int ), ( Int, Int, Int ) )
    -> Task ( String, String ) ( Int, Int )
kCreateServerWith =
    Eco.Kernel.HttpServer.createServerWith


kCloseServer : Int -> Int -> Task Never ()
kCloseServer =
    Eco.Kernel.HttpServer.closeServer


kTakeUpgrade : Int -> Task ( String, String ) WebSocket.Internal.UpgradeArg
kTakeUpgrade =
    Eco.Kernel.HttpServer.takeUpgrade


kAcceptFor : String -> String
kAcceptFor =
    Eco.Kernel.WebSocket.acceptFor


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
