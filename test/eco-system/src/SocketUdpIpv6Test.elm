module SocketUdpIpv6Test exposing (main)

{-| UDP over IPv6 (plans/eco-system-sockets.md §4 S4, §D.4, R2): an exchange over `::1` prints
`ipv6: ok`, or `ipv6: unavailable <code>` where the machine has no IPv6. A dual-stack socket bound
to `any IPv6` sends to `127.0.0.1` (sent to `::ffff:127.0.0.1`, §D.4) and reaches an IPv4 socket,
which sees the sender as `127.0.0.1`; its reply arrives from an IPv4-mapped address that
`unmapIPv4` turns into `127.0.0.1`. An IPv6 destination on an IPv4 socket fails with
`EAFNOSUPPORT`.
-}

-- CHECK: {{ipv6: (ok|unavailable \w+)}}
-- CHECK: {{v4 from v6 socket: (ok from 127.0.0.1 reply mapped True unmapped 127.0.0.1|unavailable \w+)}}
-- CHECK: v6 destination on v4 socket: err EAFNOSUPPORT
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task exposing (Task)


unavailable : Task Socket.Error a -> Task String a
unavailable =
    Task.mapError (\e -> "unavailable " ++ Socket.errorCode e)


overLoopback : Task String String
overLoopback =
    unavailable (Task.map2 Tuple.pair (U.bindOn (Address.loopback IPv6)) (U.bindOn (Address.loopback IPv6)))
        |> Task.andThen
            (\( a, b ) ->
                unavailable (Socket.Udp.send (Socket.Udp.localEndpoint b) (H.bytesOf "six") a)
                    |> Task.andThen (\_ -> U.receiveText b)
                    |> Task.andThen
                        (\( text, from ) ->
                            U.closeAll [ a, b ]
                                |> Task.map
                                    (\_ ->
                                        if text == "six" && U.sameEndpoint from (Socket.Udp.localEndpoint a) then
                                            "ok"

                                        else
                                            "wrong " ++ text ++ " from " ++ U.endpointString from
                                    )
                        )
            )


dualStack : Task String String
dualStack =
    unavailable (U.bindOn (Address.any IPv6))
        |> Task.andThen
            (\six ->
                H.socketErr U.bindLocal
                    |> Task.andThen
                        (\four ->
                            let
                                toFour =
                                    { address = Address.loopback IPv4, port_ = (Socket.Udp.localEndpoint four).port_ }
                            in
                            unavailable (Socket.Udp.send toFour (H.bytesOf "mapped") six)
                                |> Task.andThen (\_ -> U.receiveText four)
                                |> Task.andThen
                                    (\( _, from ) ->
                                        U.sendText from "reply" four
                                            |> Task.andThen (\_ -> U.receiveText six)
                                            |> Task.map
                                                (\( _, replyFrom ) ->
                                                    "ok from "
                                                        ++ Address.toString from.address
                                                        ++ " reply mapped "
                                                        ++ H.boolString (Address.isIPv4Mapped replyFrom.address)
                                                        ++ " unmapped "
                                                        ++ Address.toString (Address.unmapIPv4 replyFrom.address)
                                                )
                                    )
                                |> Task.andThen (\line -> U.closeAll [ six, four ] |> Task.map (\_ -> line))
                        )
            )


v6OnV4 : Task String String
v6OnV4 =
    H.socketErr U.bindLocal
        |> Task.andThen
            (\four ->
                H.describe (Socket.Udp.send { address = Address.loopback IPv6, port_ = 9 } (H.bytesOf "x") four)
                    |> Task.andThen (\r -> U.closeAll [ four ] |> Task.map (\_ -> r))
            )


orReason : Task String String -> Task x String
orReason task =
    Task.onError Task.succeed task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            orReason overLoopback
                |> Task.andThen
                    (\v6 ->
                        orReason dualStack
                            |> Task.andThen
                                (\dual ->
                                    orReason v6OnV4
                                        |> Task.map
                                            (\cross ->
                                                [ "ipv6: " ++ v6
                                                , "v4 from v6 socket: " ++ dual
                                                , "v6 destination on v4 socket: " ++ cross
                                                ]
                                            )
                                )
                    )
        )
