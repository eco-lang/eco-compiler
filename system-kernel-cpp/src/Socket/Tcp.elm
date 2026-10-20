module Socket.Tcp exposing
    ( ConnectOptions, defaultConnectOptions, connect, connectToHost
    , ListenOptions, defaultListenOptions, listen
    , setNoDelay, setKeepAlive
    )

{-| A TCP connection or listener is made from an IP address and a port, and this module makes
them. Once made, it is an ordinary [`Socket.Connection`](Socket#Connection) or
[`Socket.Listener`](Socket#Listener), used through [`Socket`](Socket) like a connection or
listener of any other kind.

Addresses are [`Socket.Address.Address`](Socket-Address#Address) values, IPv4 or IPv6, not text,
so a host name has to be resolved before anything connects to it. [`connect`](#connect) takes an
address; [`connectToHost`](#connectToHost) takes text, either an address literal, used as it is,
or a host name, which it resolves with [`Socket.lookup`](Socket#lookup) first. A server
[`listen`](#listen)s on an address and gets its connections from
[`Socket.accept`](Socket#accept) or [`Socket.onConnection`](Socket#onConnection), by the rule the
`Socket` module describes.

What this module offers for a connection that already exists is two TCP options: Nagle's
algorithm, which holds back small writes to send them together, and keep-alive probes, which
the operating system sends on an idle connection to find out whether the peer is still there.
Both can be chosen when connecting and changed later with [`setNoDelay`](#setNoDelay) and
[`setKeepAlive`](#setKeepAlive).

Times are given in milliseconds, as `Maybe Int`, and the two fields of `ConnectOptions` that
take one read a non-positive value differently. A connect `timeout` of `Just 0` or less is no
timeout, the same as `Nothing`. A `keepAlive` of `Just 0` or less turns keep-alive on, at 1
second; only `Nothing` leaves it off.

[`Socket.Tls`](Socket-Tls) takes the same [`ConnectOptions`](#ConnectOptions) and
[`ListenOptions`](#ListenOptions) for the TCP side of its connections and listeners.

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


{-| One attempt to open a TCP connection: where to connect, how long to wait, and the TCP
options the connection starts with.

  - `timeout`, up to 2147483647 (about 24.8 days), is the most time, in milliseconds, to wait
    until the connection is established (and, for `Socket.Tls.connect`, until the TLS handshake
    is done as well); the attempt then fails with `ETIMEDOUT`. `Nothing`, or `Just n` with
    `n <= 0`, waits as long as the operating system does.
  - `noDelay = True` turns Nagle's algorithm off (`TCP_NODELAY`), so small writes are sent at
    once.
  - `keepAlive` is how long, in milliseconds, the connection must be idle before keep-alive
    probes are sent, within any limit the operating system sets (32767 seconds on Linux). It
    is rounded up to whole seconds, at least 1 second, so `Just 0` or a negative value sends
    probes after 1 second. `Nothing` sends none.

Setting `noDelay` and `keepAlive` here is best effort: if the operating system refuses one, the
connection is still made.

-}
type alias ConnectOptions =
    { address : Address
    , port_ : Int
    , timeout : Maybe Int
    , noDelay : Bool
    , keepAlive : Maybe Int
    }


{-| Returns options for connecting to `address` on `port_` with no timeout, Nagle's algorithm on
(`noDelay = False`) and no keep-alive.
-}
defaultConnectOptions : Address -> Int -> ConnectOptions
defaultConnectOptions address port_ =
    { address = address
    , port_ = port_
    , timeout = Nothing
    , noDelay = False
    , keepAlive = Nothing
    }


{-| Opens a TCP connection, succeeding once the connection is established.

    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) 8080)

Fails with, for example, `ECONNREFUSED` when nothing listens there, or `ETIMEDOUT` when the
`timeout` has passed.

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


{-| Opens a TCP connection to a host given by name, or by an address literal, and a port, with
the [default options](#defaultConnectOptions).

Text that [`Socket.Address.fromString`](Socket-Address#fromString) reads as an address, such as
`"127.0.0.1"` or `"::1"`, is used as it is. Anything else is resolved with
[`Socket.lookup`](Socket#lookup), and a failed lookup fails the task with its error. The
addresses found are tried one after the other, in the order `lookup` returns them, until one
connects. If every attempt fails, the task fails with the last attempt's error; a name without
addresses fails with `ENOTFOUND`.

    Socket.Tcp.connectToHost "localhost" 8080

The default options have no timeout, so each attempt waits as long as the operating system does
before the next address is tried. For a time limit on each attempt, resolve the name with
`Socket.lookup` and call [`connect`](#connect) with a `timeout`.

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


{-| Connects to `port_` on `address` and, if that fails, on each address of `rest` in turn,
with the default options. Fails with the last attempt's error once every address has failed.
-}
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


{-| Where a TCP listener listens, which connections it accepts, and how it queues the ones it has
not handed out yet.

  - `port_` 0 lets the operating system pick a free port, which
    [`Socket.listenerEndpoint`](Socket#listenerEndpoint) then reports. The unspecified address
    ([`Socket.Address.any`](Socket-Address#any)) listens on every interface.
  - `backlog` is the length of the operating system's queue of connections waiting to be
    accepted, clamped to between 1 and 65535 (the operating system may limit it further). On the
    JavaScript backend it is also how many connections the listener holds for a later `accept`,
    as the `Socket` module describes.
  - `ipv6Only` matters only for an IPv6 address. When `False`, a listener on `any IPv6` also
    accepts IPv4 connections, whose addresses are then IPv4-mapped (see
    [`Socket.Address.unmapIPv4`](Socket-Address#unmapIPv4)). When `True`, it accepts IPv6
    connections only.

On the native backend the listening socket is made with `SO_REUSEADDR`, so the port can be
listened on again as soon as an earlier listener on it has closed.

-}
type alias ListenOptions =
    { address : Address
    , port_ : Int
    , backlog : Int
    , ipv6Only : Bool
    }


{-| Returns options for listening on `address` and `port_` with a backlog of 511 and
`ipv6Only = False`.
-}
defaultListenOptions : Address -> Int -> ListenOptions
defaultListenOptions address port_ =
    { address = address
    , port_ = port_
    , backlog = 511
    , ipv6Only = False
    }


{-| Starts listening for TCP connections, succeeding with the listener once it is bound and
listening. Fails with, for example, `EADDRINUSE` when the address and port are taken, or `EACCES`
for a privileged port.
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


{-| Turns Nagle's algorithm off for the connection (`True`, so small writes are sent at once) or
on (`False`). On a Unix domain connection, or one that has already been closed, this succeeds
and does nothing.
-}
setNoDelay : Bool -> Socket.Connection -> Task Socket.Error ()
setNoDelay noDelay (Internal.Connection c) =
    kSetNoDelay noDelay c.id
        |> Task.mapError Internal.toError


{-| Starts sending keep-alive probes once the connection has been idle for the given number of
milliseconds, within any limit the operating system sets (32767 seconds on Linux), or stops
sending them (`Nothing`). The time is rounded up to whole seconds, at least 1 second, so
`Just 0` or a negative value turns probes on at 1 second rather than off.

On a Unix domain connection, or one that has already been closed, this succeeds and does
nothing.

-}
setKeepAlive : Maybe Int -> Socket.Connection -> Task Socket.Error ()
setKeepAlive keepAlive (Internal.Connection c) =
    kSetKeepAlive (Internal.keepAliveSeconds keepAlive) c.id
        |> Task.mapError Internal.toError



-- KERNELS
-- The annotations fix the kernel ABI: the kernels rely on exactly these argument and result
-- shapes.


{-| The kernel's TCP connect. It takes `( address text, port, timeout in milliseconds )` and
`( noDelay, keep-alive idle time in whole seconds )`, where a timeout or keep-alive of 0 means
none, and succeeds with `( id, ( readableId, writableId ), ( local, remote ) )`, each endpoint
being `( kind, text, port )`. A failure is `( code, message )`.
-}
kTcpConnect :
    ( String, Int, Int )
    -> ( Bool, Int )
    -> Task ( String, String ) ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )
kTcpConnect =
    Eco.Kernel.Socket.tcpConnect


{-| The kernel's TCP listen. It takes `( address text, port )` and `( backlog, ipv6Only )`, and
succeeds with `( id, endpoint )`, the endpoint being `( kind, text, port )`. A failure is
`( code, message )`.
-}
kTcpListen : ( String, Int ) -> ( Int, Bool ) -> Task ( String, String ) ( Int, ( Int, String, Int ) )
kTcpListen =
    Eco.Kernel.Socket.tcpListen


{-| The kernel's `TCP_NODELAY` setter, taking the flag and a connection id.
-}
kSetNoDelay : Bool -> Int -> Task ( String, String ) ()
kSetNoDelay =
    Eco.Kernel.Socket.setNoDelay


{-| The kernel's keep-alive setter, taking the idle time in whole seconds, where 0 turns
keep-alive off, and a connection id.
-}
kSetKeepAlive : Int -> Int -> Task ( String, String ) ()
kSetKeepAlive =
    Eco.Kernel.Socket.setKeepAlive
