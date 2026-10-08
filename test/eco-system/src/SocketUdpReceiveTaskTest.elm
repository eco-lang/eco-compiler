module SocketUdpReceiveTaskTest exposing (main)

{-| Task-only UDP receiving (plans/eco-system-sockets.md §4 S4, SD14): datagrams sent before
anyone receives are held and handed to later `Socket.Udp.receive` tasks in order; a parked
`receive` gets the next datagram.
-}

-- CHECK: held 1: one
-- CHECK: held 2: two
-- CHECK: parked: three
-- CHECK: sender is a: True
-- EXIT: 0

import Process
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr (Task.map2 Tuple.pair U.bindLocal U.bindLocal)
                |> Task.andThen
                    (\( a, b ) ->
                        let
                            toB =
                                Socket.Udp.localEndpoint b
                        in
                        U.sendText toB "one" a
                            |> Task.andThen (\_ -> U.sendText toB "two" a)
                            |> Task.andThen (\_ -> Process.sleep 200)
                            |> Task.andThen (\_ -> U.receiveText b)
                            |> Task.andThen
                                (\( first, from ) ->
                                    U.receiveText b
                                        |> Task.andThen
                                            (\( second, _ ) ->
                                                H.async (U.receiveText b)
                                                    |> Task.andThen
                                                        (\parked ->
                                                            Process.sleep 50
                                                                |> Task.andThen (\_ -> U.sendText toB "three" a)
                                                                |> Task.andThen (\_ -> parked)
                                                        )
                                                    |> Task.andThen
                                                        (\( third, _ ) ->
                                                            U.closeAll [ a, b ]
                                                                |> Task.map
                                                                    (\_ ->
                                                                        [ "held 1: " ++ first
                                                                        , "held 2: " ++ second
                                                                        , "parked: " ++ third
                                                                        , "sender is a: " ++ H.boolString (U.sameEndpoint from (Socket.Udp.localEndpoint a))
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
