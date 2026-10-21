module Socket.Internal exposing
    ( Connection(..), Listener(..), Error(..), UdpSocket(..)
    , toError, error, onUnixPath, toAddress, toEndpoint, toInetEndpoint, toConnection, toListener
    , connectTimeoutMs, keepAliveSeconds, tcpConnectArgs, tcpListenArgs
    )

{-| The socket handle types and the socket error type, defined here so that every module of this
package that makes or uses sockets can build and unwrap them, while users see them only through
the aliases `Socket` and `Socket.Udp` expose, which hide the constructors. Internal; not exposed.

A socket lives in the kernel, not in Elm. What Elm holds is a _handle_: the integer id of the
socket's entry in one of the kernel's tables, together with the endpoints the kernel reported
when the socket was made. A `Listener` and a `UdpSocket` carry one id each. A `Connection`
carries three: its own id in the connection table, and the stream-table ids of its readable and
its writable. A stream-table entry is a stream pair, with a writable side and a readable side, and
a connection's readable and writable are two different pairs rather than the two sides of one.

Kernels hand these values to Elm, and take their arguments, as nested tuples rather than records.
This module names the tuples it decodes:

  - _FErr_, `( code, message )`: a failure.
  - _EpT_, `( kind, text, port )`: an endpoint.
  - _ConnT_, `( id, ( readableId, writableId ), ( local, remote ) )`: a connection, whose two
    endpoints are EpTs.
  - _ListenT_, `( id, endpoint )`: a listener, whose endpoint is an EpT.

The decoders turn these tuples into `Error`, `Connection`, `Listener` and the `Socket.Address`
endpoint types, and the packers turn the TCP option records into the argument tuples of the TCP
and TLS kernels, so the modules that call those kernels share one copy of each.

`Error` is the error of `Socket`, `Socket.Tcp`, `Socket.Unix`, `Socket.Udp`, `Socket.Tls`,
`WebSocket` and `Http.Server.upgradeRequest`. A kernel's failure arrives as an FErr and is decoded
by `toError`. Some errors are instead made in Elm by the modules that use them, without any kernel
reporting them: `Socket.Tcp.connectToHost`, for one, fails with its own `ENOTFOUND` for a name
without addresses.

Two packers turn an optional number of milliseconds into the kernels' "0 is none", and they do not
agree on what `Just` a non-positive value means: a connect timeout of `Just 0` is no timeout, but a
keep-alive of `Just 0` turns keep-alive on.

-}

import Bytes exposing (Bytes)
import Socket.Address as Address exposing (Address, Endpoint(..), Family(..), InetEndpoint)
import Stream.Internal exposing (Readable(..), Writable(..))
import Path


{-| A stream connection, over TCP, a Unix domain socket or TLS, as Elm holds it: its id in the
kernel's connection table, the readable on which the bytes the peer sends arrive, the writable that
takes the bytes to send, and both endpoints.

`readable` and `writable` are two different stream pairs. `local` and `remote` are the endpoints
the kernel reported when the connection was made.

-}
type Connection
    = Connection
        { id : Int
        , readable : Readable Bytes
        , writable : Writable Bytes
        , local : Endpoint
        , remote : Endpoint
        }


{-| A listening stream socket: its id in the kernel's listener table and the endpoint it listens
on, as the kernel reported it when listening started.
-}
type Listener
    = Listener { id : Int, endpoint : Endpoint }


{-| A failed socket operation: a code saying what went wrong and a message for people to read.

The code is usually an errno name such as `"ECONNREFUSED"`, a resolver code such as
`"ENOTFOUND"`, a TLS code, or an `ERR_*` name.

-}
type Error
    = Error { code : String, message : String, onPath : Bool }


{-| A bound UDP socket: its id in the kernel's UDP socket table and the address and port it is
bound to, as the kernel reported them when it was bound.
-}
type UdpSocket
    = UdpSocket { id : Int, endpoint : InetEndpoint }



-- DECODERS


{-| Builds an `Error` from an FErr, `( code, message )`.
-}
toError : ( String, String ) -> Error
toError ( code, message ) =
    Error { code = code, message = message, onPath = False }


{-| Makes an error with a code and a message, as `toError` does.
-}
error : String -> String -> Error
error code message =
    Error { code = code, message = message, onPath = False }


{-| Marks a Unix domain socket's error as a failure of its path when its code is one a path gives
(ENOENT, ENOTDIR, ELOOP, EROFS, ENAMETOOLONG, EACCES), so that `Socket.errorKind` reports it as
`AddressPathFailed` with the file-system kind (plans/eco-system-typed-api.md S2).
-}
onUnixPath : Error -> Error
onUnixPath (Error e) =
    Error { e | onPath = List.member e.code [ "ENOENT", "ENOTDIR", "ELOOP", "EROFS", "ENAMETOOLONG", "EACCES" ] }


