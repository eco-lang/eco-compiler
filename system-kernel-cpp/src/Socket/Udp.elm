effect module Socket.Udp where { subscription = MySub } exposing
    ( Socket, Datagram, BindOptions, defaultBindOptions, bind, localEndpoint
    , send, receive, onMessage, close
    , joinMulticast, leaveMulticast
    )

{-| Some protocols exchange separate short messages rather than a stream of bytes, and UDP is
how such messages travel. This module provides UDP sockets, which send and receive datagrams over
IPv4 and IPv6.

A _datagram_ is one message: a sequence of bytes sent in one piece to an address and port. It
arrives whole or not at all, and the network may lose, duplicate or reorder datagrams without
telling either end. So datagrams here are values, not streams: [`send`](#send) takes one
`Bytes`, and [`receive`](#receive) and [`onMessage`](#onMessage) hand out one
[`Datagram`](#Datagram) at a time, with the endpoint it came from.

A [`Socket`](#Socket) is bound to one local address and port with [`bind`](#bind). The family
of that address, IPv4 or IPv6, is the socket's family. One socket can send to any number of
endpoints and receives the datagrams sent to its own endpoint. An open socket keeps the
program running until it is [closed](#close).

    import Socket
    import Socket.Address as Address exposing (Family(..))
    import Socket.Udp
    import Task exposing (Task)

    bindLoopback : Task Socket.Error Socket.Udp.Socket
    bindLoopback =
        Socket.Udp.bind (Socket.Udp.defaultBindOptions (Address.loopback IPv4) 0)

Arriving datagrams are handed out by one rule, the same one [`Socket`](Socket) describes for the
connections of a listener. A new datagram goes to the oldest waiting `receive`; if there is none,
to every `onMessage` subscription to that socket, all of which receive the same `Datagram`; and
if there is neither, it is _held_ until the next `receive` or subscription, which takes the held
datagrams oldest first. The kernel holds at most 64 datagrams per socket, and drops the oldest
beyond that. Where a datagram that nobody takes waits depends on the backend. On the JavaScript
backend every datagram is read as soon as it arrives, so it is held. On the native backend the
socket reads only while a `receive` is waiting or a subscription exists, so a datagram that
arrives while there is neither stays in the operating system's receive buffer.

A _multicast group_ is an IP address that stands for the sockets that have joined it, so that a
datagram sent to the group's address and a port can reach each of them that is bound to that
port. [`joinMulticast`](#joinMulticast) and [`leaveMulticast`](#leaveMulticast) manage a
socket's membership.

Failures are [`Socket.Error`](Socket#Error) values, classified with that module's predicates.
On native Windows, UDP is not supported: `bind` fails with `ENOTSUP`, and an `onMessage`
subscription is a fatal error.


## Sockets

@docs Socket, Datagram, BindOptions, defaultBindOptions, bind, localEndpoint, close


## Sending and receiving

@docs send, receive, onMessage


## Multicast

@docs joinMulticast, leaveMulticast

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Eco.Kernel.Socket
import Platform
import Process
import Socket
import Socket.Address as Address exposing (Address, InetEndpoint)
import Socket.Internal as Internal
import Task exposing (Task)



-- SOCKETS


{-| A UDP socket bound to a local address and port, made by [`bind`](#bind).

The socket stays open, and keeps the program running, until it is closed with
[`close`](#close). On a closed socket, `send`, `receive`, `joinMulticast` and `leaveMulticast`
fail with `ECANCELED`, and `close` does nothing.

-}
type alias Socket =
    Internal.UdpSocket


{-| A received datagram: its bytes, and the endpoint of the socket that sent it.

On a socket bound to an IPv6 address with `ipv6Only = False`, a datagram from an IPv4 sender
reports the sender as an IPv4-mapped address; [`Socket.Address.unmapIPv4`](Socket-Address#unmapIPv4)
gives the IPv4 address. The sender's address is read from text the kernel prints, and text that
[`Socket.Address.fromString`](Socket-Address#fromString) cannot read becomes the unspecified
address. That can happen for an IPv6 sender whose scope names an interface with a character
other than an ASCII letter or digit, `_`, `.` or `-` in its name.

-}
type alias Datagram =
    { data : Bytes
    , from : InetEndpoint
    }


{-| The settings a socket is bound with.

`address` and `port_` are the local endpoint. Port 0 asks the operating system to choose a free
port, which [`localEndpoint`](#localEndpoint) then reports. The unspecified address
([`Socket.Address.any`](Socket-Address#any)) receives on every interface.

`reuseAddress` lets several sockets that all set it bind the same address and port
(`SO_REUSEADDR`), for example several receivers of one multicast group on one machine.

`broadcast` allows sending to a broadcast address (`SO_BROADCAST`). Without it the operating
system refuses such a send, with `EACCES` on Linux.

`ipv6Only` matters only for an IPv6 address. When it is `False`, a socket bound to the
unspecified IPv6 address also exchanges datagrams with IPv4 endpoints, which it sees as
IPv4-mapped addresses. When it is `True`, the socket uses IPv6 only.

-}
type alias BindOptions =
    { address : Address
    , port_ : Int
    , reuseAddress : Bool
    , broadcast : Bool
    , ipv6Only : Bool
    }


{-| Returns the options for binding to `address` and `port_` with `reuseAddress`, `broadcast`
and `ipv6Only` all `False`.
-}
defaultBindOptions : Address -> Int -> BindOptions
defaultBindOptions address port_ =
    { address = address
    , port_ = port_
    , reuseAddress = False
    , broadcast = False
    , ipv6Only = False
    }


{-| Creates a UDP socket bound to the address and port the options name.

Fails, for example, with `EADDRINUSE` ([`Socket.errorIsAddressInUse`](Socket#errorIsAddressInUse))
when another socket already has that address and port.

-}
bind : BindOptions -> Task Socket.Error Socket
bind options =
    kUdpBind ( Address.toString options.address, options.port_ )
        ( options.reuseAddress, options.broadcast, options.ipv6Only )
        |> Task.map (\( id, endpoint ) -> Internal.UdpSocket { id = id, endpoint = Internal.toInetEndpoint endpoint })
        |> Task.mapError Internal.toError


{-| Returns the address and port the socket is bound to, read when the socket was bound. For a
socket bound to port 0, the port is the one the operating system chose. An address
[`Socket.Address.fromString`](Socket-Address#fromString) cannot read, which can happen for an
IPv6 address whose scope names an interface with a character other than an ASCII letter or
digit, `_`, `.` or `-` in its name, is reported as the unspecified address.
-}
localEndpoint : Socket -> InetEndpoint
localEndpoint (Internal.UdpSocket s) =
    s.endpoint


{-| Closes the socket.

Waiting [`receive`](#receive) tasks, and sends still waiting to go out, fail with `ECANCELED`,
and held datagrams are dropped. Closing a socket that is already closed does nothing.

-}
close : Socket -> Task x ()
close (Internal.UdpSocket s) =
    kUdpClose s.id
        |> Task.mapError never



-- SENDING AND RECEIVING


{-| Sends one datagram holding `data` to the endpoint `to`.

The task succeeds once the operating system has accepted the datagram, which does not mean that
it arrived.

An IPv6 destination on an IPv4 socket fails with `EAFNOSUPPORT`. An IPv4 destination on an IPv6
socket is sent to its IPv4-mapped address, which works only when the socket was bound with
`ipv6Only = False`; otherwise the send fails with the operating system's error. A datagram too
large for the operating system to send fails, usually with `EMSGSIZE`; over IPv4 no datagram can
carry more than 65 507 bytes.

-}
send : InetEndpoint -> Bytes -> Socket -> Task Socket.Error ()
send to data (Internal.UdpSocket s) =
    kUdpSend ( Address.toString to.address, to.port_ ) data s.id
        |> Task.mapError Internal.toError


{-| Waits for the socket's next datagram.

A held datagram, the oldest first, is returned at once. Otherwise the task waits, and a new
datagram goes to the oldest waiting `receive` before any [`onMessage`](#onMessage) subscription
sees it.

Fails with `ECANCELED` ([`Socket.errorIsCancelled`](Socket#errorIsCancelled)) when the socket is
closed while the task waits, and at once on a socket that is already closed.

-}
receive : Socket -> Task Socket.Error Datagram
receive (Internal.UdpSocket s) =
    kUdpReceive s.id
        |> Task.map toDatagram
        |> Task.mapError Internal.toError


{-| Creates a subscription to the datagrams the socket receives that no waiting
[`receive`](#receive) takes, including those held before the subscription started.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Socket.Udp.onMessage model.socket GotDatagram

A subscription made to a socket that is already closed never fires.

-}
onMessage : Socket -> (Datagram -> msg) -> Sub msg
onMessage (Internal.UdpSocket s) toMsg =
    subscription (OnMessage s.id (\arg -> toMsg (toDatagram arg)))


{-| Builds a `Datagram` from a kernel's DgramT, `( data, ( fromAddress, fromPort ) )`, decoding the
sender with `Socket.Internal.toInetEndpoint`.
-}
toDatagram : DatagramArg -> Datagram
toDatagram ( data, from ) =
    { data = data, from = Internal.toInetEndpoint from }



-- MULTICAST


{-| Joins a multicast group on one network interface, or with `Nothing` on one the operating
system chooses, so that the socket can receive the datagrams sent to the group at the port it is
bound to.

The interface is given as an address of the group's family; one of the other family fails with
`EINVAL`. For IPv4 it is an address of the interface. For IPv6 it is the address's scope that
names the interface, by name or by index, and the address bits are ignored, so `"::%lo"` names
the interface `lo`. With `Nothing`, an IPv6 group's own scope, if it has one, names the
interface instead. An IPv6 interface address with no scope leaves the choice to the operating
system, and the group's own scope is then not used.

-}
joinMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
joinMulticast =
    membership True


{-| Leaves a multicast group joined with [`joinMulticast`](#joinMulticast), given the same group
and interface.
-}
leaveMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
leaveMulticast =
    membership False


{-| Joins (`join = True`) or leaves the multicast group on the socket, sending the interface as
the empty text when it is `Nothing`.
-}
membership : Bool -> Address -> Maybe Address -> Socket -> Task Socket.Error ()
membership join group interface (Internal.UdpSocket s) =
    kUdpMembership join
        (Address.toString group)
        (interface |> Maybe.map Address.toString |> Maybe.withDefault "")
        s.id
        |> Task.mapError Internal.toError



-- EFFECT MANAGER
--
-- The Elm manager below runs only on the JavaScript backend. The native backend ignores it
-- and runs the C++ manager registered as "Socket.Udp" (src/eco-system/Socket/UdpManager.cpp),
-- which reads `MySub` values by constructor layout: UdpManager.hpp mirrors `OnMessage` and its
-- two fields, so the two must be kept in sync.


{-| A subscription to the datagrams of the socket with the given id, with the tagger that turns
the kernel's DgramT into a message.
-}
type MySub msg
    = OnMessage Int (DatagramArg -> msg)


{-| A datagram as the kernel hands it over, the DgramT: `( data, ( fromAddress, fromPort ) )`,
the sender's address as text.
-}
type alias DatagramArg =
    ( Bytes, ( String, Int ) )


{-| Applies `f` to the messages a subscription produces, keeping its socket id.
-}
subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnMessage id tagger) =
    OnMessage id (tagger >> f)


{-| The manager's state: for each socket id that has subscriptions, its taggers in subscription
order and the process running its listener binding.
-}
type alias State msg =
    Dict Int (SocketSubs msg)


{-| The subscriptions to one socket: their taggers, in subscription order, and the process that
runs `kAttachMessageListener` for that socket while they exist.
-}
type alias SocketSubs msg =
    { taggers : List (DatagramArg -> msg)
    , listener : Process.Id
    }


{-| A message from a listener binding to the manager: `Incoming id datagram` is a datagram the
socket with that id received.
-}
type Event
    = Incoming Int DatagramArg


{-| The manager's starting state: no subscriptions.
-}
init : Task Never (State msg)
init =
    Task.succeed Dict.empty


{-| Brings the listener bindings in line with the current subscriptions.

Each socket that lost its last subscription has its binding process killed, so its later
datagrams go back to the kernel's rule: a waiting `receive`, or else held. Each socket with
subscriptions keeps its process, or gets a newly spawned one that sends every datagram it
receives back to the manager as an `Incoming` event. The new state holds every subscribed
socket's taggers.

-}
onEffects : Platform.Router msg Event -> List (MySub msg) -> State msg -> Task Never (State msg)
onEffects router subs state =
    let
        -- Effects arrive in reverse order of declaration.
        grouped =
            List.foldr
                (\(OnMessage id tagger) dict ->
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
                                Process.spawn (kAttachMessageListener id (\arg -> Platform.sendToSelf router (Incoming id arg)))
                                    |> Task.map (\pid -> ( id, { taggers = taggers, listener = pid } ))
                    )
    in
    Task.sequence stopped
        |> Task.andThen (\_ -> Task.sequence running)
        |> Task.map Dict.fromList


{-| Sends a datagram a socket received to the program, once through each of that socket's
taggers, in subscription order, so every subscriber gets the same `Datagram`.

If the socket has no subscriptions any more, the datagram is handed back to the kernel with
`kHoldDatagram`, which gives it to a waiting `receive`, holds it, or drops it when the socket
has been closed.

-}
onSelfMsg : Platform.Router msg Event -> Event -> State msg -> Task Never (State msg)
onSelfMsg router (Incoming id arg) state =
    case Dict.get id state of
        Just entry ->
            entry.taggers
                |> List.map (\tagger -> Platform.sendToApp router (tagger arg))
                |> Task.sequence
                |> Task.map (\_ -> state)

        Nothing ->
            -- The last subscriber went away after the listener sent this datagram.
            kHoldDatagram id arg
                |> Task.map (\_ -> state)



-- KERNELS
-- The annotations fix the kernel ABI: the kernels rely on exactly these argument and result
-- shapes. A failure is an FErr, `( code, message )`.


{-| Asks the kernel to bind a new socket to `( address, port )` with the settings
`( reuseAddress, broadcast, ipv6Only )`, succeeding with the socket's id and its bound
`( address, port )`.
-}
kUdpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task ( String, String ) ( Int, ( String, Int ) )
kUdpBind =
    Eco.Kernel.Socket.udpBind


{-| Asks the kernel to send the bytes to `( address, port )` from the socket with the given id.
-}
kUdpSend : ( String, Int ) -> Bytes -> Int -> Task ( String, String ) ()
kUdpSend =
    Eco.Kernel.Socket.udpSend


{-| Asks the kernel for the next datagram of the socket with the given id, as a DgramT.
-}
kUdpReceive : Int -> Task ( String, String ) DatagramArg
kUdpReceive =
    Eco.Kernel.Socket.udpReceive


{-| Asks the kernel to close the socket with the given id.
-}
kUdpClose : Int -> Task Never ()
kUdpClose =
    Eco.Kernel.Socket.udpClose


{-| Asks the kernel to join (`True`) or leave a multicast group, given as text, on the socket
with the given id. The interface is an address's text, or the empty text for none.
-}
kUdpMembership : Bool -> String -> String -> Int -> Task ( String, String ) ()
kUdpMembership =
    Eco.Kernel.Socket.udpMembership



-- JavaScript-only kernels, used by the effect-manager bodies above. The native backend does not
-- run those bodies, so these have no C++ counterpart.


{-| Returns a task that never completes and, while it runs, passes every datagram of the socket
with the given id that no waiting `receive` takes, starting with those already held, to the
given function. Killing its process stops this, and later datagrams are held again. On an
unknown or closed socket it delivers nothing.
-}
kAttachMessageListener : Int -> (DatagramArg -> Task Never ()) -> Task Never ()
kAttachMessageListener =
    Eco.Kernel.Socket.attachMessageListener


{-| Hands a datagram back to the kernel's delivery rule for the socket with the given id: a
waiting `receive`, a new listener binding, or the held datagrams, in the order the datagrams
arrived. On an unknown or closed socket the datagram is dropped.
-}
kHoldDatagram : Int -> DatagramArg -> Task Never ()
kHoldDatagram =
    Eco.Kernel.Socket.holdDatagram
