module SocketCloseListenerTest exposing (main)

{-| `Socket.closeListener` (plans/eco-system-sockets.md §3.3.4, §3.4): a parked `accept` fails with
`ECANCELED` (`errorIsCancelled`); closing twice is fine; `accept` on a closed listener fails the
same way; the port can be listened on again at once; the program then exits by itself.
-}

-- CHECK: parked accept: ECANCELED cancelled True
-- CHECK: close twice: ok ok
-- CHECK: accept after close: ECANCELED
-- CHECK: listen again: ok
-- EXIT: 0

import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import SocketTestHelp as H
import System
import Task


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        H.async
                            (Socket.accept listener
                                |> Task.map (\_ -> "accepted?!")
                                |> Task.onError (\e -> Task.succeed (Socket.errorCode e ++ " cancelled " ++ H.boolString (Socket.errorIsCancelled e)))
                            )
                            |> Task.andThen
                                (\parked ->
                                    Process.sleep 50
                                        |> Task.andThen (\_ -> H.describe (Socket.closeListener listener))
                                        |> Task.andThen
                                            (\first ->
                                                H.describe (Socket.closeListener listener)
                                                    |> Task.andThen
                                                        (\second ->
                                                            parked
                                                                |> Task.andThen
                                                                    (\parkedResult ->
                                                                        H.describe (Socket.accept listener)
                                                                            |> Task.andThen
                                                                                (\after ->
                                                                                    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) (H.portOf listener))
                                                                                        |> H.socketErr
                                                                                        |> Task.andThen (\again -> H.socketErr (Socket.closeListener again))
                                                                                        |> Task.map
                                                                                            (\_ ->
                                                                                                [ "parked accept: " ++ parkedResult
                                                                                                , "close twice: " ++ first ++ " " ++ second
                                                                                                , "accept after close: " ++ String.dropLeft 4 after
                                                                                                , "listen again: ok"
                                                                                                ]
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
