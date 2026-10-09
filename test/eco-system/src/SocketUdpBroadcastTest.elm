module SocketUdpBroadcastTest exposing (main)

{-| Broadcast needs the `broadcast` bind option (plans/eco-system-sockets.md §3.3.7, SF17): a send
to `127.255.255.255` from a socket bound without it fails with `EACCES`
(`errorIsPermissionDenied`); with it the send succeeds. macOS loopback (`lo0`) has no broadcast
address, so there the send is plain unicast that succeeds either way, reported as `n/a on Darwin`.
-}

-- CHECK: without broadcast: {{(err EACCES denied True|n/a on Darwin)}}
-- CHECK: with broadcast: ok
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\env ->
            H.testPort
                |> Task.andThen
                    (\port_ ->
                        let
                            to =
                                { address = Address.fromString "127.255.255.255" |> Maybe.withDefault (Address.loopback IPv4)
                                , port_ = port_
                                }

                            options =
                                Socket.Udp.defaultBindOptions (Address.loopback IPv4) 0
                        in
                        H.socketErr
                            (Task.map2 Tuple.pair
                                (Socket.Udp.bind options)
                                (Socket.Udp.bind { options | broadcast = True })
                            )
                            |> Task.andThen
                                (\( plain, bcast ) ->
                                    (Socket.Udp.send to (H.bytesOf "hello all") plain
                                        |> Task.map (\_ -> "ok")
                                        |> Task.onError
                                            (\e ->
                                                Task.succeed
                                                    ("err " ++ Socket.errorCode e ++ " denied " ++ H.boolString (Socket.errorIsPermissionDenied e))
                                            )
                                    )
                                        |> Task.andThen
                                            (\without ->
                                                H.describe (Socket.Udp.send to (H.bytesOf "hello all") bcast)
                                                    |> Task.andThen
                                                        (\with ->
                                                            U.closeAll [ plain, bcast ]
                                                                |> Task.map
                                                                    (\_ ->
                                                                        [ "without broadcast: " ++ unlessDarwinLoopback env.platform without
                                                                        , "with broadcast: " ++ with
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )


unlessDarwinLoopback : System.Platform -> String -> String
unlessDarwinLoopback platform without =
    if platform == System.Darwin && without == "ok" then
        "n/a on Darwin"

    else
        without
