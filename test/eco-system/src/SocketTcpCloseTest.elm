module SocketTcpCloseTest exposing (main)

{-| `Socket.close` (plans/eco-system-sockets.md §D.2): a read parked on the closed connection fails
with the reason `socket closed`; data written before the close still reaches the peer, which then
reads to `Closed`; later operations on the streams fail `socket closed`; closing twice is fine.
-}

-- CHECK: parked read: Cancelled: {{socket closed}}
-- CHECK: peer read: written before close
-- CHECK: write after close: Cancelled: {{socket closed}}
-- CHECK: read after close: Cancelled: {{socket closed}}
-- CHECK: close twice: ok
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
                                    H.async (result (Stream.read (Socket.readable client)) |> Task.mapError never)
                                        |> Task.andThen
                                            (\parked ->
                                                H.streamErr (Stream.write (H.bytesOf "written before close") (Socket.writable client))
                                                    |> Task.andThen (\_ -> Process.sleep 100)
                                                    |> Task.andThen (\_ -> Socket.close client)
                                                    |> Task.andThen (\_ -> Socket.close client)
                                                    |> Task.andThen (\_ -> parked)
                                                    |> Task.andThen
                                                        (\parkedResult ->
                                                            H.streamErr (H.readAll (Socket.readable server))
                                                                |> Task.andThen
                                                                    (\peer ->
                                                                        result (Stream.write (H.bytesOf "late") (Socket.writable client))
                                                                            |> Task.andThen
                                                                                (\lateWrite ->
                                                                                    result (Stream.read (Socket.readable client))
                                                                                        |> Task.map
                                                                                            (\lateRead ->
                                                                                                [ "parked read: " ++ parkedResult
                                                                                                , "peer read: " ++ peer
                                                                                                , "write after close: " ++ lateWrite
                                                                                                , "read after close: " ++ lateRead
                                                                                                , "close twice: ok"
                                                                                                ]
                                                                                            )
                                                                                )
                                                                    )
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
