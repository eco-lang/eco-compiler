module WebSocket.Internal exposing
    ( WebSocket(..), Upgrade(..), Negotiated
    , UpgradeArg, OpenArg, toUpgrade, toWebSocket
    , handshakeError, handshakeErrorPrefix
    )

{-| The WebSocket handle types, defined here so that `Http.Server`, as well as `WebSocket`, can
make an `Upgrade`, while users see both types only through `WebSocket`'s aliases, which hide the
constructors. Internal; not exposed.

A WebSocket connection begins with an opening request, an HTTP request asking to switch the
connection, or over HTTP/2 one stream of it, over to the WebSocket protocol
(`WebSocket.Internal.Handshake` describes the exchange). On a server, the kernel puts that
connection or stream into a table of handshakes under a handshake id once
`WebSocket.receiveUpgrade` has read an opening request from it, or once
`Http.Server.upgradeRequest` has taken over an opening request that `Http.Server` delivered; on a
client, once the server's answer has been read. An _upgrade_ is an opening request held this way
that has not been answered yet, and the `Upgrade` carries its handshake id. Once the handshake
has succeeded, on a server by accepting the upgrade and on a client by checking the server's
answer, the kernel's `open` makes it a WebSocket, which it keeps under a new id in a separate
WebSocket table. A `WebSocket` carries that id, never the handshake's.

Both handles are built from tuples the kernels hand over: `UpgradeArg` and `OpenArg`, whose
endpoints are the `( kind, text, port )` tuples `Socket.Internal` calls EpTs, decoded with its
`toEndpoint`. The module also makes `ERR_WS_HANDSHAKE` errors, and holds the prefix that marks
one carrying an HTTP status, which `WebSocket` reads the status back from (`HandshakeRefused`), so
that the prefix is written down in one place.

`Message` and `StreamedMessage`, and the functions that turn them into the kernel's form and back,
are in `WebSocket` itself: `WebSocket` exposes `Message(..)` with its constructors, which an alias
of a type defined here could not do.

-}

import Socket.Address exposing (Endpoint)
import Socket.Internal


{-| A WebSocket connection that has been opened, as Elm holds it.

The one constructor, `WebSocket`, carries the connection's `id` in the kernel's WebSocket table;
the ids of the stream pairs behind its readable and its writable, which are two different pairs,
held as bare `Int`s from which `WebSocket` makes the `Stream` handles each time they are asked
for; the subprotocol and the permessage-deflate settings the handshake agreed on, `compression`
being `Nothing` when permessage-deflate was not agreed; and both endpoints.

`mode` is a phantom type parameter, meant to be `WebSocket.Whole` or `WebSocket.Streamed`; the
compiler accepts any type there. Nothing in the value records it, so nothing checks that it
matches the mode the kernel opened the connection in.

-}
type WebSocket mode
    = WebSocket
        { id : Int
        , readable : Int
        , writable : Int
        , protocol : Maybe String
        , compression : Maybe Negotiated
        , local : Endpoint
        , remote : Endpoint
        }


{-| The permessage-deflate settings the two ends of a connection have agreed on.

The same record is declared in `WebSocket.Internal.Handshake`, whose docstring says what the
fields mean, and as `WebSocket.Negotiated`. The three are interchangeable only because record
aliases are structural, so they must be kept identical.

-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| A server's received opening request that has not been answered yet, as Elm holds it.

The one constructor, `Upgrade`, carries the request's `id` in the kernel's table of handshakes,
which is what answering it names; its method, target and HTTP version (`"2"` over HTTP/2); its
headers; the expected accept; whether the request came over HTTP/2, as an extended `CONNECT`; and
the client's endpoint.

`headers` has one entry per header value, with the name in lower case, in the order the kernel
listed them. The _expected accept_ is the `Sec-WebSocket-Accept` value the request's key calls
for, which the answer accepting the request sends back over HTTP/1.1. It is `""` over HTTP/2,
even if the client sent a key, and when the request has no `Sec-WebSocket-Key`.

-}
type Upgrade
    = Upgrade
        { id : Int
        , method : String
        , target : String
        , version : String
        , headers : List ( String, String )
        , expectedAccept : String
        , isH2 : Bool
        , remote : Endpoint
        }


