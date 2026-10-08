module SocketUdpTestHelp exposing
    ( bindLocal, bindOn, endpointString, sameEndpoint, sendText, receiveText, closeAll
    )

{-| Shared helpers for the UDP socket tests (not a test: no `main`; plans/eco-system-sockets.md
§4 S4). Everything else comes from `SocketTestHelp`.
-}

import Socket
import Socket.Address as Address exposing (Address, Family(..), InetEndpoint)
import Socket.Udp
import SocketTestHelp as H
import Task exposing (Task)


{-| Bind a UDP socket on 127.0.0.1 with a port picked by the system.
-}
bindLocal : Task Socket.Error Socket.Udp.Socket
bindLocal =
    bindOn (Address.loopback IPv4)


bindOn : Address -> Task Socket.Error Socket.Udp.Socket
bindOn address =
    Socket.Udp.bind (Socket.Udp.defaultBindOptions address 0)


endpointString : InetEndpoint -> String
endpointString ep =
    Address.toString ep.address ++ " " ++ String.fromInt ep.port_


sameEndpoint : InetEndpoint -> InetEndpoint -> Bool
sameEndpoint a b =
    endpointString a == endpointString b


{-| Send `text` from `socket` to `to`.
-}
sendText : InetEndpoint -> String -> Socket.Udp.Socket -> Task String ()
sendText to text socket =
    H.socketErr (Socket.Udp.send to (H.bytesOf text) socket)


{-| Receive one datagram as text, with its sender.
-}
receiveText : Socket.Udp.Socket -> Task String ( String, InetEndpoint )
receiveText socket =
    H.socketErr (Socket.Udp.receive socket)
        |> Task.map (\d -> ( H.bytesToString d.data, d.from ))


closeAll : List Socket.Udp.Socket -> Task x ()
closeAll sockets =
    Task.sequence (List.map Socket.Udp.close sockets)
        |> Task.map (\_ -> ())
