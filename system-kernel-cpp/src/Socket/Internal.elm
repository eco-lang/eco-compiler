module Socket.Internal exposing
    ( Connection(..), Listener(..), Error(..), UdpSocket(..)
    , toError, toAddress, toEndpoint, toInetEndpoint, toConnection, toListener
    , connectTimeoutMs, keepAliveSeconds, tcpConnectArgs, tcpListenArgs
    )

{-| Internal; not exposed.

The socket handle types and the error type are defined here so that every `Socket.*` module can
build and unwrap them, while users only see the aliases exposed by `Socket` and `Socket.Udp`
(plans/eco-system-sockets.md §3.1). The decoders turn the kernels' boundary tuples (§3.2) into
these types, and the packers turn option records into the kernels' argument tuples (Appendix B),
so `Socket.Tcp` and `Socket.Tls` share one copy of each.

-}

import Bytes exposing (Bytes)
import Socket.Address as Address exposing (Address, Endpoint(..), Family(..), InetEndpoint)
import Stream.Internal exposing (Readable(..), Writable(..))
import System.File.Path as Path


{-| A stream connection (TCP, Unix or TLS): its connection-table id, its two stream-table faces
and both endpoints.
-}
type Connection
    = Connection
        { id : Int
        , readable : Readable Bytes
        , writable : Writable Bytes
        , local : Endpoint
        , remote : Endpoint
        }


{-| A listening socket: its listener-table id and the endpoint it is bound to.
-}
type Listener
    = Listener { id : Int, endpoint : Endpoint }


{-| A socket error: the error code (an errno name such as `"ECONNREFUSED"`, or a resolver or TLS
code) and a human readable message.
-}
type Error
    = Error { code : String, message : String }


{-| A bound UDP socket: its socket-table id and its local endpoint.
-}
type UdpSocket
    = UdpSocket { id : Int, endpoint : InetEndpoint }



-- DECODERS (§3.2)


{-| `FErr` → `Error`.
-}
toError : ( String, String ) -> Error
toError ( code, message ) =
    Error { code = code, message = message }


{-| An address printed by a kernel. Kernels print valid RFC 4291 text, so the fallback (§3.2) should
never be used: text that does not parse becomes the unspecified address of the family its text
suggests (`::` when it contains `:`, otherwise `0.0.0.0`).
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


{-| `EpT` → `Endpoint`: kind 0 is an address and a port, kind 1 a Unix socket path (`""` for an
unnamed socket, which becomes the empty path).
-}
toEndpoint : ( Int, String, Int ) -> Endpoint
toEndpoint ( kind, text, port_ ) =
    if kind == 1 then
        Unix (Path.fromPosixString text)

    else
        Inet { address = toAddress text, port_ = port_ }


{-| `( String address, Int port )` → `InetEndpoint`.
-}
toInetEndpoint : ( String, Int ) -> InetEndpoint
toInetEndpoint ( text, port_ ) =
    { address = toAddress text, port_ = port_ }


{-| `ConnT` → `Connection`.
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


{-| `ListenT` → `Listener`.
-}
toListener : ( Int, ( Int, String, Int ) ) -> Listener
toListener ( id, endpoint ) =
    Listener { id = id, endpoint = toEndpoint endpoint }



-- ARGUMENT PACKING (Appendix A / B)


{-| The connect timeout in milliseconds for the kernel: `0` means none. `Just n` with `n <= 0` is
the same as `Nothing`.
-}
connectTimeoutMs : Maybe Int -> Int
connectTimeoutMs timeout =
    case timeout of
        Just ms ->
            max 0 ms

        Nothing ->
            0


{-| The keep-alive idle time in whole seconds for the kernel: `0` means off. Milliseconds are
rounded up to whole seconds, with a minimum of 1 second.
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


{-| The first two arguments of `Socket.tcpConnect` and `Tls.connect`:
`( address, port, timeoutMs )` and `( noDelay, keepAliveSeconds )`.
-}
tcpConnectArgs :
    { r | address : Address, port_ : Int, timeout : Maybe Int, noDelay : Bool, keepAlive : Maybe Int }
    -> ( ( String, Int, Int ), ( Bool, Int ) )
tcpConnectArgs options =
    ( ( Address.toString options.address, options.port_, connectTimeoutMs options.timeout )
    , ( options.noDelay, keepAliveSeconds options.keepAlive )
    )


{-| The first two arguments of `Socket.tcpListen` and `Tls.listen`: `( address, port )` and
`( backlog, ipv6Only )`.
-}
tcpListenArgs :
    { r | address : Address, port_ : Int, backlog : Int, ipv6Only : Bool }
    -> ( ( String, Int ), ( Int, Bool ) )
tcpListenArgs options =
    ( ( Address.toString options.address, options.port_ )
    , ( options.backlog, options.ipv6Only )
    )
