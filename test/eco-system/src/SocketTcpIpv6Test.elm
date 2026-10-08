module SocketTcpIpv6Test exposing (main)

{-| IPv6 (plans/eco-system-sockets.md §4 S3, R2): an echo over `::1` prints `ipv6: ok`, or
`ipv6: unavailable <code>` where the machine has no IPv6. A dual-stack listener on `any IPv6`
accepts an IPv4 client, whose remote address is IPv4-mapped; `unmapIPv4` turns it into
`127.0.0.1`.
-}

-- CHECK: {{ipv6: (ok|unavailable \w+)}}
-- CHECK: {{dual-stack: (mapped True unmapped 127.0.0.1|unavailable \w+)}}
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Endpoint(..), Family(..))
import Socket.Tcp
import SocketTestHelp as H
import System
import Task exposing (Task)


echoOver : Family -> Task String String
echoOver family =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback family) 0)
        |> Task.mapError (\e -> "unavailable " ++ Socket.errorCode e)
        |> Task.andThen
            (\listener ->
                H.async (H.acceptRead listener)
                    |> Task.andThen
                        (\accepted ->
                            Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback family) (H.portOf listener))
                                |> Task.mapError (\e -> "unavailable " ++ Socket.errorCode e)
                                |> Task.andThen (\c -> H.streamErr (H.writeAll "six" (Socket.writable c)))
                                |> Task.andThen (\_ -> accepted)
                        )
                    |> Task.andThen
                        (\got ->
                            H.socketErr (Socket.closeListener listener)
                                |> Task.map
                                    (\_ ->
                                        if got == "six" then
                                            "ok"

                                        else
                                            "wrong data " ++ got
                                    )
                        )
            )


dualStack : Task String String
dualStack =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.any IPv6) 0)
        |> Task.mapError (\e -> "unavailable " ++ Socket.errorCode e)
        |> Task.andThen
            (\listener ->
                H.async (H.socketErr (Socket.accept listener))
                    |> Task.andThen
                        (\accepted ->
                            H.socketErr (Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (H.portOf listener)))
                                |> Task.andThen (\c -> accepted |> Task.map (\s -> ( c, s )))
                        )
                    |> Task.andThen
                        (\( c, s ) ->
                            let
                                line =
                                    case Socket.remoteEndpoint s of
                                        Inet ep ->
                                            "mapped "
                                                ++ H.boolString (Address.isIPv4Mapped ep.address)
                                                ++ " unmapped "
                                                ++ Address.toString (Address.unmapIPv4 ep.address)

                                        Unix _ ->
                                            "unix?!"
                            in
                            Socket.close c
                                |> Task.andThen (\_ -> Socket.close s)
                                |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                |> Task.map (\_ -> line)
                        )
            )


orReason : Task String String -> Task x String
orReason task =
    Task.onError Task.succeed task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            orReason (echoOver IPv6)
                |> Task.andThen
                    (\v6 ->
                        orReason dualStack
                            |> Task.map (\dual -> [ "ipv6: " ++ v6, "dual-stack: " ++ dual ])
                    )
        )
