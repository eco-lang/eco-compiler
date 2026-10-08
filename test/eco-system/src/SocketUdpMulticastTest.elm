module SocketUdpMulticastTest exposing (main)

{-| IPv4 multicast membership (plans/eco-system-sockets.md §3.3.5, R2): joining and leaving
`239.255.0.1` on the loopback interface (`Just (loopback IPv4)`) succeed; leaving it again fails
with `EADDRNOTAVAIL`.
-}

-- CHECK: join: ok
-- CHECK: leave: ok
-- CHECK: leave again: err EADDRNOTAVAIL
-- EXIT: 0

import Socket.Address as Address exposing (Family(..))
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            let
                options =
                    Socket.Udp.defaultBindOptions (Address.any IPv4) 0

                group =
                    Address.fromString "239.255.0.1" |> Maybe.withDefault (Address.any IPv4)

                interface =
                    Just (Address.loopback IPv4)
            in
            H.socketErr (Socket.Udp.bind { options | reuseAddress = True })
                |> Task.andThen
                    (\socket ->
                        H.describe (Socket.Udp.joinMulticast group interface socket)
                            |> Task.andThen
                                (\join ->
                                    H.describe (Socket.Udp.leaveMulticast group interface socket)
                                        |> Task.andThen
                                            (\leave ->
                                                H.describe (Socket.Udp.leaveMulticast group interface socket)
                                                    |> Task.andThen
                                                        (\again ->
                                                            U.closeAll [ socket ]
                                                                |> Task.map
                                                                    (\_ ->
                                                                        [ "join: " ++ join
                                                                        , "leave: " ++ leave
                                                                        , "leave again: " ++ again
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
