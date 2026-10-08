module SocketUdpLargeTest exposing (main)

{-| The largest IPv4 UDP datagram (plans/eco-system-sockets.md §D.4, N15): 65 507 bytes are sent
and arrive whole; one byte more fails with `EMSGSIZE`.
-}

-- CHECK: size: 65507
-- CHECK: intact: True
-- CHECK: too large: err EMSGSIZE
-- EXIT: 0

import Bytes
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


payload : Int -> String
payload n =
    String.left n (String.repeat (n // 10 + 1) "0123456789")


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr (Task.map2 Tuple.pair U.bindLocal U.bindLocal)
                |> Task.andThen
                    (\( a, b ) ->
                        let
                            big =
                                payload 65507
                        in
                        H.socketErr (Socket.Udp.send (Socket.Udp.localEndpoint b) (H.bytesOf big) a)
                            |> Task.andThen (\_ -> H.socketErr (Socket.Udp.receive b))
                            |> Task.andThen
                                (\d ->
                                    H.describe (Socket.Udp.send (Socket.Udp.localEndpoint b) (H.bytesOf (payload 65508)) a)
                                        |> Task.andThen
                                            (\tooLarge ->
                                                U.closeAll [ a, b ]
                                                    |> Task.map
                                                        (\_ ->
                                                            [ "size: " ++ String.fromInt (Bytes.width d.data)
                                                            , "intact: " ++ H.boolString (H.bytesToString d.data == big)
                                                            , "too large: " ++ tooLarge
                                                            ]
                                                        )
                                            )
                                )
                    )
        )
