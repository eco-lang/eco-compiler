effect module WebSocket where { subscription = MySub } exposing
    ( WebSocket, Whole, Streamed, Message(..), StreamedMessage(..)
    , readable, streamedReadable, writable, sendText, sendBinary
    , protocol, compression, Negotiated, localEndpoint, remoteEndpoint
    , onMessage, onClose, ping, close, closed
    , CloseCode(..), CloseInfo, Heartbeat
    , ConnectOptions, ClientCompression, defaultConnectOptions, connect, connectStreamed
    , Upgrade, upgradeRequest, upgradeTarget, upgradeHeaders, upgradeProtocols, upgradeOrigin
    , upgradeRemote, AcceptOptions, ServerCompression, defaultAcceptOptions
    , accept, acceptStreamed, reject
    , errorIsHandshakeFailed, handshakeStatus
    )

{-| WebSockets (RFC 6455): message-based, full-duplex connections, as a client and as a server.

A client [`connect`](#connect)s to a `ws://` or `wss://` URL. A server receives an opening request
as an [`Upgrade`](#Upgrade), either on a [`Socket.Connection`](Socket#Connection) it accepted
([`upgradeRequest`](#upgradeRequest)) or from an HTTP server
([`Http.Server.upgradeRequest`](Http-Server#upgradeRequest)), and answers it with
[`accept`](#accept) or [`reject`](#reject).

    WebSocket.connect (WebSocket.defaultConnectOptions "wss://example.com/chat")
        |> Task.andThen
            (\ws ->
                Stream.write (WebSocket.Text "hello") (WebSocket.writable ws)
                    |> Task.mapError (\_ -> ...)
            )

Several modules define functions such as `close`, `accept` and `readable`, so import this module
qualified:

    import WebSocket

**Messages.** Text and binary [`Message`](#Message)s arrive in order on [`readable`](#readable),
or through [`onMessage`](#onMessage); write them to [`writable`](#writable). A message is always
delivered whole, up to `maxMessageSize`. To send or receive messages too large to hold in memory,
use the streamed mode ([`connectStreamed`](#connectStreamed), [`acceptStreamed`](#acceptStreamed)):
then every message is a stream of its own ([`StreamedMessage`](#StreamedMessage)). A streamed
message must be read to the end (`Closed`) or cancelled: the connection delivers nothing else until
it is, so a message that is dropped unread stalls the connection. [`sendText`](#sendText) and
[`sendBinary`](#sendBinary) send a message from a stream in either mode.

**Liveness.** Both ends send a ping every 30 seconds by default and close the connection when the
pong does not come within 30 seconds ([`Heartbeat`](#Heartbeat)); pings from the peer are always
answered.

**Compression.** permessage-deflate (RFC 7692) is offered by clients and accepted by servers by
default, without context takeover: each message is compressed on its own, which keeps the memory per
connection small (the compression state is reset after every message). Context takeover
(`contextTakeover = True` on both sides) compresses better but keeps about 300 KB of compression
state per connection. Messages shorter than `threshold` are sent uncompressed; streamed messages are
always compressed. [`compression`](#compression) tells what was agreed. Do not mix secrets and
attacker-controlled data in one compressed connection (CRIME/BREACH).

**Differences from browsers.** A client opens one connection per [`connect`](#connect), even to a
host it is already connecting to (RFC 6455 §4.1 asks clients to queue them); redirects and proxies
are not followed.


## Connections

@docs WebSocket, Whole, Streamed, Message, StreamedMessage
@docs readable, streamedReadable, writable, sendText, sendBinary
@docs protocol, compression, Negotiated, localEndpoint, remoteEndpoint


## Events and closing

@docs onMessage, onClose, ping, close, closed
@docs CloseCode, CloseInfo, Heartbeat


## Clients

@docs ConnectOptions, ClientCompression, defaultConnectOptions, connect, connectStreamed


## Servers

@docs Upgrade, upgradeRequest, upgradeTarget, upgradeHeaders, upgradeProtocols, upgradeOrigin
@docs upgradeRemote, AcceptOptions, ServerCompression, defaultAcceptOptions
@docs accept, acceptStreamed, reject


## Errors

@docs errorIsHandshakeFailed, handshakeStatus

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict exposing (Dict)
import Eco.Kernel.WebSocket
import Platform
import Process
import Socket
import Socket.Address as Address exposing (Endpoint)
import Socket.Internal
import Socket.Tls
import Stream
import Stream.Internal
import Task exposing (Task)
import WebSocket.Internal as Internal
import WebSocket.Internal.Handshake as Handshake



-- CONNECTIONS


{-| An open WebSocket connection. `mode` is [`Whole`](#Whole) when every message arrives in one
piece, [`Streamed`](#Streamed) when every message is a stream.
-}
type alias WebSocket mode =
    Internal.WebSocket mode


{-| The mode of a connection whose messages arrive whole (no values: only used in types).
-}
type Whole
    = Whole Never


{-| The mode of a connection whose messages arrive as streams (no values: only used in types).
-}
type Streamed
    = Streamed Never


{-| A message: UTF-8 text or binary data. Both kinds can be sent and received on one connection,
in any order.
-}
type Message
    = Text String
    | Binary Bytes


{-| A message received in the streamed mode: its content arrives as a stream, chunk by chunk, as
the peer sends it (decompressed, and for text checked as UTF-8: invalid text fails the connection
with `InvalidData`). A text message's chunks are always whole characters.

Read it to `Closed` (or cancel it with `Stream.cancelReadable`, which skips the rest of the
message) before the next message can arrive. When the connection closes or fails in the middle of
a message, its stream fails with `Cancelled`.

-}
type StreamedMessage
    = StreamedText (Stream.Readable String)
    | StreamedBinary (Stream.Readable Bytes)


{-| The messages the peer sends, in order.

The readable is `Closed` once the connection closed cleanly (both sides exchanged Close frames);
when it ends otherwise, reads fail with `Cancelled` and a reason such as
`"ERR_WS_PROTOCOL: <details>"`. Use [`closed`](#closed) for the close code and reason.

While the connection has an [`onMessage`](#onMessage) subscription, messages go to the
subscription instead and `Stream.read` fails with `Locked`.

-}
readable : WebSocket Whole -> Stream.Readable Message
readable (Internal.WebSocket ws) =
    Stream.Internal.Readable ws.readable


{-| The messages of a streamed connection, each a [`StreamedMessage`](#StreamedMessage). Closing
and errors behave as for [`readable`](#readable).
-}
streamedReadable : WebSocket Streamed -> Stream.Readable StreamedMessage
streamedReadable (Internal.WebSocket ws) =
    Stream.Internal.Readable ws.readable


{-| Send messages: each value written is one message. Closing the writable with
`Stream.closeWritable` closes the connection with `Normal` and no reason.
-}
writable : WebSocket mode -> Stream.Writable Message
writable (Internal.WebSocket ws) =
    Stream.Internal.Writable ws.writable


{-| Send one text message whose content is read from a stream, as it arrives: for messages too
large to build in memory. The task completes when the stream ended and the message was sent.

Messages written to [`writable`](#writable) meanwhile, and other streamed messages, are sent after
it (pings and pongs are not held up). An empty stream sends an empty message. Each chunk is sent
as it arrives (compressed, when the connection uses compression), so the peer receives the message
in pieces it puts back together, unless it reads it streamed too.

If the stream fails after part of the message was sent, the message cannot be completed: the
connection fails with `InternalError`. A stream that fails before anything was sent just sends
nothing.

-}
sendText : Stream.Readable String -> WebSocket mode -> Task Socket.Error ()
sendText =
    sendStream 1


{-| Send one binary message whose content is read from a stream; as [`sendText`](#sendText).
-}
sendBinary : Stream.Readable Bytes -> WebSocket mode -> Task Socket.Error ()
sendBinary =
    sendStream 2


sendStream : Int -> Stream.Readable a -> WebSocket mode -> Task Socket.Error ()
sendStream kind source (Internal.WebSocket ws) =
    kOpenOutgoing ws.id kind
        |> Task.mapError Socket.Internal.toError
        |> Task.andThen
            (\sink ->
                Stream.pipeTo (Stream.Internal.Writable sink) source
                    |> Task.onError
                        (\error ->
                            -- A pipe that never started (a locked source) leaves the outgoing
                            -- stream open: drop it, or it would hold up later messages.
                            Stream.cancelWritable "sendText: the stream failed" (Stream.Internal.Writable sink)
                                |> Task.onError (\_ -> Task.succeed ())
                                |> Task.andThen (\_ -> Task.fail (streamError error))
                        )
            )


streamError : Stream.Error -> Socket.Error
streamError error =
    case error of
        Stream.Cancelled reason ->
            Socket.Internal.Error { code = "ECANCELED", message = reason }

        Stream.Closed ->
            Socket.Internal.Error { code = "ECANCELED", message = "socket closed" }

        Stream.Locked ->
            Socket.Internal.Error { code = "EBUSY", message = "the stream is locked" }


{-| The subprotocol the handshake agreed on (`Sec-WebSocket-Protocol`), if any.
-}
protocol : WebSocket mode -> Maybe String
protocol (Internal.WebSocket ws) =
    ws.protocol


{-| The permessage-deflate parameters the handshake agreed on, or `Nothing` when messages are
not compressed.
-}
compression : WebSocket mode -> Maybe Negotiated
compression (Internal.WebSocket ws) =
    ws.compression


{-| Negotiated permessage-deflate parameters (RFC 7692): whether each side resets its compression
state after every message (no context takeover), and each side's LZ77 window size in bits (8 to
15).
-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| This end of the connection.
-}
localEndpoint : WebSocket mode -> Endpoint
localEndpoint (Internal.WebSocket ws) =
    ws.local


{-| The peer's end of the connection.
-}
remoteEndpoint : WebSocket mode -> Endpoint
remoteEndpoint (Internal.WebSocket ws) =
    ws.remote



-- EVENTS AND CLOSING


{-| Subscribe to the messages of a connection.

While a connection has subscribers, every message goes to all of them, in subscription order, and
is not left on [`readable`](#readable) (which then fails `Locked`). Without subscribers, messages
wait on the readable. A subscription made while a `Stream.read` is waiting starts once that read
completes.

A connection with an `onMessage` subscription keeps the program running.

-}
onMessage : WebSocket Whole -> (Message -> msg) -> Sub msg
onMessage (Internal.WebSocket ws) toMsg =
    subscription (OnMessage ws.id (\arg -> toMsg (fromWire arg)))


{-| Subscribe to the end of a connection: the [`CloseInfo`](#CloseInfo) arrives once. When the
connection ended before anyone subscribed, the first subscription receives it.
-}
onClose : WebSocket mode -> (CloseInfo -> msg) -> Sub msg
onClose (Internal.WebSocket ws) toMsg =
    subscription (OnClose ws.id (\arg -> toMsg (toCloseInfo arg)))


{-| Send a ping and wait for its pong: the round trip time in milliseconds. Fails with
`ECANCELED` when the connection closes first and `ETIMEDOUT` after the heartbeat timeout.
-}
ping : WebSocket mode -> Task Socket.Error Int
ping (Internal.WebSocket ws) =
    kPing ws.id
        |> Task.mapError Socket.Internal.toError


{-| Start the closing handshake with a code and a reason. The reason is cut to 123 bytes (of
UTF-8, at a character boundary). Messages that arrive afterwards are dropped; the connection is
gone once the peer answered (or after 30 seconds).

Fails with `EINVAL` for a code that cannot be sent: only 1000–1003, 1007–1014 and 3000–4999 can
(`NoStatus` and `Abnormal` describe a received close only). Closing twice is fine.

-}
close : CloseCode -> String -> WebSocket mode -> Task Socket.Error ()
close code reason (Internal.WebSocket ws) =
    let
        n =
            closeCodeToInt code
    in
    if isSendable n then
        kClose ws.id n (truncateUtf8 123 reason)
            |> Task.mapError never

    else
        Task.fail
            (Socket.Internal.Error
                { code = "EINVAL"
                , message = "close: the close code " ++ String.fromInt n ++ " cannot be sent"
                }
            )


{-| Wait until the connection is gone, then get how it ended. A connection that ends without a
Close frame from the peer reports `Abnormal` and `clean = False`.
-}
closed : WebSocket mode -> Task x CloseInfo
closed (Internal.WebSocket ws) =
    kClosed ws.id
        |> Task.map toCloseInfo
        |> Task.mapError never


{-| The close codes of RFC 6455 §7.4.

  - `Normal` (1000), `GoingAway` (1001), `ProtocolError` (1002), `UnsupportedData` (1003),
    `InvalidData` (1007), `PolicyViolation` (1008), `MessageTooBig` (1009),
    `MandatoryExtension` (1010), `InternalError` (1011);
  - `NoStatus` (1005): the peer's Close frame had no code; `Abnormal` (1006): the connection
    ended without a Close frame. These two are never sent.
  - `Other n`: any other code, for example an application's code from 4000 to 4999.

-}
type CloseCode
    = Normal
    | GoingAway
    | ProtocolError
    | UnsupportedData
    | NoStatus
    | Abnormal
    | InvalidData
    | PolicyViolation
    | MessageTooBig
    | MandatoryExtension
    | InternalError
    | Other Int


{-| How a connection ended: the close code and reason (from the peer's Close frame, or ours when
we failed the connection), and whether both sides exchanged Close frames.
-}
type alias CloseInfo =
    { code : CloseCode
    , reason : String
    , clean : Bool
    }


{-| Liveness checking, in milliseconds: when nothing arrived for `interval`, send a ping; when
still nothing arrived after another `timeout`, the connection is closed (with `GoingAway`) and
reported `Abnormal`. Any data received counts, not only pongs.
-}
type alias Heartbeat =
    { interval : Int
    , timeout : Int
    }


closeCodeToInt : CloseCode -> Int
closeCodeToInt code =
    case code of
        Normal ->
            1000

        GoingAway ->
            1001

        ProtocolError ->
            1002

        UnsupportedData ->
            1003

        NoStatus ->
            1005

        Abnormal ->
            1006

        InvalidData ->
            1007

        PolicyViolation ->
            1008

        MessageTooBig ->
            1009

        MandatoryExtension ->
            1010

        InternalError ->
            1011

        Other n ->
            n


intToCloseCode : Int -> CloseCode
intToCloseCode n =
    case n of
        1000 ->
            Normal

        1001 ->
            GoingAway

        1002 ->
            ProtocolError

        1003 ->
            UnsupportedData

        1005 ->
            NoStatus

        1006 ->
            Abnormal

        1007 ->
            InvalidData

        1008 ->
            PolicyViolation

        1009 ->
            MessageTooBig

        1010 ->
            MandatoryExtension

        1011 ->
            InternalError

        _ ->
            Other n


isSendable : Int -> Bool
isSendable n =
    (n >= 1000 && n <= 1003) || (n >= 1007 && n <= 1014) || (n >= 3000 && n <= 4999)


{-| The longest prefix of `text` whose UTF-8 encoding has at most `limit` bytes.
-}
truncateUtf8 : Int -> String -> String
truncateUtf8 limit text =
    let
        step c ( size, acc ) =
            let
                code =
                    Char.toCode c

                width =
                    if code < 0x80 then
                        1

                    else if code < 0x0800 then
                        2

                    else if code < 0x00010000 then
                        3

                    else
                        4
            in
            if size + width > limit then
                ( limit + 1, acc )

            else
                ( size + width, c :: acc )
    in
    String.foldl step ( 0, [] ) text
        |> Tuple.second
        |> List.reverse
        |> String.fromList


toCloseInfo : ( Int, String, Bool ) -> CloseInfo
toCloseInfo ( code, reason, clean ) =
    { code = intToCloseCode code, reason = reason, clean = clean }



-- CLIENTS


{-| How to connect.

  - `url`: `ws://host[:port]/path?query` or `wss://...` (TLS). IPv6 addresses are bracketed;
    a zone is written `%25` (`ws://[fe80::1%25eth0]/`).
  - `headers`: extra request headers, such as `Origin` or `Authorization`. Headers the handshake
    sets itself (`Host`, `Upgrade`, `Connection`, `Sec-WebSocket-*`) are not allowed.
  - `protocols`: the subprotocols to offer, in order of preference ([`protocol`](#protocol) tells
    which one the server chose).
  - `verification`: which server certificates `wss` accepts.
  - `timeout`: the time allowed for the whole handshake (connecting, TLS and the HTTP exchange; the
    name lookup comes first and is not limited), in milliseconds.
  - `maxMessageSize`: the largest message accepted, in bytes (after decompression); a larger one
    closes the connection with `MessageTooBig`. Streamed connections do not limit messages.
  - `heartbeat`: see [`Heartbeat`](#Heartbeat); `Nothing` turns it off.
  - `compression`: the permessage-deflate offer, or `Nothing` to offer none.
  - `http2`: try a WebSocket over HTTP/2 (RFC 8441) first, for `wss` URLs (`ws` always uses
    HTTP/1.1): the TLS handshake offers `h2`; when the server chooses it and its settings allow
    WebSockets (`SETTINGS_ENABLE_CONNECT_PROTOCOL`), the WebSocket runs on one stream of an HTTP/2
    connection of its own. A server that chooses HTTP/1.1 gets the usual HTTP/1.1 handshake on the
    same connection; an HTTP/2 server without WebSockets is left (`GOAWAY`) and dialed again over
    HTTP/1.1, within the same `timeout`. Frames, masking and the close handshake are the same either
    way.

-}
type alias ConnectOptions =
    { url : String
    , headers : List ( String, String )
    , protocols : List String
    , verification : Socket.Tls.Verification
    , timeout : Maybe Int
    , maxMessageSize : Int
    , heartbeat : Maybe Heartbeat
    , compression : Maybe ClientCompression
    , http2 : Bool
    }


{-| What a client offers for permessage-deflate.

  - `clientMaxWindowBits`: `Just Nothing` tells the server it may limit our window
    (`client_max_window_bits` without a value); `Just (Just n)` limits our window to `n` bits
    (8 to 15); `Nothing` says nothing.
  - `serverMaxWindowBits`: ask the server to use at most this window.
  - `contextTakeover`: `False` (the default) offers `client_no_context_takeover` and
    `server_no_context_takeover`: every message is compressed on its own.
  - `threshold`: messages shorter than this many bytes are sent uncompressed.

-}
type alias ClientCompression =
    { clientMaxWindowBits : Maybe (Maybe Int)
    , serverMaxWindowBits : Maybe Int
    , contextTakeover : Bool
    , threshold : Int
    }


{-| Options for a URL: no extra headers or protocols, the system's certificate authorities, a 30
second timeout, messages up to 16 MiB, the default heartbeat (30 s / 30 s), permessage-deflate
without context takeover (threshold 64 bytes), and HTTP/1.1.
-}
defaultConnectOptions : String -> ConnectOptions
defaultConnectOptions url =
    { url = url
    , headers = []
    , protocols = []
    , verification = Socket.Tls.SystemCertificates
    , timeout = Just 30000
    , maxMessageSize = 16 * 1024 * 1024
    , heartbeat = Just defaultHeartbeat
    , compression =
        Just
            { clientMaxWindowBits = Just Nothing
            , serverMaxWindowBits = Nothing
            , contextTakeover = False
            , threshold = 64
            }
    , http2 = False
    }


defaultHeartbeat : Heartbeat
defaultHeartbeat =
    { interval = 30000, timeout = 30000 }


{-| Open a WebSocket connection. The host name is looked up first, then each of its addresses is
tried in order.

Fails with `EINVAL` for an invalid URL or header, the usual socket and TLS errors, and
`ERR_WS_HANDSHAKE` ([`errorIsHandshakeFailed`](#errorIsHandshakeFailed)) when the server does not
accept the connection: [`handshakeStatus`](#handshakeStatus) then tells the HTTP status it
answered, if any.

-}
connect : ConnectOptions -> Task Socket.Error (WebSocket Whole)
connect =
    connectWith 1 fromWire


{-| Open a WebSocket connection in the streamed mode; as [`connect`](#connect).
-}
connectStreamed : ConnectOptions -> Task Socket.Error (WebSocket Streamed)
connectStreamed =
    connectWith 2 fromWireStreamed


connectWith : Int -> (( Int, String, Bytes ) -> a) -> ConnectOptions -> Task Socket.Error (WebSocket mode)
connectWith mode decode options =
    case Handshake.parseUrl options.url of
        Err text ->
            Task.fail (einval text)

        Ok url ->
            kHandshakeKey
                |> Task.mapError never
                |> Task.andThen
                    (\( key, expectedAccept ) ->
                        case
                            Handshake.requestHeaders
                                { host = Handshake.hostHeader url
                                , key = key
                                , protocols = options.protocols
                                , extensions = Maybe.map Handshake.clientOffer (offeredCompression options)
                                , headers = options.headers
                                }
                        of
                            Err text ->
                                Task.fail (einval text)

                            Ok headers ->
                                addressesOf url.host
                                    |> Task.andThen (dial mode decode options url expectedAccept headers)
                    )


{-| The permessage-deflate offer sent (plans/eco-system-websockets.md §3.7, Appendix D.7).
-}
offeredCompression : ConnectOptions -> Maybe ClientCompression
offeredCompression options =
    options.compression


addressesOf : Handshake.Host -> Task Socket.Error (List String)
addressesOf host =
    case host of
        Handshake.Literal address ->
            Task.succeed [ Address.toString address ]

        Handshake.Name name ->
            Socket.lookup name
                |> Task.map (List.map Address.toString)


dial :
    Int
    -> (( Int, String, Bytes ) -> a)
    -> ConnectOptions
    -> Handshake.Url
    -> String
    -> List ( String, String )
    -> List String
    -> Task Socket.Error (WebSocket mode)
dial mode decode options url expectedAccept headers addresses =
    let
        verification =
            case options.verification of
                Socket.Tls.SystemCertificates ->
                    ( 0, "" )

                Socket.Tls.TrustedCertificates pem ->
                    ( 1, pem )

                Socket.Tls.NoVerification ->
                    ( 2, "" )
    in
    kDial
        ( addresses, url.port_, Socket.Internal.connectTimeoutMs options.timeout )
        ( ( url.secure, Handshake.serverName url ), verification, ( options.http2 && url.secure, False ) )
        ( url.target, headers )
        |> Task.mapError Socket.Internal.toError
        |> Task.andThen
            (\( hsId, ( status, isH2 ), responseHeaders ) ->
                let
                    -- An HTTP/2 handshake answers 2xx, an HTTP/1.1 one 101 (Appendix D.2); the
                    -- kernel says which one it used.
                    checked =
                        Handshake.checkResponse
                            { expectedAccept = expectedAccept, protocols = options.protocols, isH2 = isH2 }
                            status
                            (flatten responseHeaders)
                            |> Result.mapError (\( st, text ) -> Internal.handshakeError st text)
                            |> Result.andThen
                                (\r ->
                                    Handshake.negotiateClient (offeredCompression options) r.extensions
                                        |> Result.map (\negotiated -> ( r.protocol, negotiated ))
                                        |> Result.mapError (Internal.handshakeError Nothing)
                                )
                in
                case checked of
                    Err error ->
                        -- The kernel still holds the connection: release it.
                        kAbandon hsId
                            |> Task.mapError never
                            |> Task.andThen (\_ -> Task.fail error)

                    Ok ( chosen, negotiated ) ->
                        kOpen hsId
                            ( 0, [] )
                            (openParams 0
                                mode
                                options.maxMessageSize
                                options.heartbeat
                                negotiated
                                (options.compression |> Maybe.map .threshold |> Maybe.withDefault 0)
                            )
                            decode
                            toWire
                            |> Task.map (Internal.toWebSocket chosen negotiated)
                            |> Task.mapError Socket.Internal.toError
                            |> Task.onError
                                (\error ->
                                    kAbandon hsId
                                        |> Task.mapError never
                                        |> Task.andThen (\_ -> Task.fail error)
                                )
            )


{-| The third argument of `open` (Appendix B.1): `( ( role, mode, maxMessageSize ), ( heartbeat
interval, heartbeat timeout, close timeout ), ( threshold, ( ourNoContextTakeover, ourBits ),
( peerNoContextTakeover, peerBits ) ) )`; role 0 client, 1 server; mode 1 whole, 2 streamed;
threshold -1 when no compression was negotiated (WS7: B.1's `Bool deflate` became the threshold,
which the kernel needs too).
-}
openParams : Int -> Int -> Int -> Maybe Heartbeat -> Maybe Negotiated -> Int -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Int, ( Bool, Int ), ( Bool, Int ) ) )
openParams role mode maxMessageSize heartbeat negotiated threshold =
    let
        ( interval, timeout ) =
            case heartbeat of
                Just hb ->
                    ( hb.interval, hb.timeout )

                Nothing ->
                    ( 0, 0 )

        deflate =
            case negotiated of
                Just n ->
                    if role == 0 then
                        ( max 0 threshold, ( n.clientNoContextTakeover, n.clientMaxWindowBits ), ( n.serverNoContextTakeover, n.serverMaxWindowBits ) )

                    else
                        ( max 0 threshold, ( n.serverNoContextTakeover, n.serverMaxWindowBits ), ( n.clientNoContextTakeover, n.clientMaxWindowBits ) )

                Nothing ->
                    ( -1, ( False, 15 ), ( False, 15 ) )
    in
    ( ( role, mode, maxMessageSize ), ( interval, timeout, 30000 ), deflate )


flatten : List ( String, List String ) -> List ( String, String )
flatten headers =
    List.concatMap (\( name, values ) -> List.map (\v -> ( String.toLower name, v )) values) headers


einval : String -> Socket.Error
einval text =
    Socket.Internal.Error { code = "EINVAL", message = text }



-- SERVERS


{-| An opening request from a client, received but not yet answered. Answer it with
[`accept`](#accept), [`acceptStreamed`](#acceptStreamed) or [`reject`](#reject).
-}
type alias Upgrade =
    Internal.Upgrade


{-| Read an opening request on a connection a server accepted (`Socket.Tcp.listen`,
`Socket.Tls.listen`). The connection must not have a pending read or write; from then on it belongs
to the WebSocket, and its streams fail with `Cancelled "upgraded to WebSocket"`.

Fails with `ETIMEDOUT` when the request does not arrive within 30 seconds, with `EBUSY` while a
read, write or close is in progress on the connection's streams, and with `ERR_WS_HANDSHAKE` when
the client sends something else than an HTTP request (it is answered 400 and the connection
closed). Bytes the client sent right behind its request (an early first frame) are kept for the
WebSocket.

-}
upgradeRequest : Socket.Connection -> Task Socket.Error Upgrade
upgradeRequest (Socket.Internal.Connection c) =
    kReadUpgrade c.id 30000
        |> Task.map (Internal.toUpgrade kAcceptFor)
        |> Task.mapError Socket.Internal.toError


{-| The request target: the path and the query, for example `"/chat?room=1"`.
-}
upgradeTarget : Upgrade -> String
upgradeTarget (Internal.Upgrade up) =
    up.target


{-| The request headers in order, with lower-case names; a repeated header appears once per
occurrence.
-}
upgradeHeaders : Upgrade -> List ( String, String )
upgradeHeaders (Internal.Upgrade up) =
    up.headers


{-| The subprotocols the client offers, in its order of preference.
-}
upgradeProtocols : Upgrade -> List String
upgradeProtocols (Internal.Upgrade up) =
    Handshake.headerValues "sec-websocket-protocol" up.headers
        |> List.concatMap (String.split ",")
        |> List.map String.trim
        |> List.filter ((/=) "")


{-| The `Origin` header, sent by browsers: check it to refuse pages from other sites.
-}
upgradeOrigin : Upgrade -> Maybe String
upgradeOrigin (Internal.Upgrade up) =
    List.head (Handshake.headerValues "origin" up.headers)


{-| The client's end of the connection.
-}
upgradeRemote : Upgrade -> Endpoint
upgradeRemote (Internal.Upgrade up) =
    up.remote


{-| How to accept a connection.

  - `protocol`: the subprotocol to use; it must be one the client offers
    ([`upgradeProtocols`](#upgradeProtocols)).
  - `headers`: extra response headers.
  - `maxMessageSize`, `heartbeat`: as in [`ConnectOptions`](#ConnectOptions).
  - `compression`: the server's permessage-deflate policy, or `Nothing` to decline every offer.

The opening request itself is read by [`upgradeRequest`](#upgradeRequest), within 30 seconds.

-}
type alias AcceptOptions =
    { protocol : Maybe String
    , headers : List ( String, String )
    , maxMessageSize : Int
    , heartbeat : Maybe Heartbeat
    , compression : Maybe ServerCompression
    }


{-| A server's permessage-deflate policy.

  - `maxWindowBits`: the largest window the server compresses with (8 to 15).
  - `contextTakeover`: `False` (the default) answers with `server_no_context_takeover` and
    `client_no_context_takeover`: every message is compressed on its own. `True` allows context
    takeover in each direction the client does not restrict.
  - `threshold`: messages shorter than this many bytes are sent uncompressed.

-}
type alias ServerCompression =
    { maxWindowBits : Int
    , contextTakeover : Bool
    , threshold : Int
    }


{-| No protocol, no extra headers, messages up to 16 MiB, the default heartbeat (30 s / 30 s), and
permessage-deflate accepted without context takeover (15 bits, threshold 64 bytes).
-}
defaultAcceptOptions : AcceptOptions
defaultAcceptOptions =
    { protocol = Nothing
    , headers = []
    , maxMessageSize = 16 * 1024 * 1024
    , heartbeat = Just defaultHeartbeat
    , compression = Just { maxWindowBits = 15, contextTakeover = False, threshold = 64 }
    }


{-| Accept an opening request: check it (RFC 6455 §4.2.1), agree on the protocol and the
compression, and answer it.

An invalid request is answered with 400 (or 426 for an unsupported WebSocket version) and the task
fails with `ERR_WS_HANDSHAKE`. A `protocol` the client did not offer, or an invalid header, fails
with `EINVAL` (the request stays unanswered).

-}
accept : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Whole)
accept =
    acceptWith 1 fromWire


{-| Accept an opening request in the streamed mode; as [`accept`](#accept).
-}
acceptStreamed : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Streamed)
acceptStreamed =
    acceptWith 2 fromWireStreamed


acceptWith : Int -> (( Int, String, Bytes ) -> a) -> AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket mode)
acceptWith mode decode options ((Internal.Upgrade up) as upgrade) =
    case Handshake.checkRequest { method = up.method, version = up.version, headers = up.headers, isH2 = up.isH2 } of
        Err ( status, text ) ->
            let
                extra =
                    if status == 426 then
                        [ ( "Sec-WebSocket-Version", "13" ) ]

                    else
                        []
            in
            reject status extra text upgrade
                |> Task.andThen (\_ -> Task.fail (Internal.handshakeError Nothing text))

        Ok request ->
            let
                protocolOk =
                    case options.protocol of
                        Just p ->
                            List.member p request.protocols

                        Nothing ->
                            True

                negotiated =
                    Handshake.negotiateServer options.compression request.extensions
            in
            if not protocolOk then
                Task.fail (einval "accept: the client did not offer this protocol")

            else
                case
                    Handshake.responseHeaders
                        { accept = up.expectedAccept
                        , protocol = options.protocol
                        , extensions = Maybe.map Tuple.second negotiated
                        , headers = options.headers
                        , isH2 = up.isH2
                        }
                of
                    Err text ->
                        Task.fail (einval text)

                    Ok headers ->
                        kOpen up.id
                            ( if up.isH2 then
                                200

                              else
                                101
                            , headers
                            )
                            (openParams 1
                                mode
                                options.maxMessageSize
                                options.heartbeat
                                (Maybe.map Tuple.first negotiated)
                                (options.compression |> Maybe.map .threshold |> Maybe.withDefault 0)
                            )
                            decode
                            toWire
                            |> Task.map (Internal.toWebSocket options.protocol (Maybe.map Tuple.first negotiated))
                            |> Task.mapError Socket.Internal.toError


{-| Refuse an opening request with an HTTP status, headers and a body, for example
`reject 403 [] "Forbidden"`. The connection is closed afterwards.
-}
reject : Int -> List ( String, String ) -> String -> Upgrade -> Task x ()
reject status headers body (Internal.Upgrade up) =
    kReject up.id ( status, headers, body )
        |> Task.mapError never



-- ERRORS


{-| `True` if the opening handshake failed (`ERR_WS_HANDSHAKE`): the server refused the connection
or answered something else than a WebSocket handshake, or a client's request was invalid.
-}
errorIsHandshakeFailed : Socket.Error -> Bool
errorIsHandshakeFailed error =
    Socket.errorCode error == "ERR_WS_HANDSHAKE"


{-| The HTTP status a server answered a refused opening request with, for example `Just 403`.
`Nothing` for other errors.
-}
handshakeStatus : Socket.Error -> Maybe Int
handshakeStatus ((Socket.Internal.Error e) as error) =
    if errorIsHandshakeFailed error && String.startsWith Internal.handshakeErrorPrefix e.message then
        e.message
            |> String.dropLeft (String.length Internal.handshakeErrorPrefix)
            |> String.split ":"
            |> List.head
            |> Maybe.andThen String.toInt

    else
        Nothing



-- WIRE VALUES (Appendix B.1: mapped-source and mapped-sink tags)


{-| A received message: tag 1 text (the String slot), 2 binary (the Bytes slot).
-}
fromWire : ( Int, String, Bytes ) -> Message
fromWire ( tag, text, bytes ) =
    if tag == 2 then
        Binary bytes

    else
        Text text


{-| A received streamed message: tag 3 text, 4 binary; the String slot is the decimal id of the
body's readable pair.
-}
fromWireStreamed : ( Int, String, Bytes ) -> StreamedMessage
fromWireStreamed ( tag, bodyId, _ ) =
    let
        id =
            String.toInt bodyId |> Maybe.withDefault 0
    in
    if tag == 4 then
        StreamedBinary (Stream.Internal.Readable id)

    else
        StreamedText (Stream.Internal.Readable id)


{-| A message to send: tag 1 text, 2 binary.
-}
toWire : Message -> ( Int, String, Bytes )
toWire message =
    case message of
        Text text ->
            ( 1, text, emptyBytes )

        Binary bytes ->
            ( 2, "", bytes )


emptyBytes : Bytes
emptyBytes =
    Bytes.Encode.encode (Bytes.Encode.sequence [])



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "WebSocket"
-- (src/eco-system/WebSocket/WsManager.{hpp,cpp}, plans/eco-system-websockets.md §3.6 and
-- Appendix C.2) and ignores the Elm functions below. The JS backend runs them (base plan D15):
-- every connection with message subscribers keeps one message-listener process, and every
-- connection with close subscribers one close-listener process (never-completing kernel
-- bindings, killed when the last subscription of their kind goes away), which notify the
-- manager through `Platform.sendToSelf`; the manager hands each event to every tagger of its
-- kind. A close event that arrives after the last close subscription went away goes back to the
-- kernel (`kHoldClose`) for the next subscriber. The constructor layout of MySub is mirrored by
-- WsManager.hpp: keep them in sync. Tagger arguments: ( kind, text, bytes ) (the mapped-source
-- tags of Appendix B.1) and ( code, reason, clean ).


type MySub msg
    = OnMessage Int (( Int, String, Bytes ) -> msg)
    | OnClose Int (( Int, String, Bool ) -> msg)


type alias MessageArg =
    ( Int, String, Bytes )


type alias CloseArg =
    ( Int, String, Bool )


subMap : (a -> b) -> MySub a -> MySub b
subMap f sub =
    case sub of
        OnMessage id tagger ->
            OnMessage id (tagger >> f)

        OnClose id tagger ->
            OnClose id (tagger >> f)


{-| Per WebSocket id: its taggers of each kind in subscription order, and the processes running
the kernel listeners.
-}
type alias State msg =
    Dict Int (Subs msg)


type alias Subs msg =
    { messages : List (MessageArg -> msg)
    , closes : List (CloseArg -> msg)
    , messageListener : Maybe Process.Id
    , closeListener : Maybe Process.Id
    }


type Event
    = GotMessage Int MessageArg
    | GotClose Int CloseArg


init : Task Never (State msg)
init =
    Task.succeed Dict.empty


onEffects : Platform.Router msg Event -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router subs state =
    let
        empty =
            { messages = [], closes = [], messageListener = Nothing, closeListener = Nothing }

        -- Effects arrive in reverse order of declaration.
        grouped =
            List.foldr
                (\sub dict ->
                    case sub of
                        OnMessage id tagger ->
                            Dict.update id (\old -> Just (Maybe.withDefault empty old |> (\s -> { s | messages = tagger :: s.messages }))) dict

                        OnClose id tagger ->
                            Dict.update id (\old -> Just (Maybe.withDefault empty old |> (\s -> { s | closes = tagger :: s.closes }))) dict
                )
                Dict.empty
                (List.reverse subs)

        ids =
            Dict.keys (Dict.union grouped state)

        reconcile id =
            let
                wanted =
                    Dict.get id grouped |> Maybe.withDefault empty

                old =
                    Dict.get id state |> Maybe.withDefault empty
            in
            Task.map2
                (\ml cl -> ( id, { wanted | messageListener = ml, closeListener = cl } ))
                (listener (not (List.isEmpty wanted.messages))
                    old.messageListener
                    (kAttachMessageListener id (\arg -> Platform.sendToSelf router (GotMessage id arg)))
                )
                (listener (not (List.isEmpty wanted.closes))
                    old.closeListener
                    (kAttachCloseListener id (\arg -> Platform.sendToSelf router (GotClose id arg)))
                )
    in
    List.map reconcile ids
        |> Task.sequence
        |> Task.map
            (List.filter (\( _, s ) -> s.messageListener /= Nothing || s.closeListener /= Nothing)
                >> Dict.fromList
            )


listener : Bool -> Maybe Process.Id -> Task Never () -> Task Never (Maybe Process.Id)
listener want old attach =
    case ( want, old ) of
        ( True, Just pid ) ->
            Task.succeed (Just pid)

        ( True, Nothing ) ->
            Process.spawn attach |> Task.map Just

        ( False, Just pid ) ->
            Process.kill pid |> Task.map (\_ -> Nothing)

        ( False, Nothing ) ->
            Task.succeed Nothing


onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router event state =
    case event of
        GotMessage id arg ->
            -- A message for a connection whose last subscriber just went away is dropped.
            Dict.get id state
                |> Maybe.map .messages
                |> Maybe.withDefault []
                |> List.map (\tagger -> Platform.sendToApp router (tagger arg))
                |> Task.sequence
                |> Task.map (\_ -> state)

        GotClose id arg ->
            case Dict.get id state |> Maybe.map .closes |> Maybe.withDefault [] of
                [] ->
                    kHoldClose id arg
                        |> Task.map (\_ -> state)

                taggers ->
                    taggers
                        |> List.map (\tagger -> Platform.sendToApp router (tagger arg))
                        |> Task.sequence
                        |> Task.map (\_ -> state)



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-websockets.md Appendix B.1).


kHandshakeKey : Task Never ( String, String )
kHandshakeKey =
    Eco.Kernel.WebSocket.handshakeKey


kAcceptFor : String -> String
kAcceptFor =
    Eco.Kernel.WebSocket.acceptFor


kDial :
    ( List String, Int, Int )
    -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) )
    -> ( String, List ( String, String ) )
    -> Task ( String, String ) ( Int, ( Int, Bool ), List ( String, List String ) )
kDial =
    Eco.Kernel.WebSocket.dial


kReadUpgrade : Int -> Int -> Task ( String, String ) Internal.UpgradeArg
kReadUpgrade =
    Eco.Kernel.WebSocket.readUpgrade


kOpen :
    Int
    -> ( Int, List ( String, String ) )
    -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Int, ( Bool, Int ), ( Bool, Int ) ) )
    -> (( Int, String, Bytes ) -> a)
    -> (b -> ( Int, String, Bytes ))
    -> Task ( String, String ) Internal.OpenArg
kOpen =
    Eco.Kernel.WebSocket.open


kReject : Int -> ( Int, List ( String, String ), String ) -> Task Never ()
kReject =
    Eco.Kernel.WebSocket.reject


{-| Releases a handshake id nobody will answer (a client handshake whose response Elm refused);
the kernel closes its connection.
-}
kAbandon : Int -> Task Never ()
kAbandon =
    Eco.Kernel.WebSocket.abandon


kClose : Int -> Int -> String -> Task Never ()
kClose =
    Eco.Kernel.WebSocket.close


kClosed : Int -> Task Never ( Int, String, Bool )
kClosed =
    Eco.Kernel.WebSocket.closed


kPing : Int -> Task ( String, String ) Int
kPing =
    Eco.Kernel.WebSocket.ping


kOpenOutgoing : Int -> Int -> Task ( String, String ) Int
kOpenOutgoing =
    Eco.Kernel.WebSocket.openOutgoing



-- JS-only kernels, for the effect-manager bodies (plans/eco-system-websockets.md Appendix B.1,
-- E.3). The native backend drops those bodies, so these have no C++ counterpart.


kAttachMessageListener : Int -> (MessageArg -> Task Never ()) -> Task Never ()
kAttachMessageListener =
    Eco.Kernel.WebSocket.attachMessageListener


kAttachCloseListener : Int -> (CloseArg -> Task Never ()) -> Task Never ()
kAttachCloseListener =
    Eco.Kernel.WebSocket.attachCloseListener


kHoldClose : Int -> CloseArg -> Task Never ()
kHoldClose =
    Eco.Kernel.WebSocket.holdClose
