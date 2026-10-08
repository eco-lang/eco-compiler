module SocketTlsBulkTest exposing (main)

{-| 8 MiB through a TLS connection whose reader starts late (plans/eco-system-sockets.md §3.6,
§3.3.3): the socket buffers fill, so encrypted records wait in the transport (the writes are
paced by the socket). The client then ends its side with `Stream.cancelWritable` (a write-face
shutdown): the `close_notify` and the FIN follow whatever records are still queued, without
further requests. The server reads every byte, then `Closed`, and replies.
-}

-- CHECK: server read bytes: 8388608
-- CHECK: client got: got 8388608
-- CHECK: closed: ok
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode
import Process
import Socket
import SocketTestHelp as H
import SocketTlsHelp as T
import Stream
import System
import Task exposing (Task)


chunk : Bytes
chunk =
    Bytes.Encode.encode (Bytes.Encode.string (String.repeat 1048576 "x"))


{-| Read to `Closed`, pausing after every chunk, and count the bytes.
-}
countBytes : Stream.Readable Bytes -> Task Stream.Error Int
countBytes =
    Stream.readUntilClosed (\b n -> Ok (n + Bytes.width b)) 0


serve : Socket.Listener -> Task String Int
serve listener =
    H.socketErr (Socket.accept listener)
        |> Task.andThen
            (\conn ->
                Process.sleep 300
                    |> Task.andThen (\_ -> H.streamErr (countBytes (Socket.readable conn)))
                    |> Task.andThen
                        (\n ->
                            H.streamErr (H.writeAll ("got " ++ String.fromInt n) (Socket.writable conn))
                                |> Task.map (\_ -> n)
                        )
            )


writeChunks : Int -> Stream.Writable Bytes -> Task Stream.Error ()
writeChunks n w =
    if n <= 0 then
        Task.succeed ()

    else
        Stream.write chunk w |> Task.andThen (\_ -> writeChunks (n - 1) w)


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr (T.listenTls (T.server []))
                |> Task.andThen
                    (\listener ->
                        H.async (serve listener)
                            |> Task.andThen
                                (\served ->
                                    H.socketErr (T.connectTls (T.trusted "localhost" []) listener)
                                        |> Task.andThen
                                            (\client ->
                                                H.streamErr (writeChunks 8 (Socket.writable client))
                                                    |> Task.andThen (\_ -> H.streamErr (Stream.cancelWritable "done" (Socket.writable client)))
                                                    |> Task.andThen (\_ -> H.streamErr (H.readAll (Socket.readable client)))
                                            )
                                        |> Task.andThen
                                            (\reply ->
                                                served
                                                    |> Task.andThen
                                                        (\n ->
                                                            H.describe (Socket.closeListener listener)
                                                                |> Task.map
                                                                    (\closed ->
                                                                        [ "server read bytes: " ++ String.fromInt n
                                                                        , "client got: " ++ reply
                                                                        , "closed: " ++ closed
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )
