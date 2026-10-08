module SocketTcpResetTest exposing (main)

{-| `Socket.reset` (plans/eco-system-sockets.md §D.2): the connection is aborted with a TCP reset,
so the peer's parked read fails with `read ECONNRESET`, and its next write fails too (Linux
reports `EPIPE` or `ECONNRESET`).
-}

-- CHECK: peer read: Cancelled: {{read ECONNRESET}}
-- CHECK: peer write: Cancelled: {{write (EPIPE|ECONNRESET)}}
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import Stream
import System
import Task exposing (Task)


result : Task Stream.Error a -> Task x String
result task =
    task
        |> Task.map (\_ -> "ok")
        |> Task.onError (\e -> Task.succeed (Stream.errorToString e))


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        H.async (H.socketErr (Socket.accept listener))
                            |> Task.andThen
                                (\accepted ->
                                    H.socketErr (H.connectTo listener)
                                        |> Task.andThen (\client -> accepted |> Task.map (\server -> ( client, server )))
                                )
                            |> Task.andThen
                                (\( client, server ) ->
                                    H.async (result (Stream.read (Socket.readable server)) |> Task.mapError never)
                                        |> Task.andThen
                                            (\parked ->
                                                Process.sleep 100
                                                    |> Task.andThen (\_ -> Socket.reset client)
                                                    |> Task.andThen (\_ -> parked)
                                                    |> Task.andThen
                                                        (\readResult ->
                                                            result (Stream.write (H.bytesOf "after reset") (Socket.writable server))
                                                                |> Task.map (\writeResult -> [ "peer read: " ++ readResult, "peer write: " ++ writeResult ])
                                                        )
                                            )
                                        |> Task.andThen
                                            (\lines ->
                                                Socket.close server
                                                    |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                                    |> Task.map (\_ -> lines)
                                            )
                                )
                    )
        )
