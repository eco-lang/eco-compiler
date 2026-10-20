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

{-| An HTTP server for an Elm program: requests arrive as subscription messages, and the program
answers each one by sending a response as a command.

[`listen`](#listen) or [`listenOnHost`](#listenOnHost) starts a [`Server`](#Server).
[`onRequest`](#onRequest) subscribes to its requests, and every [`Request`](#Request) arrives
together with a fresh [`Response`](#Response), which the program builds up and
[`send`](#send)s from its `update` function:

    GotRequest request response ->
        ( model
        , response
            |> Http.Server.setHeader "Content-Type" "text/html"
            |> Http.Server.setBody "<html>Hello there!</html>"
            |> Http.Server.send
        )

A response answers the one request it arrived with. It carries that request's _response key_,
the server's name for a request that is still waiting for its answer. The key is released when
the request is answered, when [`upgradeRequest`](#upgradeRequest) takes the request over, and
when the request's connection goes away. From then on, sending the response writes nothing, so a
request is answered at most once however often its response is sent.

The server speaks HTTP/1.0 and HTTP/1.1, and, when started with `http2` (which requires TLS),
HTTP/2 (see [`ListenOptions`](#ListenOptions)). Over HTTP/1 a connection is kept alive and serves one request
after another; requests a client sends ahead of their answers (pipelining) are handed to the
program one at a time, in order, each once the one before it has been answered. Over HTTP/2
several requests on one connection are handed over at once and answered independently.

The server checks every request against its limits and the HTTP rules before the program sees
it. A request that breaks them never arrives: the server answers it itself, with a status such
as 400, 413 or 431, or over HTTP/2 may reset its stream instead.

Starting a server fails with this module's own [`Error`](#Error). On the native backend under
Windows no server can be started (`listen` and `listenOnHost` fail with `ENOTSUP`), and an
`onRequest` subscription stops the program with a fatal error.


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


{-| An HTTP server that [`listen`](#listen) or [`listenOnHost`](#listenOnHost) started.

A `Server` stays usable after it has been closed: [`endpoint`](#endpoint) still answers, and
closing it again does nothing.

-}
type Server
    = Server { id : Int, endpoint : InetEndpoint }


{-| Starts a server listening on `host` and `port_`, with the limits and timeouts of
[`defaultListenOptions`](#defaultListenOptions), and without TLS.

    Http.Server.listenOnHost "localhost" 8080

An address literal such as `"127.0.0.1"` or `"::1"` is used as it is. A name is resolved, and the
server listens on one of its addresses; natively that is the first IPv4 address that can be used,
if there is one. The empty string listens on every interface: natively on `0.0.0.0`, so on IPv4
only, and on the JavaScript backend on Node's default, `::` where IPv6 is available. Port 0 lets
the system pick a free port, which [`endpoint`](#endpoint) reports.

A name that cannot be resolved fails with [`errorIsHostNotFound`](#errorIsHostNotFound). A
listening server keeps the program running until it is closed with [`close`](#close).

-}
listenOnHost : String -> Int -> Task Error Server
listenOnHost host port_ =
    kCreateServer host port_
        |> Task.map toServer
        |> Task.mapError toError


{-| Builds a `Server` from the kernel's `( id, bound address text, bound port )`. Address text
that does not parse becomes `0.0.0.0`.
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


{-| Builds an `Error` from the kernel's `( code, message )` pair.
-}
toError : ( String, String ) -> Error
toError ( code, message ) =
    Error { code = code, message = message }


{-| How to run a server: where it listens, whether it uses TLS and HTTP/2, and the limits it holds
clients to.

`port_` 0 lets the system pick a free port, which [`endpoint`](#endpoint) reports.

`tls` serves HTTPS (and so `wss` WebSockets) with the given certificate chain and key. Its `alpn`
field is not used: the server offers `h2` and `http/1.1` with `http2`, else `http/1.1`, and a
client that offers none of them is still served HTTP/1.1.

`http2` also serves HTTP/2 to clients that ask for it during the TLS handshake. It requires `tls`.
TLS 1.2 is then limited to the cipher suites HTTP/2 allows.

`maxConnections` is the most connections open at once. Natively, further clients wait in the
operating system's queue of pending connections until one closes; on the JavaScript backend Node
drops them.

`maxConcurrentStreams` is the most HTTP/2 requests, WebSockets included, in progress at once on one
connection, and is advertised to the client. Natively, requests the program has not answered yet
count even when the client has cancelled them, and at the limit the server processes nothing more
from that connection until the program answers one; on the JavaScript backend Node refuses the
requests over the limit. Without this limit, natively a client that keeps cancelling its requests
is held back only by a limit on cancellations (about 1000 at once, then 33 per second), so a
public server should set one.

For both of these limits `Nothing` means no limit, but `Just 0` or a negative value is a limit of
0, which serves nothing. A `maxConnections` of 0 natively accepts no connection, so clients wait
indefinitely, and on the JavaScript backend drops every one. A `maxConcurrentStreams` of 0 refuses
every HTTP/2 request.

`maxBodySize` and `maxHeaderSize` are in bytes. A request with a larger body is answered 413, and
one with a larger header block 431 (on the JavaScript backend over HTTP/2, a header block over
twice `maxHeaderSize` has its stream reset instead).

`keepAliveTimeout`, `headersTimeout` and `requestTimeout` are in milliseconds, and a value of 0 or
less is no timeout. `keepAliveTimeout` is how long an idle connection stays open between requests.
`headersTimeout` runs from the first byte of a request to the end of its headers and
`requestTimeout` to the end of its body; a request that takes longer is answered 408. Natively, a
new connection without TLS that sends nothing is closed after `headersTimeout`. Over HTTP/2 they
apply differently: natively `headersTimeout` limits only the wait for a new connection's first
bytes, and on the JavaScript backend none of the three applies. No timeout limits the program's
answer: the connection waits for it.

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


{-| Returns the options for plain HTTP on `address` and `port_`, with no connection or stream
limits, bodies up to 16 MiB, header blocks up to 64 KiB, a 5 second keep-alive timeout, a 60
second headers timeout and a 300 second request timeout.

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


{-| Starts a server as `options` say.

    let
        options =
            Http.Server.defaultListenOptions (Socket.Address.loopback Socket.Address.IPv4) 8443
    in
    Http.Server.listen
        { options | tls = Just { certificateChain = cert, privateKey = key, alpn = [] } }

Fails with an [`Error`](#Error): for example [`errorIsAddressInUse`](#errorIsAddressInUse) when
the port is taken, [`errorIsCertificateInvalid`](#errorIsCertificateInvalid) when the certificate
chain or key cannot be used, and `EINVAL` when `http2` is set without `tls`. A listening server
keeps the program running until it is closed with [`close`](#close).

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


{-| Returns a limit as the kernel takes it: -1 for `Nothing` (no limit), and `max 0 n` for
`Just n`, so that a value of 0 or less is a limit of 0.
-}
limit : Maybe Int -> Int
limit value =
    case value of
        Just n ->
            max 0 n

        Nothing ->
            -1


{-| Returns the address and port a server listens on. For port 0 this is the port the system
picked. An address the system reports as text that does not parse is given as `0.0.0.0`.
-}
endpoint : Server -> InetEndpoint
endpoint (Server s) =
    s.endpoint


{-| Stops a server gracefully, with [`closeWithin`](#closeWithin) and a deadline of 5 seconds.
-}
close : Server -> Task x ()
close =
    closeWithin 5000


{-| Stops a server gracefully, closing the connections still open after `deadline` milliseconds.

The server stops accepting connections at once (the port is free when the task completes) and
closes its idle connections. Requests held because nothing subscribed to them (see
[`onRequest`](#onRequest)) are answered 503. Requests already handed to the program can still be
answered until the deadline, over HTTP/1 with `Connection: close`; then the connections that remain
are closed. A request still being received when the server closes can still be handed to a
subscription. WebSockets made with [`upgradeRequest`](#upgradeRequest) stay open, except one over
HTTP/2, which shares its connection and ends with it at the deadline.

Closing a server twice is fine. A closed server no longer keeps the program running.

-}
closeWithin : Int -> Server -> Task x ()
closeWithin deadline (Server s) =
    kCloseServer s.id deadline
        |> Task.mapError never



-- REQUESTS


{-| An HTTP request a server has received.

`headers` maps each header name, spelled as the client sent it, to its value. Over HTTP/2 names
are always lower case, and over HTTP/1 they need not be, so look a header up by every spelling it
may have or compare names case-insensitively: names that differ in case are separate entries. When
a name is sent more than once with the same spelling, the last value wins. Over HTTP/2 the
pseudo-header fields (`:method`, `:path`, ...) are not included, and several `cookie` fields are
joined into one with `"; "`.

`body` is the complete request body.

`url` is the absolute URL of the request, made from the `Host` header (over HTTP/2 the
`:authority` field), or, without one, the host the server was started with (its address for
`listen`, `localhost` for `listenOnHost ""`) and its port, followed by the request target; a target
that is already an absolute URL is used as it is. When that text is not one `Url.fromString`
accepts, for example when the host is a bracketed IPv6 address, `url` has an empty host and path,
and its protocol is `Https` when the connection uses TLS and `Http` otherwise.

`upgrade` is the protocol the client asks to switch to, lower-cased, such as `Just "websocket"`:
the first protocol of the HTTP/1.1 `Upgrade` header when `Connection` also names `upgrade`
(natively, only for a request without a body), or HTTP/2's `:protocol`. Answer a WebSocket
request with [`upgradeRequest`](#upgradeRequest). Any response sent instead refuses the upgrade,
and over HTTP/1 the connection then closes.

-}
type alias Request =
    { headers : Dict String String
    , method : Method
    , body : Bytes
    , url : Url
    , version : HttpVersion
    , upgrade : Maybe String
    }


{-| The HTTP version a request was made with. `Http2` occurs only on a server started with `http2`.
-}
type HttpVersion
    = Http1_0
    | Http1_1
    | Http2


{-| The HTTP method of a request. `UNKNOWN` holds the name of any method not listed, as it was
received, for example `UNKNOWN "OPTIONS"`.
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


{-| Returns the name of a method, for example `"GET"`. `UNKNOWN name` gives `name`.
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


{-| Returns the `Method` named `s`, matched exactly, so that a name in another case is `UNKNOWN`.
-}
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


{-| Builds a `Request` from the pieces the kernel hands over.

`url` is absolute text; when `Url.fromString` rejects it, the result has an empty host and path
and the protocol that `flags` gives. `headers` holds one `( name, [ value ] )` entry per header
occurrence, in arrival order, so the last occurrence of a name wins. In `flags`, bits 0 and 1 are
the version (0 for 1.0, 1 for 1.1, 2 for 2) and bit 2 is set over TLS. An empty `upgradeToken`
is `Nothing`.

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


{-| Returns `dict` with `name` set to the last of `values`. An entry with no values changes
nothing.
-}
insertHeader : ( String, List String ) -> Dict String String -> Dict String String
insertHeader ( name, values ) dict =
    case List.head (List.reverse values) of
        Just value ->
            Dict.insert name value dict

        Nothing ->
            dict


{-| Returns the request body as a string, or `Nothing` if it is not valid UTF-8.
-}
bodyAsString : Request -> Maybe String
bodyAsString request =
    kUtf8ToString request.body


{-| Decodes the request body as JSON. A body that is not valid UTF-8 is decoded as the empty
string, so the decoder fails.
-}
bodyAsJson : Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a
bodyAsJson decoder request =
    request
        |> bodyAsString
        |> Maybe.withDefault ""
        |> Json.Decode.decodeString decoder


{-| Returns a one-line description of a request for logs: its method and URL, for example
`"GET http://localhost:8080/"`. An `UNKNOWN` method is written as `UNKNOWN(name)`.
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


{-| Creates a subscription to the requests `server` receives, each with a fresh
[`Response`](#Response) that answers it.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Http.Server.onRequest model.server GotRequest

Every subscription to one server receives every request, all with the same response, so only the
first of them to be sent answers it.

Requests that arrive while nothing subscribes to their server are held, and handed out oldest
first once a subscription appears. A server holds about `maxBodySize` × 4 bytes of them, and
always at least one. It answers 503 to a request beyond that, and to a request that arrives
after the server was closed with nothing subscribed.

-}
onRequest : Server -> (Request -> Response -> msg) -> Sub msg
onRequest (Server s) toMsg =
    subscription
        (OnRequest s.id
            (\( ( method, url ), ( headers, body ), ( key, flags, upgradeToken ) ) ->
                toMsg (toRequest method url headers body flags upgradeToken) (freshResponse key)
            )
        )


{-| Takes over a WebSocket opening request (a [`Request`](#Request) whose `upgrade` is
`Just "websocket"`, over HTTP/1.1 or HTTP/2) instead of answering it with its
[`Response`](#Response). The result is a [`WebSocket.Upgrade`](WebSocket#Upgrade), to be answered
with [`WebSocket.accept`](WebSocket#accept) or [`WebSocket.reject`](WebSocket#reject). The response
is used up: sending it later writes nothing.

    GotRequest request response ->
        if request.upgrade == Just "websocket" then
            ( model
            , Http.Server.upgradeRequest request response
                |> Task.andThen (WebSocket.accept WebSocket.defaultAcceptOptions)
                |> Task.attempt GotWebSocket
            )

        else
            ...

The opening request is checked by `WebSocket.accept`, which answers a request that breaks the
rules with 400 or 426 itself, as for [`WebSocket.receiveUpgrade`](WebSocket#receiveUpgrade). Over
HTTP/1.1 the requests the client sent before this one on the same connection are answered first,
so the `101` follows their responses.

Over HTTP/2 the request is an extended `CONNECT` with `:protocol` `websocket`, which a server with
`http2` allows; the server itself answers any other `:protocol` with 501. The WebSocket then runs
on that one stream of the connection, next to the connection's other requests and WebSockets:
`accept` answers `200` and the stream carries the frames, the close handshake ends the stream, and
an aborted WebSocket resets it. Such a WebSocket is one of the connection's streams for
`maxConcurrentStreams`.

The WebSocket does not belong to the server: [`close`](#close) leaves it open, except that over
HTTP/2 it ends at the close deadline with the connection it shares.

Fails with `EINVAL` when the request does not ask for a WebSocket; the response is then untouched
and can still be sent. Fails with `EINVAL` too when the request was already answered or taken
over, and with `EINVAL` or `ECANCELED` when its connection has gone away.

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


{-| Returns the response a request starts with, answering the request whose response key is
`key`: status 200, no headers and an empty body.
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


{-| An HTTP response being built for one request.

A response is obtained only from [`onRequest`](#onRequest), together with the request it answers,
and stays tied to that request: the functions below change its status, headers and body, but
never which request it answers.

-}
type alias Response =
    Internal.Response


{-| Creates a command that sends `response` to the request it answers.

The response is written with its status, its headers in order, one header line per value, and
its body:

  - A `Content-Length` header is always written, except with status 204 or 304, which send no
    body. The response's own `Content-Length`, `Connection` and `Transfer-Encoding` headers are
    left out, and so is a header whose name is empty or whose name or value holds a carriage
    return, line feed or NUL character. On the JavaScript backend a header Node considers invalid,
    such as one whose name contains a space, is left out as well. A `Date` header is added unless
    the response has one.
  - Over HTTP/2 header names are sent lower-cased, and other headers HTTP/2 forbids, such as
    `Upgrade` and `Keep-Alive`, are left out too. On the JavaScript backend, if a header HTTP/2
    allows only once, such as `Content-Type`, has several values (for example from two spellings
    of its name), every header of the response that has several values keeps only its last one.
  - The answer to a `HEAD` request has the headers only.
  - An HTML body (see [`setBodyAsHtml`](#setBodyAsHtml)) is serialized now.

Over HTTP/1 the connection then stays open for the client's next request, unless, for example,
the client asked to close it (`Connection: close`, or HTTP/1.0 without keep-alive), the response
has a `Connection: close` header, the server is closing, or the request asked to switch protocols
or was a `CONNECT`.

Sending a response whose request was already answered, was taken over by
[`upgradeRequest`](#upgradeRequest), or lost its connection writes nothing.

-}
send : Response -> Cmd msg
send (Internal.Response r) =
    case r.body of
        HtmlBody node ->
            command (Respond (kRespondHtml r.key r.status (withHtmlContentType r.headers) (isDocument node) node))

        _ ->
            command (Respond (kRespond r.key r.status r.headers (bodyBytes r.body)))


{-| Returns the bytes of a body: a string encoded as UTF-8, the bytes themselves, or the HTML
text of a node encoded as UTF-8. `send` hands an HTML body to the kernel instead, so it never
uses the last case.
-}
bodyBytes : Body -> Bytes
bodyBytes body =
    case body of
        StringBody s ->
            kStringToUtf8 s

        BytesBody b ->
            b

        HtmlBody node ->
            kStringToUtf8 (Dom.toString node)


{-| Returns `headers` with `Content-Type: text/html; charset=utf-8` added first, unless they
already have a `Content-Type` header, the name compared case-insensitively.
-}
withHtmlContentType : List ( String, List String ) -> List ( String, List String )
withHtmlContentType headers =
    if List.any (\( name, _ ) -> String.toLower name == "content-type") headers then
        headers

    else
        ( "Content-Type", [ "text/html; charset=utf-8" ] ) :: headers


{-| Returns whether a page gets `<!DOCTYPE html>`: whether its root, seen through `Html.map`, is
an HTML `html` element, the tag compared case-insensitively.
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


{-| Sets the HTTP status code of a response. A status below 200 or above 999 is sent as 500.

    response |> Http.Server.setStatus 404

-}
setStatus : Int -> Response -> Response
setStatus status (Internal.Response r) =
    Internal.Response { r | status = status }


{-| Sets a header on a response, replacing the values of the header with exactly this name and
keeping its place, or adding it last. Names are compared exactly, so `"content-type"` does not
replace `"Content-Type"`: the response then has both.
-}
setHeader : String -> String -> Response -> Response
setHeader key value (Internal.Response r) =
    Internal.Response { r | headers = updateHeader key (\_ -> [ value ]) r.headers }


{-| Adds a value to the header with exactly this name, after the values it already has, or adds
the header last. Use this for headers that may appear more than once, such as `Set-Cookie`.
-}
appendHeader : String -> String -> Response -> Response
appendHeader key value (Internal.Response r) =
    Internal.Response { r | headers = updateHeader key (\old -> old ++ [ value ]) r.headers }


{-| Returns `headers` with the values of the header named exactly `key` replaced by `f` of them,
in place, or, when there is no such header, with `( key, f [] )` added last.
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


{-| Sets the body of a response to a string; the same as [`setBodyAsString`](#setBodyAsString).
-}
setBody : String -> Response -> Response
setBody =
    setBodyAsString


{-| Sets the body of a response to a string, which is sent encoded as UTF-8. The backends differ
only for a lone surrogate: the JavaScript backend sends it as U+FFFD, the native one in its 3-byte
form, which is not valid UTF-8.
-}
setBodyAsString : String -> Response -> Response
setBodyAsString body (Internal.Response r) =
    Internal.Response { r | body = StringBody body }


{-| Sets the body of a response to bytes, which are sent as they are.
-}
setBodyAsBytes : Bytes -> Response -> Response
setBodyAsBytes body (Internal.Response r) =
    Internal.Response { r | body = BytesBody body }


{-| Sets the body of a response to an HTML page or fragment built with
[elm/html](/packages/elm/html/latest/) (or `Svg`).

    response
        |> Http.Server.setBodyAsHtml
            (Html.node "html" [] [ Html.node "body" [] [ Html.text "Hello!" ] ])
        |> Http.Server.send

When the response is sent:

  - the HTML is written as the text [`Html.Dom.htmlToString`](Html-Dom#htmlToString) gives,
    encoded as UTF-8, with the same lone-surrogate difference between the backends as
    [`setBodyAsString`](#setBodyAsString);
  - `<!DOCTYPE html>` is written first when the root, seen through `Html.map`, is an HTML `html`
    element;
  - `Content-Type: text/html; charset=utf-8` is added unless the response already has a
    `Content-Type` header, in any case.

-}
setBodyAsHtml : VirtualDom.Node msg -> Response -> Response
setBodyAsHtml node (Internal.Response r) =
    Internal.Response { r | body = HtmlBody (Dom.fromHtml node) }



-- ERRORS


{-| A failure to start a server, from [`listen`](#listen) or [`listenOnHost`](#listenOnHost).

Each error has a code and a human readable message. The code is, for example, an errno name such
as `"EADDRINUSE"`, a resolver code such as `"ENOTFOUND"`, or an `"ERR_SSL_"` code for a
certificate chain or key that cannot be used. The `errorIs…` functions below check for the common
cases.

This is a separate type from `Socket.Error`, which [`upgradeRequest`](#upgradeRequest) fails with.

-}
type Error
    = Error { code : String, message : String }


{-| Returns the error code, for example `"EADDRINUSE"`.
-}
errorCode : Error -> String
errorCode (Error e) =
    e.code


{-| Returns a human readable description of the error: the code, `": "`, and the message.
-}
errorToString : Error -> String
errorToString (Error e) =
    e.code ++ ": " ++ e.message


{-| Returns whether the error's code is one of `codes`.
-}
codeIn : List String -> Error -> Bool
codeIn codes (Error e) =
    List.member e.code codes


{-| Returns `True` when the port is already in use (`EADDRINUSE`).
-}
errorIsAddressInUse : Error -> Bool
errorIsAddressInUse =
    codeIn [ "EADDRINUSE" ]


{-| Returns `True` when the address cannot be used here (`EADDRNOTAVAIL`, `EAFNOSUPPORT`): it does
not belong to this machine, or the system does not support its family.
-}
errorIsAddressNotAvailable : Error -> Bool
errorIsAddressNotAvailable =
    codeIn [ "EADDRNOTAVAIL", "EAFNOSUPPORT" ]


{-| Returns `True` when the host name given to [`listenOnHost`](#listenOnHost) could not be
resolved (`ENOTFOUND`, `EAI_AGAIN`, `EAI_FAIL`).
-}
errorIsHostNotFound : Error -> Bool
errorIsHostNotFound =
    codeIn [ "ENOTFOUND", "EAI_AGAIN", "EAI_FAIL" ]


{-| Returns `True` when the operating system refused to listen (`EACCES`, `EPERM`), for example on
a privileged port.
-}
errorIsPermissionDenied : Error -> Bool
errorIsPermissionDenied =
    codeIn [ "EACCES", "EPERM" ]


{-| Returns `True` when the TLS certificate chain or private key cannot be used: the code starts
with `"ERR_SSL_"`. This is not what `Socket.errorIsCertificateInvalid` checks, which is whether the
other end's certificate failed verification.
-}
errorIsCertificateInvalid : Error -> Bool
errorIsCertificateInvalid (Error e) =
    String.startsWith "ERR_SSL_" e.code



-- EFFECT MANAGER
--
-- On the native backend the C++ manager registered as "Http.Server"
-- (src/eco-system/HttpServer/HttpServerManager.{hpp,cpp}) takes the place of the
-- Elm functions below, and mirrors the constructor layouts of both MyCmd and
-- MySub: keep them in sync. The JS backend runs the Elm functions. There, every
-- server with subscribers has one listener process, which passes each request to
-- the manager with Platform.sendToSelf, and the manager hands it to every tagger
-- of that server. A request that arrives after the server's last subscription went
-- away goes back to the kernel to be held (kHoldRequest).


{-| A command of this module. `Respond` carries the kernel task that writes one response.
-}
type MyCmd msg
    = Respond (Task Never ())


{-| Returns the command unchanged: a response produces no message.
-}
cmdMap : (a -> b) -> MyCmd a -> MyCmd b
cmdMap _ (Respond task) =
    Respond task


{-| A subscription of this module. `OnRequest` carries a server id and the tagger that turns the
kernel's tuple for one of its requests into a message.
-}
type MySub msg
    = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) ) -> msg)


{-| Applies `f` to every message a subscription produces.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnRequest id tagger) =
    OnRequest id (tagger >> f)


{-| A request as the kernel hands it over:
`( ( method, absolute URL ), ( headers, body ), ( response key, flags, upgrade token ) )`, with
the headers, flags and token as `toRequest` reads them.
-}
type alias RequestArg =
    ( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) )


{-| The JS manager's state: for each server with subscribers, its taggers in declaration order
and the process running its listener.
-}
type alias State msg =
    Dict Int (ServerListeners msg)


{-| One server's entry in the `State`.
-}
type alias ServerListeners msg =
    { taggers : List (RequestArg -> msg)
    , listener : Process.Id
    }


{-| A self-message of the JS manager. `Incoming` carries a server id and a request its listener
received.
-}
type Event
    = Incoming Int RequestArg


{-| The JS manager's state before any subscription: no servers.
-}
init : Task Never (State msg)
init =
    Task.succeed Dict.empty


{-| Spawns the task of every command, in declaration order, kills the listeners of servers that
have no subscription any more, starts one for each newly subscribed server, and returns the new state: each
subscribed server's taggers and listener.
-}
onEffects : Platform.Router msg Event -> List (MyCmd msg) -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router cmds subs state =
    let
        -- elm/core hands effects over newest first; reversing gives declaration order, as natively.
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


{-| Hands a request to every tagger of its server, in declaration order, or, when the server has
no subscription any more, gives it back to the kernel to be held.
-}
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
-- Each annotation fixes the argument and result shapes that both implementations of
-- Eco.Kernel.HttpServer (C++ and JS) rely on.


{-| Starts a server on a host name and port with the default limits. Succeeds with
`( id, bound address text, bound port )`, fails with `( code, message )`.
-}
kCreateServer : String -> Int -> Task ( String, String ) ( Int, String, Int )
kCreateServer =
    Eco.Kernel.HttpServer.createServer


{-| Starts a server from `( ( address text, port ), ( http2, maxConnections ) )`, the TLS
certificate chain and key, and
`( ( keepAliveTimeout, headersTimeout, requestTimeout ), ( maxBodySize, maxHeaderSize, maxConcurrentStreams ) )`,
with -1 for no limit. Results as for `kCreateServer`.
-}
kCreateServerWith :
    ( ( String, Int ), ( Bool, Int ) )
    -> Maybe ( String, String )
    -> ( ( Int, Int, Int ), ( Int, Int, Int ) )
    -> Task ( String, String ) ( Int, String, Int )
kCreateServerWith =
    Eco.Kernel.HttpServer.createServerWith


{-| Closes a server, given its id and the deadline in milliseconds.
-}
kCloseServer : Int -> Int -> Task Never ()
kCloseServer =
    Eco.Kernel.HttpServer.closeServer


{-| Takes over the upgrade request with a response key, releasing the key, and succeeds with the
opening request as a WebSocket handshake.
-}
kTakeUpgrade : Int -> Task ( String, String ) WebSocket.Internal.UpgradeArg
kTakeUpgrade =
    Eco.Kernel.HttpServer.takeUpgrade


{-| Returns the `Sec-WebSocket-Accept` value that a `Sec-WebSocket-Key` value calls for.
-}
kAcceptFor : String -> String
kAcceptFor =
    Eco.Kernel.WebSocket.acceptFor


{-| Answers the request with a response key, given the status, the headers and the body. Completes
at once, writing nothing, when the key has been released.
-}
kRespond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
kRespond =
    Eco.Kernel.HttpServer.respond


{-| Answers like `kRespond`, with the body serialized from a node, after `<!DOCTYPE html>` when
the `Bool` is `True`.
-}
kRespondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Dom.Node -> Task Never ()
kRespondHtml =
    Eco.Kernel.HttpServer.respondHtml


{-| Returns a string encoded as UTF-8.
-}
kStringToUtf8 : String -> Bytes
kStringToUtf8 =
    Eco.Kernel.Stream.stringToUtf8


{-| Returns bytes decoded as UTF-8, or `Nothing` if they are not valid UTF-8.
-}
kUtf8ToString : Bytes -> Maybe String
kUtf8ToString =
    Eco.Kernel.Stream.utf8ToString



-- JS-only kernels, used by the effect-manager bodies above (the native backend drops those
-- bodies, so these have no C++ counterpart).


{-| Returns a task that never completes: while it runs, every request of a server, first those held
so far, is passed to the function given. Killing its process detaches it, and later requests are
held again.
-}
kAttachRequestListener : Int -> (RequestArg -> Task Never ()) -> Task Never ()
kAttachRequestListener =
    Eco.Kernel.HttpServer.attachRequestListener


{-| Gives a request, by server id and response key, back to the kernel to be held until a
listener attaches.
-}
kHoldRequest : Int -> Int -> Task Never ()
kHoldRequest =
    Eco.Kernel.HttpServer.holdRequest
