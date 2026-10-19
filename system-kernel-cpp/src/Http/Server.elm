effect module Http.Server where { command = MyCmd, subscription = MySub } exposing
    ( Server, ListenOptions, defaultListenOptions, listen, listenOnHost, endpoint, close, closeWithin
    , Request, Method(..), HttpVersion(..), methodToString, bodyAsString, bodyAsJson, requestToString, onRequest
    , Response, send
    , setStatus, setHeader, appendHeader
    , setBody, setBodyAsString, setBodyAsBytes, setBodyAsHtml
    , upgradeRequest
    , Error, errorCode, errorToString
    , errorIsAddressInUse, errorIsAddressNotAvailable, errorIsHostNotFound, errorIsPermissionDenied, errorIsCertificateInvalid
    )

{-| Create a server that can respond to HTTP requests.

You write your server using The Elm Architecture: start a [`Server`](#Server) with
[`listen`](#listen) or [`listenOnHost`](#listenOnHost), subscribe to its requests with
[`onRequest`](#onRequest), and answer each request by building up its [`Response`](#Response)
and [`send`](#send)ing it from your `update` function:

    GotRequest request response ->
        ( model
        , response
            |> Http.Server.setHeader "Content-Type" "text/html"
            |> Http.Server.setBody "<html>Hello there!</html>"
            |> Http.Server.send
        )

The server speaks HTTP/1.1 (and HTTP/1.0) with keep-alive: a connection serves one request after
the other, and requests a client sends ahead of their answers (pipelining) are handed to you one
at a time, in order, each after the previous one was answered. Request sizes and the time a client
may take to send a request are limited (see [`ListenOptions`](#ListenOptions)); requests that break
the limits or the HTTP rules are answered by the server itself (400, 408, 413, 417, 431, 505) and
never reach your program.

Unlike gren-node's `HttpServer` module, there is no permission value and no `initialize`, and
the response functions of gren's `HttpServer.Response` are part of this module.


## Servers

@docs Server, ListenOptions, defaultListenOptions, listen, listenOnHost, endpoint, close, closeWithin


## Requests

@docs Request, Method, HttpVersion, methodToString, bodyAsString, bodyAsJson, requestToString, onRequest


## Responses

A fresh response has status `200`, no headers and an empty body.

@docs Response, send


### Status and headers

@docs setStatus, setHeader, appendHeader


### Body

@docs setBody, setBodyAsString, setBodyAsBytes, setBodyAsHtml


## WebSockets

@docs upgradeRequest


## Errors

@docs Error, errorCode, errorToString
@docs errorIsAddressInUse, errorIsAddressNotAvailable, errorIsHostNotFound, errorIsPermissionDenied, errorIsCertificateInvalid

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.HttpServer
import Eco.Kernel.Stream
import Eco.Kernel.WebSocket
import Html.Dom as Dom
import Http.Server.Internal as Internal exposing (Body(..))
import Json.Decode
import Platform
import Process
import Socket
import Socket.Address exposing (Address, InetEndpoint)
import Socket.Internal
import Socket.Tls
import Task exposing (Task)
import Url exposing (Url)
import VirtualDom
import WebSocket
import WebSocket.Internal



-- SERVERS


{-| An HTTP server listening on a host and port.
-}
type Server
    = Server { id : Int, endpoint : InetEndpoint }


{-| Task to start a [`Server`](#Server) listening on the given host name and port, with the limits
and timeouts of [`defaultListenOptions`](#defaultListenOptions). The name is resolved as with
[`Socket.lookup`](Socket#lookup), and an address literal such as `"127.0.0.1"` or `"::1"` is used
as it is; the empty string listens on all interfaces. Port 0 lets the system pick a free port
([`endpoint`](#endpoint) tells which).

    Http.Server.listenOnHost "localhost" 8080

A name that cannot be resolved fails with [`errorIsHostNotFound`](#errorIsHostNotFound). A
listening server keeps the program running until it is closed with [`close`](#close).

This was `createServer`.

-}
listenOnHost : String -> Int -> Task Error Server
listenOnHost host port_ =
    kCreateServer host port_
        |> Task.map toServer
        |> Task.mapError toError


{-| The kernel's result: ( id, bound address text, bound port ).
-}
toServer : ( Int, String, Int ) -> Server
toServer ( id, address, port_ ) =
    Server
        { id = id
        , endpoint =
            { address =
                Socket.Address.fromString address
                    |> Maybe.withDefault (Socket.Address.any Socket.Address.IPv4)
            , port_ = port_
            }
        }


toError : ( String, String ) -> Error
toError ( code, message ) =
    Error { code = code, message = message }


{-| How to run a server, for [`listen`](#listen).

  - `address`, `port_`: where to listen. Port 0 lets the system pick a free port
    ([`endpoint`](#endpoint) tells which).
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
type alias ListenOptions =
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

    Http.Server.defaultListenOptions (Socket.Address.loopback Socket.Address.IPv4) 8080

-}
defaultListenOptions : Address -> Int -> ListenOptions
defaultListenOptions address port_ =
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


{-| Task to start a [`Server`](#Server) listening as the [`ListenOptions`](#ListenOptions) say.

Fails with an [`Error`](#Error): for example [`errorIsAddressInUse`](#errorIsAddressInUse) when the
port is taken, [`errorIsCertificateInvalid`](#errorIsCertificateInvalid) when the certificate or key
cannot be used, and `EINVAL` when `http2` is set without `tls`, and
with an `"ERR_SSL_"` code when the certificate or key cannot be used.

    let
        options =
            Http.Server.defaultListenOptions (Socket.Address.loopback Socket.Address.IPv4) 8443
    in
    Http.Server.listen
        { options | tls = Just { certificateChain = cert, privateKey = key, alpn = [] } }

-}
listen : ListenOptions -> Task Error Server
listen options =
    if options.http2 && options.tls == Nothing then
        Task.fail (Error { code = "EINVAL", message = "listen: http2 requires tls" })

    else
        kCreateServerWith
            ( ( Socket.Address.toString options.address, options.port_ )
            , ( options.http2, limit options.maxConnections )
            )
            (Maybe.map (\tls -> ( tls.certificateChain, tls.privateKey )) options.tls)
            ( ( options.keepAliveTimeout, options.headersTimeout, options.requestTimeout )
            , ( options.maxBodySize, options.maxHeaderSize, limit options.maxConcurrentStreams )
            )
            |> Task.map toServer
            |> Task.mapError toError


{-| A limit for the kernel: -1 is none.
-}
limit : Maybe Int -> Int
limit value =
    case value of
        Just n ->
            max 0 n

        Nothing ->
            -1


{-| The address and port a server listens on. For port 0 this is the port the system picked.
-}
endpoint : Server -> InetEndpoint
endpoint (Server s) =
    s.endpoint


{-| Stop a server gracefully, within 5 seconds: [`closeWithin`](#closeWithin) 5000.
-}
close : Server -> Task x ()
close =
    closeWithin 5000


{-| Stop a server gracefully, within the given number of milliseconds. The server stops accepting
connections at once (the port is free when the task completes) and closes its idle connections.
Requests that were received but not yet delivered are answered 503; requests already delivered can
still be answered (with `Connection: close`) until the deadline, when the remaining connections are
closed. WebSocket connections are not affected.

Closing a server twice is fine. A closed server no longer keeps the program running.

-}
closeWithin : Int -> Server -> Task x ()
closeWithin deadline (Server s) =
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
bodyAsJson : Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a
bodyAsJson decoder request =
    request
        |> bodyAsString
        |> Maybe.withDefault ""
        |> Json.Decode.decodeString decoder


{-| Get a string representation of the request, for example `"GET http://localhost:8080/"`.

Good for logging. This was `requestInfo`.

-}
requestToString : Request -> String
requestToString request =
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
[`Request`](#Request) and a fresh [`Response`](#Response) that answers it.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Http.Server.onRequest model.server GotRequest

-}
onRequest : Server -> (Request -> Response -> msg) -> Sub msg
onRequest (Server s) toMsg =
    subscription
        (OnRequest s.id
            (\( ( method, url ), ( headers, body ), ( key, flags, upgradeToken ) ) ->
                toMsg (toRequest method url headers body flags upgradeToken) (freshResponse key)
            )
        )


{-| Answer a WebSocket opening request (a [`Request`](#Request) whose `upgrade` is
`Just "websocket"`, over HTTP/1.1 or HTTP/2) instead of sending its
[`Response`](#Response): the result is a
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
rules 400 or 426 itself), exactly as for [`WebSocket.receiveUpgrade`](WebSocket#receiveUpgrade).
Requests the client sent before this one on the same connection are answered first: the `101`
follows their responses. Over TLS the result is a `wss` WebSocket.

Over HTTP/2 (RFC 8441: an extended `CONNECT` with `:protocol websocket`, which a server with
`http2` allows) the WebSocket runs on that one stream of the connection, next to the connection's
other requests and WebSockets: `accept` answers `200` and the stream carries the frames; the close
handshake ends the stream (`END_STREAM`) and an aborted WebSocket resets it (`CANCEL`). Such a
WebSocket counts against `maxConcurrentStreams` like any request, when it is set. Another
`:protocol` is answered `501` by the server itself.

The WebSocket does not belong to the server: [`close`](#close) leaves it open (over
HTTP/2, until the close deadline, which ends the connection it shares).

Fails with `EINVAL` when the request does not ask for a WebSocket, or was already answered (or
upgraded), and with `ECANCELED` when its connection is gone.

-}
upgradeRequest : Request -> Response -> Task Socket.Error WebSocket.Upgrade
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
freshResponse : Int -> Response
freshResponse key =
    Internal.Response
        { key = key
        , status = 200
        , headers = []
        , body = Internal.StringBody ""
        }



-- RESPONSES


{-| An HTTP response to a single request. You receive one from
[`onRequest`](#onRequest) together with the request it answers.
-}
type alias Response =
    Internal.Response


{-| Command to send an HTTP response.

The response is written with a `Content-Length` header and the connection is closed afterwards.
Send each response only once. An HTML body (see [`setBodyAsHtml`](#setBodyAsHtml)) is serialized
as it is sent.

-}
send : Response -> Cmd msg
send (Internal.Response r) =
    case r.body of
        HtmlBody node ->
            command (Respond (kRespondHtml r.key r.status (withHtmlContentType r.headers) (isDocument node) node))

        _ ->
            command (Respond (kRespond r.key r.status r.headers (bodyBytes r.body)))


bodyBytes : Body -> Bytes
bodyBytes body =
    case body of
        StringBody s ->
            kStringToUtf8 s

        BytesBody b ->
            b

        HtmlBody node ->
            kStringToUtf8 (Dom.toString node)


{-| Add `Content-Type: text/html; charset=utf-8` unless the response already has a
Content-Type (the name compared case-insensitively).
-}
withHtmlContentType : List ( String, List String ) -> List ( String, List String )
withHtmlContentType headers =
    if List.any (\( name, _ ) -> String.toLower name == "content-type") headers then
        headers

    else
        ( "Content-Type", [ "text/html; charset=utf-8" ] ) :: headers


{-| Whether the page gets `<!DOCTYPE html>`: its root, seen through `Html.map`, is an HTML
`html` element.
-}
isDocument : Dom.Node -> Bool
isDocument node =
    case node of
        Dom.Mapped _ inner ->
            isDocument inner

        Dom.Element Nothing tag _ _ ->
            String.toLower tag == "html"

        Dom.KeyedElement Nothing tag _ _ ->
            String.toLower tag == "html"

        _ ->
            False


{-| Set the HTTP status code of a response.

    response |> Http.Server.setStatus 404

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


{-| Set the body of the response to an HTML page or fragment built with
[elm/html](/packages/elm/html/latest/) (or `Svg`).

    response
        |> Http.Server.setBodyAsHtml
            (Html.node "html" [] [ Html.node "body" [] [ Html.text "Hello!" ] ])
        |> Http.Server.send

When the response is sent:

  - the HTML is serialized as [`Html.Dom.htmlToString`](Html-Dom#htmlToString) does, straight into the
    response (natively no `String` is built);
  - `<!DOCTYPE html>` is written first when the root element is `html`;
  - `Content-Type: text/html; charset=utf-8` is added unless the response already has a
    Content-Type header.

-}
setBodyAsHtml : VirtualDom.Node msg -> Response -> Response
setBodyAsHtml node (Internal.Response r) =
    Internal.Response { r | body = HtmlBody (Dom.fromHtml node) }



-- ERRORS


{-| An error from starting a server: the error code (an errno name such as `"EADDRINUSE"`, a
resolver code, or an `"ERR_SSL_"` code for a certificate or key that cannot be used) and a human
readable message. Use the `errorIs…` functions below to check for the common cases.

This replaces gren-node's `ServerError` constructor.

-}
type Error
    = Error { code : String, message : String }


{-| The error code, for example `"EADDRINUSE"`.
-}
errorCode : Error -> String
errorCode (Error e) =
    e.code


{-| A human readable description of the error: the code, `": "`, and a message.
-}
errorToString : Error -> String
errorToString (Error e) =
    e.code ++ ": " ++ e.message


codeIn : List String -> Error -> Bool
codeIn codes (Error e) =
    List.member e.code codes


{-| `True` if the port is already in use (`EADDRINUSE`).
-}
errorIsAddressInUse : Error -> Bool
errorIsAddressInUse =
    codeIn [ "EADDRINUSE" ]


{-| `True` if the address cannot be used here (`EADDRNOTAVAIL`, `EAFNOSUPPORT`): it does not belong
to this machine, or the system does not support its family.
-}
errorIsAddressNotAvailable : Error -> Bool
errorIsAddressNotAvailable =
    codeIn [ "EADDRNOTAVAIL", "EAFNOSUPPORT" ]


{-| `True` if the host name given to [`listenOnHost`](#listenOnHost) could not be resolved
(`ENOTFOUND`, `EAI_AGAIN`, `EAI_FAIL`).
-}
errorIsHostNotFound : Error -> Bool
errorIsHostNotFound =
    codeIn [ "ENOTFOUND", "EAI_AGAIN", "EAI_FAIL" ]


{-| `True` if the operating system refused to listen (`EACCES`, `EPERM`), for example on a
privileged port.
-}
errorIsPermissionDenied : Error -> Bool
errorIsPermissionDenied =
    codeIn [ "EACCES", "EPERM" ]


{-| `True` if the TLS certificate chain or private key cannot be used (an `"ERR_SSL_"` code).
-}
errorIsCertificateInvalid : Error -> Bool
errorIsCertificateInvalid (Error e) =
    String.startsWith "ERR_SSL_" e.code



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


type MyCmd msg
    = Respond (Task Never ())


cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Respond task) =
    Respond task


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


onEffects : Platform.Router msg Event -> List (MyCmd msg) -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router cmds subs state =
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
    List.reverse cmds
        |> List.map (\(Respond task) -> Process.spawn task)
        |> Task.sequence
        |> Task.andThen (\_ -> Task.sequence stopped)
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


kCreateServer : String -> Int -> Task ( String, String ) ( Int, String, Int )
kCreateServer =
    Eco.Kernel.HttpServer.createServer


kCreateServerWith :
    ( ( String, Int ), ( Bool, Int ) )
    -> Maybe ( String, String )
    -> ( ( Int, Int, Int ), ( Int, Int, Int ) )
    -> Task ( String, String ) ( Int, String, Int )
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


kRespond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
kRespond =
    Eco.Kernel.HttpServer.respond


kRespondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Dom.Node -> Task Never ()
kRespondHtml =
    Eco.Kernel.HttpServer.respondHtml


kStringToUtf8 : String -> Bytes
kStringToUtf8 =
    Eco.Kernel.Stream.stringToUtf8


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
