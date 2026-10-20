effect module WebSocket where { subscription = MySub } exposing
    ( WebSocket, Whole, Streamed, Message(..), StreamedMessage(..)
    , readable, readableStreamed, writable, sendText, sendBinary
    , protocol, compression, Negotiated, localEndpoint, remoteEndpoint
    , onMessage, onClose, ping, close, awaitClose
    , CloseCode(..), CloseInfo, Heartbeat
    , ConnectOptions, ClientCompression, defaultConnectOptions, connect, connectStreamed
    , Upgrade, receiveUpgrade, upgradeTarget, upgradeHeaders, upgradeProtocols, upgradeOrigin
    , upgradeRemote, AcceptOptions, ServerCompression, defaultAcceptOptions
    , accept, acceptStreamed, reject
    , errorIsHandshakeFailed, errorHandshakeStatus
    )

{-| A WebSocket (RFC 6455) is a full-duplex connection that carries messages rather than bytes
and is opened by an HTTP request, and this module opens WebSockets as a client and answers them
as a server.

A client [`connect`](#connect)s to a `ws://` or `wss://` URL. A server receives a client's
opening request as an [`Upgrade`](#Upgrade), either on a [`Socket.Connection`](Socket#Connection)
it accepted ([`receiveUpgrade`](#receiveUpgrade)) or from an HTTP server
([`Http.Server.upgradeRequest`](Http-Server#upgradeRequest)), and answers it with
[`accept`](#accept) or [`reject`](#reject). Either way an open connection is a
[`WebSocket`](#WebSocket).

    WebSocket.connect (WebSocket.defaultConnectOptions "wss://example.com/chat")
        |> Task.andThen
            (\ws ->
                Stream.write (WebSocket.Text "hello") (WebSocket.writable ws)
                    |> Task.mapError (\_ -> ...)
            )

Several modules define functions such as `close`, `accept` and `readable`, so import this module
qualified:

    import WebSocket

**Messages.** A message is text or binary data ([`Message`](#Message)). A connection is opened in
one of two _modes_, and its type says which. In the _whole_ mode ([`connect`](#connect),
[`accept`](#accept)) every message arrives in one piece, on [`readable`](#readable) or through
[`onMessage`](#onMessage), and a message larger than the `maxMessageSize` of its options fails
the connection. In the _streamed_ mode ([`connectStreamed`](#connectStreamed),
[`acceptStreamed`](#acceptStreamed)) every message arrives as a stream of its own
([`StreamedMessage`](#StreamedMessage)), whatever its size. A streamed message must be read to
its end (`Closed`) or cancelled, because the connection delivers nothing after it until then. In
both modes each value written to [`writable`](#writable) is one message, and
[`sendText`](#sendText) and [`sendBinary`](#sendBinary) send one message whose content is read
from a stream. While 1 MiB of received messages, or 1024 of them, wait unread, the connection
stops reading from the network.

**Ending.** A connection normally ends with a _closing handshake_: one end sends a Close frame
carrying a [`CloseCode`](#CloseCode) and a reason, the other answers with its own, and the
connection is then gone. This end can also _fail_ a connection, for example on a protocol error,
an invalid or oversized message, or a silent peer: it sends a Close frame with a code saying why
and closes the connection without waiting for an answer. And the network connection can simply
be lost. [`awaitClose`](#awaitClose) and [`onClose`](#onClose) report how a connection ended, as
a [`CloseInfo`](#CloseInfo).

The tasks of this module that can fail fail with a [`Socket.Error`](Socket#Error), which
`Socket`'s predicates and [`errorIsHandshakeFailed`](#errorIsHandshakeFailed) classify. Once a
connection is open, a failure of the connection itself arrives on its streams instead, as the
[`Stream`](Stream) module describes: a read of [`readable`](#readable) fails with
`Stream.Cancelled` and a reason such as `"ERR_WS_PROTOCOL: <details>"`.

**Liveness.** By default this end checks that the peer is still there: when nothing has arrived
for 30 seconds it sends a ping, and when still nothing at all has arrived 30 seconds later it
fails the connection ([`Heartbeat`](#Heartbeat)). Pings from the peer are answered until this
end starts closing.

**Compression.** permessage-deflate (RFC 7692) compresses the content of each message. By
default a client offers it and a server accepts the offer, both without _context takeover_: each
message is compressed on its own, without referring back to earlier ones. With
`contextTakeover = True` in the compression options of both sides a message may refer back into
earlier messages, which compresses a run of similar messages better. A message written to
[`writable`](#writable) that is shorter than the compression options' `threshold` bytes is sent
uncompressed, while a non-empty message sent with
[`sendText`](#sendText) or [`sendBinary`](#sendBinary) is compressed whatever its size.
[`compression`](#compression) tells what the handshake agreed. Do not send secrets and data an
attacker controls on one compressed connection: the compressed sizes can reveal the secrets (the
CRIME and BREACH attacks).

A connection keeps the program running while an [`onMessage`](#onMessage) subscription exists
and the connection is open, while an [`onClose`](#onClose) subscription waits for its
`CloseInfo`, while an [`awaitClose`](#awaitClose) waits, during a closing handshake this end
started, and while an operation on it, such as a read, a write or a [`ping`](#ping), is waiting.

**Client limits.** A client opens a new connection for every [`connect`](#connect), even to a
host it is already connecting to, although RFC 6455 asks a client to wait for one opening
handshake with a host to finish before it starts another. Redirects are not followed (a redirect
status fails the handshake), and no proxy is used.

On native Windows, WebSockets are not supported: connecting, receiving an opening request and
accepting one fail with `ENOTSUP`.


## Connections

@docs WebSocket, Whole, Streamed, Message, StreamedMessage
@docs readable, readableStreamed, writable, sendText, sendBinary
@docs protocol, compression, Negotiated, localEndpoint, remoteEndpoint


## Events and closing

@docs onMessage, onClose, ping, close, awaitClose
@docs CloseCode, CloseInfo, Heartbeat


## Clients

@docs ConnectOptions, ClientCompression, defaultConnectOptions, connect, connectStreamed


## Servers

@docs Upgrade, receiveUpgrade, upgradeTarget, upgradeHeaders, upgradeProtocols, upgradeOrigin
@docs upgradeRemote, AcceptOptions, ServerCompression, defaultAcceptOptions
@docs accept, acceptStreamed, reject


## Errors

@docs errorIsHandshakeFailed, errorHandshakeStatus

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


{-| An open WebSocket connection, in the mode `mode`: [`Whole`](#Whole) or
[`Streamed`](#Streamed).

A value is made only by [`connect`](#connect), [`connectStreamed`](#connectStreamed),
[`accept`](#accept) and [`acceptStreamed`](#acceptStreamed), and its `mode` is the mode that
function opened the connection in, so a function that takes only one mode can rely on it. The
value stays usable after the connection has ended.

-}
type alias WebSocket mode =
    Internal.WebSocket mode


{-| The mode of a connection whose messages arrive whole, each as one [`Message`](#Message). It
has no values; it is only used as the `mode` of a [`WebSocket`](#WebSocket).
-}
type Whole
    = Whole Never


{-| The mode of a connection whose messages arrive as streams, each a
[`StreamedMessage`](#StreamedMessage). It has no values; it is only used as the `mode` of a
[`WebSocket`](#WebSocket).
-}
type Streamed
    = Streamed Never


{-| A message: `Text` carries text and `Binary` carries bytes. Both kinds can be sent and
received on one connection, in any order.

A received `Text` has been checked to be valid UTF-8: a text message that is not fails the
connection with `InvalidData`. On the native backend a lone surrogate in a sent `Text` goes out
as bytes that are not valid UTF-8; the JavaScript backend sends U+FFFD in its place.

-}
type Message
    = Text String
    | Binary Bytes


{-| A message received in the streamed mode, whose content arrives as a stream, chunk by chunk,
as the peer sends it, decompressed when the message was compressed.

`StreamedText` carries a stream of text whose chunks always end on a whole character; text that
is not valid UTF-8 fails the connection with `InvalidData`. `StreamedBinary` carries a stream of
bytes.

The next message is delivered only once this one's stream has been read to `Closed`, or
cancelled with `Stream.cancelReadable`, which drops the rest of the message. When the connection
ends or fails before the message is complete, what had arrived can still be read, and then the
stream fails with `Cancelled`.

-}
type StreamedMessage
    = StreamedText (Stream.Readable String)
    | StreamedBinary (Stream.Readable Bytes)


{-| Returns the stream of the messages the peer sends, in order.

Once the peer's Close frame has arrived, reads fail with `Closed` after the messages received
before it. When the connection fails or is lost instead, reads fail with `Stream.Cancelled` and
a reason, such as `"ERR_WS_PROTOCOL: <details>"`, `"ERR_WS_MESSAGE_TOO_BIG"`,
`"heartbeat ETIMEDOUT"` or `"socket closed"`, again after the messages received before it.
[`awaitClose`](#awaitClose) gives the close code and reason.

While the connection has an [`onMessage`](#onMessage) subscription, messages go to the
subscription instead, and a read fails with `Locked`.

-}
readable : WebSocket Whole -> Stream.Readable Message
readable (Internal.WebSocket ws) =
    Stream.Internal.Readable ws.readable


{-| Returns the stream of the messages of a streamed connection, each a
[`StreamedMessage`](#StreamedMessage). It ends and fails as [`readable`](#readable) does.
-}
readableStreamed : WebSocket Streamed -> Stream.Readable StreamedMessage
readableStreamed (Internal.WebSocket ws) =
    Stream.Internal.Readable ws.readable


{-| Returns the stream that sends messages: each value written is one message, sent after the
messages written or streamed before it.

Closing it with `Stream.closeWritable` starts the closing handshake with `Normal` and no reason,
as [`close`](#close) does. Cancelling it with `Stream.cancelWritable` fails the connection with
`InternalError`. Once the connection is closing or has ended, writes fail with
`Stream.Cancelled`.

-}
writable : WebSocket mode -> Stream.Writable Message
writable (Internal.WebSocket ws) =
    Stream.Internal.Writable ws.writable


{-| Sends one text message whose content is read from `source` as it arrives, so that a message
too large to hold in memory can be sent. The task succeeds once `source` has ended and the
message's last frame has been written.

The message takes its place among the outgoing messages when the task starts: messages written
to [`writable`](#writable), or sent with `sendText` or [`sendBinary`](#sendBinary), after that
go out after it, while pings and pongs are not held up. Each chunk of `source` is sent as one or
more pieces of the message, compressed when the connection uses compression. An empty `source`
sends an empty message.

If `source` fails after part of the message has gone out, the message cannot be completed and
the connection fails with `InternalError`; if nothing of it has gone out yet, nothing is sent.
Either way the task fails with `ECANCELED`. It fails with `EBUSY` when `source` is locked, and
with `ECANCELED` when the connection is closing or has ended, or ends before the message is
complete.

-}
sendText : Stream.Readable String -> WebSocket mode -> Task Socket.Error ()
sendText =
    sendStream 1


{-| Sends one binary message whose content is read from `source` as it arrives, exactly as
[`sendText`](#sendText) does for text.
-}
sendBinary : Stream.Readable Bytes -> WebSocket mode -> Task Socket.Error ()
sendBinary =
    sendStream 2


{-| Sends one message of kernel kind `kind` (1 text, 2 binary) whose content is piped from
`source` into a new outgoing message stream, as [`sendText`](#sendText) describes.
-}
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


{-| Returns the `Socket.Error` for a failed pipe: `ECANCELED` with the reason for `Cancelled`,
`ECANCELED` with `"socket closed"` for `Closed`, and `EBUSY` for `Locked`.
-}
streamError : Stream.Error -> Socket.Error
streamError error =
    case error of
        Stream.Cancelled reason ->
            Socket.Internal.Error { code = "ECANCELED", message = reason }

        Stream.Closed ->
            Socket.Internal.Error { code = "ECANCELED", message = "socket closed" }

        Stream.Locked ->
            Socket.Internal.Error { code = "EBUSY", message = "the stream is locked" }


{-| Returns the subprotocol the handshake agreed on (`Sec-WebSocket-Protocol`), or `Nothing`
when it agreed none.
-}
protocol : WebSocket mode -> Maybe String
protocol (Internal.WebSocket ws) =
    ws.protocol


{-| Returns the permessage-deflate settings the handshake agreed on, or `Nothing` when it agreed
none.

A `Just` does not mean that every message is compressed: a message written to
[`writable`](#writable) that is shorter than the `threshold` is still sent uncompressed, and what
the peer compresses is up to the peer.

-}
compression : WebSocket mode -> Maybe Negotiated
compression (Internal.WebSocket ws) =
    ws.compression


{-| The permessage-deflate settings the two ends of a connection have agreed on.

`serverNoContextTakeover` and `clientNoContextTakeover` are `True` when that end, the server or
the client, compresses every message on its own. `serverMaxWindowBits` and `clientMaxWindowBits`
are the largest window that end compresses with, in window bits (as
[`ClientCompression`](#ClientCompression) explains them); in the settings
[`compression`](#compression) returns, they are from 8 to 15.

-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| Returns this end of the connection.
-}
localEndpoint : WebSocket mode -> Endpoint
localEndpoint (Internal.WebSocket ws) =
    ws.local


{-| Returns the peer's end of the connection.
-}
remoteEndpoint : WebSocket mode -> Endpoint
remoteEndpoint (Internal.WebSocket ws) =
    ws.remote



-- EVENTS AND CLOSING


{-| Creates a subscription to the messages of a connection.

While a connection has subscriptions, every message goes to all of them, in subscription order,
and reads of [`readable`](#readable) fail with `Locked`. Messages that arrive while it has none
wait on the readable. A subscription does not start while a `Stream.read` of the readable is
waiting.

While the connection is open, an `onMessage` subscription keeps the program running.

-}
onMessage : WebSocket Whole -> (Message -> msg) -> Sub msg
onMessage (Internal.WebSocket ws) toMsg =
    subscription (OnMessage ws.id (\arg -> toMsg (fromWire arg)))


{-| Creates a subscription to the end of a connection. Its [`CloseInfo`](#CloseInfo) is
delivered once, to every `onClose` subscription the connection has at that moment. A
subscription made after it was delivered receives nothing.

Until its `CloseInfo` has been delivered, an `onClose` subscription keeps the program running.

-}
onClose : WebSocket mode -> (CloseInfo -> msg) -> Sub msg
onClose (Internal.WebSocket ws) toMsg =
    subscription (OnClose ws.id (\arg -> toMsg (toCloseInfo arg)))


{-| Sends a ping and waits for its pong, giving the round trip time in milliseconds.

Fails with `ECANCELED` when the connection is closing or has ended, or ends before the pong
arrives, and with `ETIMEDOUT` when no pong arrives within the heartbeat's `timeout` (30 seconds
when `heartbeat` is `Nothing` or its `timeout` is 0 or less). While the connection has
stopped reading because messages wait unread, that wait is suspended, and it starts again when
reading resumes. A pong also answers every earlier ping still waiting.

-}
ping : WebSocket mode -> Task Socket.Error Int
ping (Internal.WebSocket ws) =
    kPing ws.id
        |> Task.mapError Socket.Internal.toError


{-| Starts the closing handshake with `code` and `reason`: the messages already written or being
streamed are sent first, then a Close frame. On the JavaScript backend the reason is cut to its
longest start that is at most 123 bytes of UTF-8; on the native backend a character outside the
Basic Multilingual Plane is counted as 6 bytes, so the reason can be cut shorter, and the cut
can fall inside such a character. The task succeeds once the Close frame has been written. The
connection ends when the peer's Close frame arrives, or 30 seconds after this end started
closing if it does not, which is reported as `Abnormal`.

From then on, messages that arrive are dropped (a streamed message being received fails with
`Cancelled`), and writes to [`writable`](#writable) fail.

Fails with `EINVAL` for a code that cannot be sent: only 1000 to 1003, 1007 to 1014 and 3000 to
4999 can, so `NoStatus`, `Abnormal`, and `Other` with a code outside those ranges cannot.
Closing a connection that is closing or has ended, with a code that can be sent, succeeds and
sends nothing more.

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


{-| Waits until the connection has ended and returns how it ended. Once it has ended, it returns
at once. On the native backend, a connection that ended before more than 4096 other connections
ended may be reported as `Abnormal`, with an empty reason and `clean` `False`, whatever its real
end.

A waiting `awaitClose` keeps the program running.

-}
awaitClose : WebSocket mode -> Task x CloseInfo
awaitClose (Internal.WebSocket ws) =
    kClosed ws.id
        |> Task.map toCloseInfo
        |> Task.mapError never


{-| The code a Close frame carries to say why a connection is closing, from the codes RFC 6455
defines.

`Normal`, `GoingAway`, `ProtocolError` and `UnsupportedData` are the codes 1000 to 1003, and
`InvalidData`, `PolicyViolation`, `MessageTooBig`, `MandatoryExtension` and `InternalError` the
codes 1007 to 1011.

`NoStatus` (1005) and `Abnormal` (1006) are never sent; they describe how a connection ended.
`NoStatus` is reported when the peer's Close frame carried no code. `Abnormal` is reported when,
for example, the network connection was lost, the peer did not answer a Close frame in time, or
the heartbeat found the peer silent.

`Other` carries any other code, such as an application's own code from 4000 to 4999. A received
code that has a constructor of its own is always given that constructor, never `Other`.

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


{-| How a connection ended.

When the peer's Close frame arrived, `code` and `reason` are the ones it carried and `clean` is
`True`, whichever end started closing. When this end failed the connection, they are the code
and reason of the failure, and `clean` is `False`; a heartbeat that found the peer silent
is the exception, reported as `Abnormal` with an empty reason. When the connection ended in any
other way, `code` is `Abnormal`, `reason` is empty and `clean` is `False`.

-}
type alias CloseInfo =
    { code : CloseCode
    , reason : String
    , clean : Bool
    }


{-| The liveness check of a connection, both times in milliseconds.

When nothing has arrived from the peer for `interval`, a ping is sent. If nothing at all
arrives within a further `timeout`, the connection is failed: a Close frame with `GoingAway` is
sent, the connection is closed, its end is reported as `Abnormal`, and reads fail with
`"heartbeat ETIMEDOUT"`. Anything received counts, not only the pong. While the connection has
stopped reading because messages wait unread, the check is suspended.

An `interval` of 0 or less turns the check off, as `heartbeat = Nothing` does, while a `timeout`
of 0 or less means 30 seconds. Both are plain `Int`s, so the compiler accepts any value.

-}
type alias Heartbeat =
    { interval : Int
    , timeout : Int
    }


{-| Returns the number a close code stands for.
-}
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


{-| Returns the close code for a number: its own constructor where there is one, and `Other n`
otherwise.
-}
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


{-| Tells whether a close code may be sent in a Close frame: 1000 to 1003, 1007 to 1014, or 3000
to 4999.
-}
isSendable : Int -> Bool
isSendable n =
    (n >= 1000 && n <= 1003) || (n >= 1007 && n <= 1014) || (n >= 3000 && n <= 4999)


{-| Returns the longest start of `text` whose UTF-8 encoding has at most `limit` bytes, counting
each `Char`. On the native backend a `Char` is a UTF-16 unit, so a character outside the Basic
Multilingual Plane counts as two 3-byte halves: the result can be shorter and can end in half a
character.
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


{-| Builds a `CloseInfo` from the kernel's `( code, reason, clean )` tuple.
-}
toCloseInfo : ( Int, String, Bool ) -> CloseInfo
toCloseInfo ( code, reason, clean ) =
    { code = intToCloseCode code, reason = reason, clean = clean }



-- CLIENTS


{-| How a client connects.

  - `url`: `ws://host[:port]/path?query`, or `wss://...` for a connection over TLS. An IPv6
    address is written in brackets, and a zone in it may be written `%25`, as in
    `ws://[fe80::1%25eth0]/`. A fragment (`#`) or user information makes the URL invalid.
  - `headers`: extra request headers, such as `Authorization`. A name must be an HTTP token and
    a value may not hold a carriage return, line feed or NUL. `Host`, `Upgrade`, `Connection`,
    `Sec-WebSocket-Key`, `Sec-WebSocket-Version`, `Sec-WebSocket-Accept`,
    `Sec-WebSocket-Protocol`, `Sec-WebSocket-Extensions`, `Content-Length` and
    `Transfer-Encoding` are refused, in any case.
  - `protocols`: the subprotocols to offer, in order; each must be an HTTP token and be listed
    once. [`protocol`](#protocol) tells which one the server chose.
  - `verification`: which server certificates a `wss` connection accepts.
  - `timeout`: the time allowed, in milliseconds, for connecting, TLS and the HTTP exchange
    together; the name lookup before them is not limited. `Nothing`, or a value of 0 or less,
    is no limit.
  - `maxMessageSize`: the largest message accepted, in bytes after decompression; a larger one
    fails the connection with `MessageTooBig`. A value of 0 or less accepts only empty
    messages. It does not apply to a streamed connection.
  - `heartbeat`: the [`Heartbeat`](#Heartbeat), or `Nothing` for none.
  - `compression`: the permessage-deflate offer, or `Nothing` to offer none.
  - `http2`: for a `wss` URL, try a WebSocket over HTTP/2 (RFC 8441) first; a `ws` URL always
    uses HTTP/1.1. The TLS handshake then offers `h2`. When the server chooses it and its
    settings allow WebSockets (`SETTINGS_ENABLE_CONNECT_PROTOCOL`), the WebSocket runs on one
    stream of a new HTTP/2 connection. A server that chooses HTTP/1.1 gets the HTTP/1.1
    handshake on the same connection, and an HTTP/2 server whose settings do not allow
    WebSockets is left and dialed again over HTTP/1.1, within the same `timeout`.

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

_Window bits_ is the size of a compressor's window, the distance back it may refer, as a power
of two: from 8 (256 bytes) to 15 (32 KiB). A window size outside 8 to 15 is clamped into that
range.

  - `clientMaxWindowBits`: `Just (Just n)` limits the client's own window to `n` window bits.
    `Just Nothing` sends the parameter without a value, which lets the server choose a limit
    for the client's window. `Nothing` leaves the parameter out, and a server that answers with
    a limit for the client's window then fails the handshake.
  - `serverMaxWindowBits`: `Just n` asks the server to compress with at most `n` window bits; a
    server that answers with more fails the handshake.
  - `contextTakeover`: `False` offers `client_no_context_takeover` and
    `server_no_context_takeover`, and the client then compresses every message on its own.
    `True` offers neither, and the server may still answer with them.
  - `threshold`: a message written to [`writable`](#writable) that is shorter than this many
    bytes is sent uncompressed.

-}
type alias ClientCompression =
    { clientMaxWindowBits : Maybe (Maybe Int)
    , serverMaxWindowBits : Maybe Int
    , contextTakeover : Bool
    , threshold : Int
    }


{-| Returns the options for connecting to `url`: no extra headers or subprotocols,
`Socket.Tls.SystemCertificates`, a 30 second timeout, messages up to 16 MiB, the default
heartbeat (a ping after 30 seconds without anything received, then 30 seconds for anything to
arrive), permessage-deflate offered without context takeover, with `client_max_window_bits`
sent without a value and a threshold of 64 bytes, and `http2 = False`.
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


{-| The heartbeat of both default option sets: a ping after 30 seconds without anything
received, then a further 30 seconds for anything to arrive.
-}
defaultHeartbeat : Heartbeat
defaultHeartbeat =
    { interval = 30000, timeout = 30000 }


{-| Opens a connection in the whole mode to `options.url`.

A host name is looked up first; an address written in the URL is used as it is. The addresses
are tried in order until a connection is made, and the opening handshake then runs on that
connection. When no connection can be made, the error of the last address tried is reported.

Fails with `EINVAL` for an invalid URL, header or subprotocol; with the errors of
[`Socket.lookup`](Socket#lookup); with the socket and TLS errors of connecting; with `ETIMEDOUT`
when the `timeout` runs out; and with `ERR_WS_HANDSHAKE`
([`errorIsHandshakeFailed`](#errorIsHandshakeFailed)) when the server's answer is not an
acceptable opening handshake, in which case
[`errorHandshakeStatus`](#errorHandshakeStatus) gives the HTTP status when that was the problem.

-}
connect : ConnectOptions -> Task Socket.Error (WebSocket Whole)
connect =
    connectWith 1 fromWire


{-| Opens a connection in the streamed mode; everything else is as for [`connect`](#connect).
-}
connectStreamed : ConnectOptions -> Task Socket.Error (WebSocket Streamed)
connectStreamed =
    connectWith 2 fromWireStreamed


{-| Opens a client connection in kernel mode `mode` (1 whole, 2 streamed), where `decode` turns a
received message's kernel tuple into a value of the readable: checks the URL and builds the
request headers, both failing with `EINVAL`, then looks up the host and dials.
-}
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


{-| Returns the permessage-deflate offer a client makes: its `compression` option, unchanged.
-}
offeredCompression : ConnectOptions -> Maybe ClientCompression
offeredCompression options =
    options.compression


{-| Returns the addresses to dial for a URL's host, as text: the address itself for an address,
or what `Socket.lookup` finds for a name.
-}
addressesOf : Handshake.Host -> Task Socket.Error (List String)
addressesOf host =
    case host of
        Handshake.Literal address ->
            Task.succeed [ Address.toString address ]

        Handshake.Name name ->
            Socket.lookup name
                |> Task.map (List.map Address.toString)


{-| Dials `addresses` in order with the request `headers`, checks the server's answer against
`expectedAccept`, the offered subprotocols and the compression offer, and opens the WebSocket.
When the check or the opening fails, the handshake is abandoned, which closes its connection.
-}
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
                    -- `isH2` says which HTTP the kernel used: HTTP/2 answers 2xx, HTTP/1.1 101.
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


{-| Builds the parameters `kOpen` takes, for role `role` (0 client, 1 server) and kernel mode
`mode` (1 whole, 2 streamed): `( ( role, mode, maxMessageSize ), ( interval, timeout,
closeTimeout ), ( threshold, ( ourNoContextTakeover, ourBits ), ( peerNoContextTakeover,
peerBits ) ) )`, where "our" is this end's compressor and "peer" the peer's.

No heartbeat is sent as an interval and timeout of 0, and the close timeout is always 30
seconds. With negotiated settings, a negative `threshold` is sent as 0. Without them the
threshold is -1, which tells the kernel that messages are not compressed, and the two pairs
after it do not matter.

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


{-| Flattens the kernel's response headers into one `( name, value )` pair per value, with the
name lower-cased, keeping their order.
-}
flatten : List ( String, List String ) -> List ( String, String )
flatten headers =
    List.concatMap (\( name, values ) -> List.map (\v -> ( String.toLower name, v )) values) headers


{-| Builds an `EINVAL` error whose message is `text`.
-}
einval : String -> Socket.Error
einval text =
    Socket.Internal.Error { code = "EINVAL", message = text }



-- SERVERS


{-| A client's opening request that a server has received.

One is obtained from [`receiveUpgrade`](#receiveUpgrade) or `Http.Server.upgradeRequest`, read
with the `upgrade` functions below, and answered with [`accept`](#accept),
[`acceptStreamed`](#acceptStreamed) or [`reject`](#reject).

-}
type alias Upgrade =
    Internal.Upgrade


{-| Reads a client's opening request from `connection`, a connection a server accepted, such as
one from a `Socket.Tcp.listen` or `Socket.Tls.listen` listener.

The connection is taken over: from then on its streams fail with
`Stream.Cancelled "upgraded to WebSocket"`, and bytes the client sent right behind its request
are kept for the WebSocket. The request is only read as HTTP here; whether it is a valid opening
request is checked by [`accept`](#accept).

Fails with `EBUSY` while a read or write is waiting on the connection's streams or when the
connection has already been taken over, and with `ECANCELED` when the connection, or its
writable, has been closed; these leave the connection as it is. Otherwise it fails with
`ETIMEDOUT` when the request has not arrived within 30 seconds; with `ERR_WS_HANDSHAKE` when what
the client sends is not an HTTP request or has a head over 64 KiB (both answered with 400), or
the client closes the connection before sending a request; and with the connection's own error
when reading fails. After any of these the connection is closed.

-}
receiveUpgrade : Socket.Connection -> Task Socket.Error Upgrade
receiveUpgrade (Socket.Internal.Connection c) =
    kReadUpgrade c.id 30000
        |> Task.map (Internal.toUpgrade kAcceptFor)
        |> Task.mapError Socket.Internal.toError


{-| Returns the request target, the path and the query, for example `"/chat?room=1"`, as the
client sent it.
-}
upgradeTarget : Upgrade -> String
upgradeTarget (Internal.Upgrade up) =
    up.target


{-| Returns the request headers in the order they were received, with lower-case names and one
entry for each occurrence of a repeated header.
-}
upgradeHeaders : Upgrade -> List ( String, String )
upgradeHeaders (Internal.Upgrade up) =
    up.headers


{-| Returns the subprotocols the client offers, in the order it lists them: the comma-separated
elements of every `Sec-WebSocket-Protocol` header, trimmed, with empty ones dropped.
-}
upgradeProtocols : Upgrade -> List String
upgradeProtocols (Internal.Upgrade up) =
    Handshake.headerValues "sec-websocket-protocol" up.headers
        |> List.concatMap (String.split ",")
        |> List.map String.trim
        |> List.filter ((/=) "")


{-| Returns the value of the first `Origin` header, or `Nothing` when the request has none.
-}
upgradeOrigin : Upgrade -> Maybe String
upgradeOrigin (Internal.Upgrade up) =
    List.head (Handshake.headerValues "origin" up.headers)


{-| Returns the client's end of the connection.
-}
upgradeRemote : Upgrade -> Endpoint
upgradeRemote (Internal.Upgrade up) =
    up.remote


{-| How a server accepts an opening request.

  - `protocol`: the subprotocol to use, which must be one the client offers
    ([`upgradeProtocols`](#upgradeProtocols)), or `Nothing` for none.
  - `headers`: extra response headers, refused by the same rules as the `headers` of
    [`ConnectOptions`](#ConnectOptions).
  - `maxMessageSize`, `heartbeat`: as in [`ConnectOptions`](#ConnectOptions).
  - `compression`: the server's permessage-deflate policy, or `Nothing` to decline every offer.

-}
type alias AcceptOptions =
    { protocol : Maybe String
    , headers : List ( String, String )
    , maxMessageSize : Int
    , heartbeat : Maybe Heartbeat
    , compression : Maybe ServerCompression
    }


{-| What a server agrees to for permessage-deflate. The first of the client's offers that is
valid is accepted under it.

  - `maxWindowBits`: the largest window the server compresses with, in window bits (as
    [`ClientCompression`](#ClientCompression) explains them, clamped to 8 to 15), or the
    client's limit when that is smaller.
  - `contextTakeover`: `False` answers with `server_no_context_takeover` and
    `client_no_context_takeover`, which ask both ends to compress every message on its own. `True`
    keeps context takeover for each end whose no-context-takeover parameter the client did not
    send.
  - `threshold`: a message written to [`writable`](#writable) that is shorter than this many
    bytes is sent uncompressed.

-}
type alias ServerCompression =
    { maxWindowBits : Int
    , contextTakeover : Bool
    , threshold : Int
    }


{-| The default options for accepting: no subprotocol, no extra headers, messages up to 16 MiB,
the default heartbeat (as in [`defaultConnectOptions`](#defaultConnectOptions)), and
permessage-deflate accepted without context takeover, with a 15-bit window and a threshold of 64
bytes.
-}
defaultAcceptOptions : AcceptOptions
defaultAcceptOptions =
    { protocol = Nothing
    , headers = []
    , maxMessageSize = 16 * 1024 * 1024
    , heartbeat = Just defaultHeartbeat
    , compression = Just { maxWindowBits = 15, contextTakeover = False, threshold = 64 }
    }


{-| Accepts an opening request in the whole mode: checks it, agrees on the subprotocol and the
compression, answers it (101 over HTTP/1.1, 200 over HTTP/2), and opens the connection.

The request must be a valid opening request. Over HTTP/1.1 it is a `GET` of HTTP/1.1 or later
with a `Host` header, `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Version: 13`
and a valid `Sec-WebSocket-Key`; over HTTP/2 an extended `CONNECT` with
`Sec-WebSocket-Version: 13`. Its subprotocols must be HTTP tokens and its extensions well
formed. The checks are made in that order, and the first that fails decides the answer: 426,
with `Sec-WebSocket-Version: 13`, for the version, and 400 for any other. The task then fails
with `ERR_WS_HANDSHAKE`.

A `protocol` the client did not offer, or a refused header in `headers`, fails with `EINVAL` and
leaves the request unanswered. Accepting an `Upgrade` that has already been answered fails.

-}
accept : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Whole)
accept =
    acceptWith 1 fromWire


{-| Accepts an opening request in the streamed mode; everything else is as for
[`accept`](#accept).
-}
acceptStreamed : AcceptOptions -> Upgrade -> Task Socket.Error (WebSocket Streamed)
acceptStreamed =
    acceptWith 2 fromWireStreamed


{-| Accepts `upgrade` in kernel mode `mode` (1 whole, 2 streamed), where `decode` turns a
received message's kernel tuple into a value of the readable, as [`accept`](#accept) describes.
-}
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


{-| Refuses an opening request with an HTTP `status`, extra `headers` and a `body`, for example
`reject 403 [] "Forbidden"`, and succeeds once the answer has been written. Over HTTP/1.1 the
connection is closed afterwards; over HTTP/2 the request's stream is ended.

A `status` outside 100 to 999 is sent as 400, and over HTTP/2 on the JavaScript backend a
`status` below 200 is sent as 500. An `Upgrade` that has already been answered is
left as it is.

-}
reject : Int -> List ( String, String ) -> String -> Upgrade -> Task x ()
reject status headers body (Internal.Upgrade up) =
    kReject up.id ( status, headers, body )
        |> Task.mapError never



-- ERRORS


{-| Returns `True` when the error is a failed opening handshake (`ERR_WS_HANDSHAKE`).

A client gets it from [`connect`](#connect) when the server's answer is not an acceptable
opening handshake (a wrong status, missing or wrong handshake headers, or a subprotocol or
extension that was not offered), is not HTTP, or never comes because the server closes the
connection. A server gets it from [`receiveUpgrade`](#receiveUpgrade) and [`accept`](#accept)
when the client's request is not HTTP or not a valid opening request, or the client closes the
connection before sending one.

-}
errorIsHandshakeFailed : Socket.Error -> Bool
errorIsHandshakeFailed error =
    Socket.errorCode error == "ERR_WS_HANDSHAKE"


{-| Returns the HTTP status with which a server refused a client's opening request, for example
`Just 403`: the status of an answer that was not 101, or not 2xx over HTTP/2. Returns `Nothing`
for every other error, including handshakes that failed for another reason.
-}
errorHandshakeStatus : Socket.Error -> Maybe Int
errorHandshakeStatus ((Socket.Internal.Error e) as error) =
    if errorIsHandshakeFailed error && String.startsWith Internal.handshakeErrorPrefix e.message then
        e.message
            |> String.dropLeft (String.length Internal.handshakeErrorPrefix)
            |> String.split ":"
            |> List.head
            |> Maybe.andThen String.toInt

    else
        Nothing



-- WIRE VALUES
-- Messages cross the kernel boundary as ( tag, text, bytes ) tuples: the values of the
-- connection's readable and writable are mapped from and to them.


{-| Returns the `Message` for a received message's kernel tuple `( tag, text, bytes )`: tag 2 is
binary, carried in `bytes`, and any other tag is text, carried in `text`.
-}
fromWire : ( Int, String, Bytes ) -> Message
fromWire ( tag, text, bytes ) =
    if tag == 2 then
        Binary bytes

    else
        Text text


{-| Returns the `StreamedMessage` for a received streamed message's kernel tuple: tag 4 is
binary and any other tag text, and the text slot is the decimal id of the stream pair that
carries the message's content, read as 0, no stream, if it is not a number.
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


{-| Returns the kernel tuple `( tag, text, bytes )` for a message to send: tag 1 with the text,
or tag 2 with the bytes.
-}
toWire : Message -> ( Int, String, Bytes )
toWire message =
    case message of
        Text text ->
            ( 1, text, emptyBytes )

        Binary bytes ->
            ( 2, "", bytes )


{-| An empty `Bytes`, the unused bytes slot of a text message's kernel tuple.
-}
emptyBytes : Bytes
emptyBytes =
    Bytes.Encode.encode (Bytes.Encode.sequence [])



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "WebSocket"
-- (src/eco-system/WebSocket/WsManager.{hpp,cpp}) and ignores the Elm functions below.
-- WsManager.hpp mirrors the constructor layout of MySub: keep the two in sync. The JS backend
-- runs these functions: every connection with message subscriptions keeps one message-listener
-- process, and every connection with close subscriptions one close-listener process (kernel
-- bindings that never complete, killed when the last subscription of their kind goes away),
-- which notify the manager through `Platform.sendToSelf`; the manager hands each event to every
-- tagger of its kind. A close event that arrives after the last close subscription went away
-- goes back to the kernel (`kHoldClose`) for the next subscriber, while a message that arrives
-- after the last message subscription went away is dropped.


{-| A subscription to one connection, named by its WebSocket id: `OnMessage` to its messages,
whose tagger takes a `MessageArg`, and `OnClose` to its end, whose tagger takes a `CloseArg`.
-}
type MySub msg
    = OnMessage Int (( Int, String, Bytes ) -> msg)
    | OnClose Int (( Int, String, Bool ) -> msg)


{-| The kernel's tuple for a received message, `( tag, text, bytes )`, as `fromWire` reads it.
-}
type alias MessageArg =
    ( Int, String, Bytes )


{-| The kernel's tuple for how a connection ended, `( code, reason, clean )`.
-}
type alias CloseArg =
    ( Int, String, Bool )


{-| Applies `f` to whatever a subscription's tagger produces.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f sub =
    case sub of
        OnMessage id tagger ->
            OnMessage id (tagger >> f)

        OnClose id tagger ->
            OnClose id (tagger >> f)


{-| The manager's state: for each WebSocket id that has a listener running, its subscriptions
and listeners.
-}
type alias State msg =
    Dict Int (Subs msg)


{-| One connection's subscriptions, its taggers of each kind in subscription order, and the
processes running its kernel listeners.
-}
type alias Subs msg =
    { messages : List (MessageArg -> msg)
    , closes : List (CloseArg -> msg)
    , messageListener : Maybe Process.Id
    , closeListener : Maybe Process.Id
    }


{-| What a kernel listener reports: a message received on, or the end of, the connection with the
given WebSocket id.
-}
type Event
    = GotMessage Int MessageArg
    | GotClose Int CloseArg


{-| The manager's initial state, with no subscriptions.
-}
init : Task Never (State msg)
init =
    Task.succeed Dict.empty


{-| Brings the listeners in line with the current subscriptions: for every connection, starts
the message and close listeners it now needs and kills those it no longer needs. The new state
keeps only the connections with a listener running.
-}
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


{-| Returns the listener process to keep, given whether one is wanted and the `old` one: `old`
when one is wanted and runs, a newly spawned `attach` when one is wanted and none runs, and
`Nothing`, after killing `old`, when none is wanted.
-}
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


{-| Hands a listener's event to every tagger of its kind for its connection. A message with no
tagger left is dropped; a close with none goes back to the kernel, which holds it for the next
close subscription.
-}
onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router event state =
    case event of
        GotMessage id arg ->
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
-- The annotations fix the kernel ABI: both kernels rely on exactly these argument and result
-- shapes.


{-| A task giving a new random `Sec-WebSocket-Key` and the `Sec-WebSocket-Accept` value it calls
for.
-}
kHandshakeKey : Task Never ( String, String )
kHandshakeKey =
    Eco.Kernel.WebSocket.handshakeKey


{-| Returns the `Sec-WebSocket-Accept` value a `Sec-WebSocket-Key` calls for.
-}
kAcceptFor : String -> String
kAcceptFor =
    Eco.Kernel.WebSocket.acceptFor


{-| Connects to the first of the addresses that accepts, does TLS and the HTTP exchange, and
gives the handshake id, the status and whether HTTP/2 was used, and the response headers.

It takes `( addresses, port, timeout )`, `( ( tls, serverName ), ( verification, pem ),
( http2, _ ) )` and `( target, headers )`, where `verification` is 0 for the system's
certificates, 1 for those in `pem` and 2 for none, and the last `Bool` is unused.

-}
kDial :
    ( List String, Int, Int )
    -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) )
    -> ( String, List ( String, String ) )
    -> Task ( String, String ) ( Int, ( Int, Bool ), List ( String, List String ) )
kDial =
    Eco.Kernel.WebSocket.dial


{-| Takes over the connection with the given id and reads an opening request from it within the
given number of milliseconds.
-}
kReadUpgrade : Int -> Int -> Task ( String, String ) Internal.UpgradeArg
kReadUpgrade =
    Eco.Kernel.WebSocket.readUpgrade


{-| Answers a handshake, on a server with the given status and headers (a client sends nothing),
and opens the WebSocket with `openParams`' parameters, the two functions mapping the values of
its readable and its writable from and to the kernel's tuples.
-}
kOpen :
    Int
    -> ( Int, List ( String, String ) )
    -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Int, ( Bool, Int ), ( Bool, Int ) ) )
    -> (( Int, String, Bytes ) -> a)
    -> (b -> ( Int, String, Bytes ))
    -> Task ( String, String ) Internal.OpenArg
kOpen =
    Eco.Kernel.WebSocket.open


{-| Answers a handshake with a status, headers and a body, and ends it; does nothing for a
handshake that has already been answered.
-}
kReject : Int -> ( Int, List ( String, String ), String ) -> Task Never ()
kReject =
    Eco.Kernel.WebSocket.reject


{-| Releases a handshake id nobody will answer, such as a client handshake whose response Elm
refused; the kernel closes its connection.
-}
kAbandon : Int -> Task Never ()
kAbandon =
    Eco.Kernel.WebSocket.abandon


{-| Starts the closing handshake of a WebSocket with a code and a reason, succeeding once the
Close frame has been written, or at once on a connection that has ended.
-}
kClose : Int -> Int -> String -> Task Never ()
kClose =
    Eco.Kernel.WebSocket.close


{-| Waits for a WebSocket to end and gives its `( code, reason, clean )`.
-}
kClosed : Int -> Task Never ( Int, String, Bool )
kClosed =
    Eco.Kernel.WebSocket.closed


{-| Pings a WebSocket and gives the round trip time in milliseconds.
-}
kPing : Int -> Task ( String, String ) Int
kPing =
    Eco.Kernel.WebSocket.ping


{-| Opens the stream of one outgoing message of a WebSocket, of kind 1 text or 2 binary, and
gives the stream-pair id of its writable.
-}
kOpenOutgoing : Int -> Int -> Task ( String, String ) Int
kOpenOutgoing =
    Eco.Kernel.WebSocket.openOutgoing



-- JS-only kernels, for the effect-manager bodies. The native backend ignores those bodies, so
-- these have no C++ counterpart.


{-| Hands every message of a WebSocket to the given function while it runs, as a task that never
completes; killing its process detaches it.
-}
kAttachMessageListener : Int -> (MessageArg -> Task Never ()) -> Task Never ()
kAttachMessageListener =
    Eco.Kernel.WebSocket.attachMessageListener


{-| Hands the end of a WebSocket to the given function once, at once when the kernel holds it,
as a task that never completes.
-}
kAttachCloseListener : Int -> (CloseArg -> Task Never ()) -> Task Never ()
kAttachCloseListener =
    Eco.Kernel.WebSocket.attachCloseListener


{-| Gives a close event back to the kernel, which holds it for the next close listener.
-}
kHoldClose : Int -> CloseArg -> Task Never ()
kHoldClose =
    Eco.Kernel.WebSocket.holdClose