{-| The tuple a kernel hands over for a received opening request, the result of
`Eco.Kernel.WebSocket.readUpgrade` and `Eco.Kernel.HttpServer.takeUpgrade`:
`( id, ( method, target, version ), ( headers, isH2, remote ) )`, where `remote` is an EpT.

Each header is a name with a list of values. Both kernels send one value per entry, a repeated
header as several entries, but the type allows any number. `readUpgrade` always sends `isH2` as
`False`.

-}
type alias UpgradeArg =
    ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )


{-| The tuple `Eco.Kernel.WebSocket.open` hands over for a newly opened WebSocket:
`( id, ( readableId, writableId ), ( local, remote ) )`, where `local` and `remote` are EpTs.
-}
type alias OpenArg =
    ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )


{-| Builds an `Upgrade` from a kernel's `UpgradeArg`, where `acceptFor` turns a
`Sec-WebSocket-Key` value into the `Sec-WebSocket-Accept` value it calls for.

The headers are flattened into one entry per value, each name lower-cased, keeping their order.
The expected accept is `acceptFor` of the first `Sec-WebSocket-Key` value, trimmed, and `""` over
HTTP/2 or when there is no such header.

-}
toUpgrade : (String -> String) -> UpgradeArg -> Upgrade
toUpgrade acceptFor ( id, ( method, target, version ), ( headers, isH2, remote ) ) =
    let
        flat =
            List.concatMap (\( name, values ) -> List.map (\v -> ( String.toLower name, v )) values) headers

        key =
            flat
                |> List.filter (\( name, _ ) -> name == "sec-websocket-key")
                |> List.map (Tuple.second >> String.trim)
                |> List.head
    in
    Upgrade
        { id = id
        , method = method
        , target = target
        , version = version
        , headers = flat
        , expectedAccept =
            case ( isH2, key ) of
                ( False, Just k ) ->
                    acceptFor k

                _ ->
                    ""
        , isH2 = isH2
        , remote = Socket.Internal.toEndpoint remote
        }


{-| Builds a `WebSocket` from `Eco.Kernel.WebSocket.open`'s `OpenArg`, given the subprotocol and
the permessage-deflate settings the handshake agreed on.

The result can be given any `mode`; nothing here checks it against the mode the connection was
opened in.

-}
toWebSocket : Maybe String -> Maybe Negotiated -> OpenArg -> WebSocket mode
toWebSocket protocol compression ( id, ( readableId, writableId ), ( local, remote ) ) =
    WebSocket
        { id = id
        , readable = readableId
        , writable = writableId
        , protocol = protocol
        , compression = compression
        , local = Socket.Internal.toEndpoint local
        , remote = Socket.Internal.toEndpoint remote
        }


{-| The text an `ERR_WS_HANDSHAKE` message made by `handshakeError` starts with when it carries
an HTTP status, which is what `WebSocket` looks for to read the status back as `HandshakeRefused`.
-}
handshakeErrorPrefix : String
handshakeErrorPrefix =
    "status "


{-| Builds an `ERR_WS_HANDSHAKE` error whose message is `text`, or, given `Just n`, is
`"status <n>: <text>"`.

Not every `ERR_WS_HANDSHAKE` error is made here: the kernels make their own, whose messages do
not start with `handshakeErrorPrefix`.

-}
handshakeError : Maybe Int -> String -> Socket.Internal.Error
handshakeError status text =
    Socket.Internal.error "ERR_WS_HANDSHAKE"
        (case status of
            Just s ->
                handshakeErrorPrefix ++ String.fromInt s ++ ": " ++ text

            Nothing ->
                text
        )
