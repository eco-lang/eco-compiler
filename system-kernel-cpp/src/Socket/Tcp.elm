module Socket.Tcp exposing
    ( ConnectOptions, defaultConnectOptions, connect, connectToHost
    , ListenOptions, defaultListenOptions, listen
    , setNoDelay, setKeepAlive
    )

{-| TCP connections over IPv4 and IPv6.

A client connects with [`connect`](#connect) (to an [`Address`](Socket-Address#Address)) or
[`connectToHost`](#connectToHost) (to a host name); a server [`listen`](#listen)s and gets its
connections from [`Socket.accept`](Socket#accept) or [`Socket.onConnection`](Socket#onConnection).
Both sides then use the [`Connection`](Socket#Connection)'s streams.

    import Socket
    import Socket.Address as Address exposing (Family(..))
    import Socket.Tcp

    listener =
        Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 8080)


## Connecting

@docs ConnectOptions, defaultConnectOptions, connect, connectToHost


## Listening

@docs ListenOptions, defaultListenOptions, listen


## Connection options

@docs setNoDelay, setKeepAlive

-}

import Eco.Kernel.Socket
import Socket
import Socket.Address as Address exposing (Address)
import Socket.Internal as Internal
import Task exposing (Task)



-- CONNECTING


{-| How to connect.

  - `address` and `port_`: where to connect.
  - `timeout`: the most time, in milliseconds, to wait until the connection is established (and,
    for `Socket.Tls.connect`, the TLS handshake is done); the attempt then fails with `ETIMEDOUT`.
    `Nothing` (or `Just n` with `n <= 0`) waits as long as the operating system does.
  - `noDelay`: disable Nagle's algorithm (`TCP_NODELAY`), so small writes are sent at once.
  - `keepAlive`: send keep-alive probes after the connection has been idle for this many
    milliseconds (rounded up to whole seconds, at least 1 second). `Nothing` sends none.

-}
type alias ConnectOptions =
    { address : Address
    , port_ : Int
    , timeout : Maybe Int
    , noDelay : Bool
    , keepAlive : Maybe Int
    }


{-| Connect to an address and port with no timeout, `noDelay = False` and no keep-alive.
-}
defaultConnectOptions : Address -> Int -> ConnectOptions
defaultConnectOptions address port_ =
    { address = address
    , port_ = port_
    , timeout = Nothing
    , noDelay = False
    , keepAlive = Nothing
    }


{-| Open a TCP connection.

    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) 8080)

Fails with, for example, `ECONNREFUSED` when nothing listens there, or `ETIMEDOUT`.

-}
connect : ConnectOptions -> Task Socket.Error Socket.Connection
connect options =
    let
        ( target, settings ) =
            Internal.tcpConnectArgs options
    in
    kTcpConnect target settings
        |> Task.map Internal.toConnection
        |> Task.mapError Internal.toError


{-| Connect to a host given by name (or by an address literal) and port, with the
[default options](#defaultConnectOptions).

An address literal such as `"127.0.0.1"` or `"::1"` is used as it is. Otherwise the name is
resolved with [`Socket.lookup`](Socket#lookup) and its addresses are tried one after the other, in
the order the resolver returned them, until one connects. If every attempt fails, the task fails
with the last attempt's error; a name without addresses fails with `ENOTFOUND`.

    Socket.Tcp.connectToHost "localhost" 8080

-}
connectToHost : String -> Int -> Task Socket.Error Socket.Connection
connectToHost name port_ =
    case Address.fromString name of
        Just address ->
            connect (defaultConnectOptions address port_)

        Nothing ->
            Socket.lookup name
                |> Task.andThen
                    (\addresses ->
                        case addresses of
                            first :: rest ->
                                connectToFirst port_ first rest

                            [] ->
                                Task.fail
                                    (Internal.Error
                                        { code = "ENOTFOUND"
                                        , message = "getaddrinfo ENOTFOUND " ++ name
                                        }
                                    )
                    )


connectToFirst : Int -> Address -> List Address -> Task Socket.Error Socket.Connection
connectToFirst port_ address rest =
    connect (defaultConnectOptions address port_)
        |> Task.onError
            (\error ->
                case rest of
                    next :: more ->
                        connectToFirst port_ next more

                    [] ->
                        Task.fail error
            )



-- LISTENING


{-| How to listen.

  - `address` and `port_`: where to listen. Port 0 lets the operating system pick a free port
    (see [`Socket.listenerEndpoint`](Socket#listenerEndpoint)). The unspecified address
    (`Socket.Address.any`) listens on every interface.
  - `backlog`: how many connections the operating system queues before they are accepted.
  - `ipv6Only`: for an IPv6 address, accept IPv6 connections only. When `False`, listening on
    `any IPv6` also accepts IPv4 connections, whose addresses are then IPv4-mapped (see
    [`Socket.Address.unmapIPv4`](Socket-Address#unmapIPv4)).

The address may be reused at once after a previous listener on it has closed (`SO_REUSEADDR`).

-}
type alias ListenOptions =
    { address : Address
    , port_ : Int
    , backlog : Int
    , ipv6Only : Bool
    }


{-| Listen on an address and port with a backlog of 511 and `ipv6Only = False`.
-}
defaultListenOptions : Address -> Int -> ListenOptions
defaultListenOptions address port_ =
    { address = address
    , port_ = port_
    , backlog = 511
    , ipv6Only = False
    }


{-| Start listening for TCP connections. Fails with, for example, `EADDRINUSE` when the address and
port are taken, or `EACCES` for a privileged port.
-}
listen : ListenOptions -> Task Socket.Error Socket.Listener
listen options =
    let
        ( target, settings ) =
            Internal.tcpListenArgs options
    in
    kTcpListen target settings
        |> Task.map Internal.toListener
        |> Task.mapError Internal.toError



-- CONNECTION OPTIONS


{-| Turn Nagle's algorithm off (`True`: small writes are sent at once) or on (`False`). On a Unix
domain connection this succeeds and does nothing.
-}
setNoDelay : Bool -> Socket.Connection -> Task Socket.Error ()
setNoDelay noDelay (Internal.Connection c) =
    kSetNoDelay noDelay c.id
        |> Task.mapError Internal.toError


{-| Send keep-alive probes after the connection has been idle for this many milliseconds (rounded
up to whole seconds, at least 1 second), or stop sending them (`Nothing`). On a Unix domain
connection this succeeds and does nothing.
-}
setKeepAlive : Maybe Int -> Socket.Connection -> Task Socket.Error ()
setKeepAlive keepAlive (Internal.Connection c) =
    kSetKeepAlive (Internal.keepAliveSeconds keepAlive) c.id
        |> Task.mapError Internal.toError



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-sockets.md Appendix B.1).


kTcpConnect :
    ( String, Int, Int )
    -> ( Bool, Int )
    -> Task ( String, String ) ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )
kTcpConnect =
    Eco.Kernel.Socket.tcpConnect


kTcpListen : ( String, Int ) -> ( Int, Bool ) -> Task ( String, String ) ( Int, ( Int, String, Int ) )
kTcpListen =
    Eco.Kernel.Socket.tcpListen


kSetNoDelay : Bool -> Int -> Task ( String, String ) ()
kSetNoDelay =
    Eco.Kernel.Socket.setNoDelay


kSetKeepAlive : Int -> Int -> Task ( String, String ) ()
kSetKeepAlive =
    Eco.Kernel.Socket.setKeepAlive