{-| Parses the text of an address that a kernel printed.

Text that does not parse becomes the unspecified address, `::` when the text contains a `:` and
`0.0.0.0` otherwise, so the result is then not the address the kernel meant.

-}
toAddress : String -> Address
toAddress text =
    case Address.fromString text of
        Just address ->
            address

        Nothing ->
            if String.contains ":" text then
                Address.any IPv6

            else
                Address.any IPv4


{-| Builds an `Endpoint` from a kernel's EpT, `( kind, text, port )`.

Kind 1 is a Unix domain socket: `text` is its path, parsed with `Path.fromPosixString`, and the
port is ignored. The empty text, which a kernel sends for an unnamed socket, gives the empty path.
Any other kind is an IP endpoint, `text` parsed by `toAddress` with its fallback to the unspecified
address.

-}
toEndpoint : ( Int, String, Int ) -> Endpoint
toEndpoint ( kind, text, port_ ) =
    if kind == 1 then
        Unix (Path.fromPosixString text)

    else
        Inet { address = toAddress text, port_ = port_ }


{-| Builds an `InetEndpoint` from an address's text and a port, parsing the text with `toAddress`
and its fallback to the unspecified address.
-}
toInetEndpoint : ( String, Int ) -> InetEndpoint
toInetEndpoint ( text, port_ ) =
    { address = toAddress text, port_ = port_ }


{-| Builds a `Connection` from a kernel's ConnT, decoding both endpoints with `toEndpoint`.
-}
toConnection : ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) ) -> Connection
toConnection ( id, ( readableId, writableId ), ( local, remote ) ) =
    Connection
        { id = id
        , readable = Readable readableId
        , writable = Writable writableId
        , local = toEndpoint local
        , remote = toEndpoint remote
        }


{-| Builds a `Listener` from a kernel's ListenT, decoding its endpoint with `toEndpoint`.
-}
toListener : ( Int, ( Int, String, Int ) ) -> Listener
toListener ( id, endpoint ) =
    Listener { id = id, endpoint = toEndpoint endpoint }



-- ARGUMENT PACKING


{-| Returns the connect timeout in milliseconds as the kernels take it, where 0 means no timeout:
`Just n` gives `n` for a positive `n`, and both `Nothing` and `Just n` with `n <= 0` give 0.
-}
connectTimeoutMs : Maybe Int -> Int
connectTimeoutMs timeout =
    case timeout of
        Just ms ->
            max 0 ms

        Nothing ->
            0


{-| Returns the keep-alive idle time as the kernels take it, in whole seconds, where 0 means
keep-alive off.

Only `Nothing` gives 0. `Just ms` gives `ms` rounded up to whole seconds, at least 1, so `Just 0`
and negative values turn keep-alive on at 1 second rather than off, unlike `connectTimeoutMs`.

-}
keepAliveSeconds : Maybe Int -> Int
keepAliveSeconds keepAlive =
    case keepAlive of
        Just ms ->
            if ms <= 1000 then
                1

            else
                (ms + 999) // 1000

        Nothing ->
            0


{-| Builds the first two arguments of the kernel functions `Eco.Kernel.Socket.tcpConnect` and
`Eco.Kernel.Tls.connect` from TCP connect options: `( address, port, timeoutMs )` and
`( noDelay, keepAliveSeconds )`. The address is printed with `Socket.Address.toString`, and the
timeout and keep-alive are converted by `connectTimeoutMs` and `keepAliveSeconds`.
-}
tcpConnectArgs :
    { r | address : Address, port_ : Int, timeout : Maybe Int, noDelay : Bool, keepAlive : Maybe Int }
    -> ( ( String, Int, Int ), ( Bool, Int ) )
tcpConnectArgs options =
    ( ( Address.toString options.address, options.port_, connectTimeoutMs options.timeout )
    , ( options.noDelay, keepAliveSeconds options.keepAlive )
    )


{-| Builds the first two arguments of the kernel functions `Eco.Kernel.Socket.tcpListen` and
`Eco.Kernel.Tls.listen` from TCP listen options: `( address, port )` and `( backlog, ipv6Only )`.
The address is printed with `Socket.Address.toString`; the other values are passed as given.
-}
tcpListenArgs :
    { r | address : Address, port_ : Int, backlog : Int, ipv6Only : Bool }
    -> ( ( String, Int ), ( Int, Bool ) )
tcpListenArgs options =
    ( ( Address.toString options.address, options.port_ )
    , ( options.backlog, options.ipv6Only )
    )
