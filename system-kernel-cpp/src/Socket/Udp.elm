effect module Socket.Udp where { subscription = MySub } exposing
    ( Socket, Datagram, BindOptions, defaultBindOptions, bind, localEndpoint
    , send, receive, onMessage, close
    , joinMulticast, leaveMulticast
    )

{-| UDP: datagrams over IPv4 and IPv6.

A UDP socket is bound to a local address and port. It sends datagrams to any address and port,
and receives the datagrams sent to it, each with the endpoint it came from. Datagrams are values,
not streams: each one arrives whole or not at all, and the network may lose, duplicate or reorder
them.

    import Socket.Address as Address exposing (Family(..))
    import Socket.Udp

    socket =
        Socket.Udp.bind (Socket.Udp.defaultBindOptions (Address.loopback IPv4) 0)


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


{-| A bound UDP socket. An open socket keeps the program running until it is [closed](#close).
-}
type alias Socket =
    Internal.UdpSocket


{-| A received datagram: its bytes and the endpoint that sent it.

On a socket bound to an IPv6 address that also receives IPv4 traffic, IPv4 senders are reported
as IPv4-mapped addresses (see [`Socket.Address.unmapIPv4`](Socket-Address#unmapIPv4)).

-}
type alias Datagram =
    { data : Bytes
    , from : InetEndpoint
    }


{-| How to bind.

  - `address` and `port_`: the local address and port. Port 0 lets the operating system pick a
    free port (see [`localEndpoint`](#localEndpoint)); the unspecified address
    (`Socket.Address.any`) receives on every interface.
  - `reuseAddress`: allow other sockets to bind the same address and port (`SO_REUSEADDR`), as
    several multicast receivers on one machine need.
  - `broadcast`: allow sending to broadcast addresses (`SO_BROADCAST`); without it such a send
    fails with `EACCES`.
  - `ipv6Only`: for an IPv6 address, use IPv6 only. When `False`, a socket bound to `any IPv6`
    also sends to and receives from IPv4 endpoints.

-}
type alias BindOptions =
    { address : Address
    , port_ : Int
    , reuseAddress : Bool
    , broadcast : Bool
    , ipv6Only : Bool
    }


{-| Bind to an address and port with every option off.
-}
defaultBindOptions : Address -> Int -> BindOptions
defaultBindOptions address port_ =
    { address = address
    , port_ = port_
    , reuseAddress = False
    , broadcast = False
    , ipv6Only = False
    }


{-| Create a UDP socket bound to an address and port. Fails with, for example, `EADDRINUSE`.
-}
bind : BindOptions -> Task Socket.Error Socket
bind options =
    kUdpBind ( Address.toString options.address, options.port_ )
        ( options.reuseAddress, options.broadcast, options.ipv6Only )
        |> Task.map (\( id, endpoint ) -> Internal.UdpSocket { id = id, endpoint = Internal.toInetEndpoint endpoint })
        |> Task.mapError Internal.toError


{-| The address and port the socket is bound to. When binding to port 0, this tells which port the
operating system picked.
-}
localEndpoint : Socket -> InetEndpoint
localEndpoint (Internal.UdpSocket s) =
    s.endpoint


{-| Close the socket. Waiting [`receive`](#receive) tasks fail with `ECANCELED`, and datagrams that
were received but not yet handed out are dropped. Closing a socket twice is fine.
-}
close : Socket -> Task x ()
close (Internal.UdpSocket s) =
    kUdpClose s.id
        |> Task.mapError never



-- SENDING AND RECEIVING


{-| Send one datagram to an endpoint. The task succeeds once the operating system has accepted the
datagram, which does not mean it arrived.

An IPv4 destination on a socket bound to an IPv6 address is sent to its IPv4-mapped address; an
IPv6 destination on an IPv4 socket fails with `EAFNOSUPPORT`. A datagram larger than the network
allows (65 507 bytes over IPv4) fails with `EMSGSIZE`.

-}
send : InetEndpoint -> Bytes -> Socket -> Task Socket.Error ()
send to data (Internal.UdpSocket s) =
    kUdpSend ( Address.toString to.address, to.port_ ) data s.id
        |> Task.mapError Internal.toError


{-| Wait for the next datagram.

Datagrams are handed out in the order they arrive: one that arrived while nobody was receiving or
subscribed is held (up to 64; beyond that the oldest are dropped) and given to the next `receive`
(or [`onMessage`](#onMessage) subscription). When `receive` tasks are waiting and a subscription
exists too, a new datagram goes to the oldest waiting `receive`.

Fails with `ECANCELED` when the socket is closed.

-}
receive : Socket -> Task Socket.Error Datagram
receive (Internal.UdpSocket s) =
    kUdpReceive s.id
        |> Task.map toDatagram
        |> Task.mapError Internal.toError


{-| Subscribe to the datagrams a socket receives. Every subscription to the same socket receives
every datagram. A subscription to a closed socket never fires.

    subscriptions : Model -> Sub Msg
    subscriptions model =
        Socket.Udp.onMessage model.socket GotDatagram

-}
onMessage : Socket -> (Datagram -> msg) -> Sub msg
onMessage (Internal.UdpSocket s) toMsg =
    subscription (OnMessage s.id (\arg -> toMsg (toDatagram arg)))


toDatagram : DatagramArg -> Datagram
toDatagram ( data, from ) =
    { data = data, from = Internal.toInetEndpoint from }



-- MULTICAST


{-| Join a multicast group, to receive the datagrams sent to it, on one interface (`Just`) or on
the interface the system picks (`Nothing`).

The interface is given as an address: for IPv4, an address of the interface; for IPv6, an address
whose scope names the interface (for example `"::%lo"`), the address bits being ignored.

-}
joinMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
joinMulticast =
    membership True


{-| Leave a multicast group joined with [`joinMulticast`](#joinMulticast), with the same group and
interface.
-}
leaveMulticast : Address -> Maybe Address -> Socket -> Task Socket.Error ()
leaveMulticast =
    membership False


membership : Bool -> Address -> Maybe Address -> Socket -> Task Socket.Error ()
membership join group interface (Internal.UdpSocket s) =
    kUdpMembership join
        (Address.toString group)
        (interface |> Maybe.map Address.toString |> Maybe.withDefault "")
        s.id
        |> Task.mapError Internal.toError



-- EFFECT MANAGER
--
-- The native backend runs the C++ manager registered as "Socket.Udp"
-- (src/eco-system/Socket/UdpManager.{hpp,cpp}, plans/eco-system-sockets.md §3.5 and
-- Appendix C.2) and ignores the Elm functions below. The JS backend runs them (D15,
-- Appendix E): every socket with subscribers keeps one listener process (a
-- never-completing kernel binding, killed when the socket's last subscription goes away)
-- that notifies the manager through `Platform.sendToSelf`; the manager hands each datagram
-- to every tagger of that socket (§3.4: the kernel gives a datagram to a parked `receive`
-- first and holds it when nobody listens). A datagram that arrives after the last
-- subscription went away goes back to the kernel (`kHoldDatagram`). The constructor layout
-- of MySub is mirrored by UdpManager.hpp: keep them in sync. The tagger argument is DgramT
-- (§3.2): ( data, ( fromAddress, fromPort ) ).


type MySub msg
    = OnMessage Int (DatagramArg -> msg)


type alias DatagramArg =
    ( Bytes, ( String, Int ) )


subMap : (a -> b) -> MySub a -> MySub b
subMap f (OnMessage id tagger) =
    OnMessage id (tagger >> f)


{-| Per socket id: its taggers in subscription order, and the process running its kernel
listener.
-}
type alias State msg =
    Dict Int (SocketSubs msg)


type alias SocketSubs msg =
    { taggers : List (DatagramArg -> msg)
    , listener : Process.Id
    }


type Event
    = Incoming Int DatagramArg


init : Task Never (State msg)
init =
    Task.succeed Dict.empty


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
-- The annotations fix the kernel ABI (plans/eco-system-sockets.md Appendix B.2).


kUdpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task ( String, String ) ( Int, ( String, Int ) )
kUdpBind =
    Eco.Kernel.Socket.udpBind


kUdpSend : ( String, Int ) -> Bytes -> Int -> Task ( String, String ) ()
kUdpSend =
    Eco.Kernel.Socket.udpSend


kUdpReceive : Int -> Task ( String, String ) DatagramArg
kUdpReceive =
    Eco.Kernel.Socket.udpReceive


kUdpClose : Int -> Task Never ()
kUdpClose =
    Eco.Kernel.Socket.udpClose


kUdpMembership : Bool -> String -> String -> Int -> Task ( String, String ) ()
kUdpMembership =
    Eco.Kernel.Socket.udpMembership



-- JS-only kernels, for the effect-manager bodies (S6; plans/eco-system-sockets.md Appendix E).
-- The native backend drops those bodies, so these have no C++ counterpart.


kAttachMessageListener : Int -> (DatagramArg -> Task Never ()) -> Task Never ()
kAttachMessageListener =
    Eco.Kernel.Socket.attachMessageListener


kHoldDatagram : Int -> DatagramArg -> Task Never ()
kHoldDatagram =
    Eco.Kernel.Socket.holdDatagram
