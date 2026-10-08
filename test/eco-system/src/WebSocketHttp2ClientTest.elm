module WebSocketHttp2ClientTest exposing (main)

{-| The WebSocket client over HTTP/2 (`http2 = True`, RFC 8441; plans/eco-system-websockets.md W12,
§3.9, §4 WS9):

  - against our server with `http2`: ALPN `h2`, the server's SETTINGS allow extended CONNECT, so
    the WebSocket runs on an HTTP/2 stream (the server sees an `Http2` upgrade request); echo and
    a clean close; a 4 MiB message and 512 KiB of text sent at once and echoed (HTTP/2 flow
    control: 64 KiB stream windows, the codec's write backpressure);
  - against an HTTPS server without `http2` (ALPN `http/1.1`): the HTTP/1.1 handshake on the same
    connection (`Http1_1`);
  - without `http2`, against the HTTP/2 server: HTTP/1.1 (`Http1_1`);
  - against a Node HTTP/2 server whose SETTINGS do not allow extended CONNECT (`allowHTTP1`): the
    client leaves the h2 session (GOAWAY NO_ERROR) and dials again over HTTP/1.1, within the same
    timeout; the WebSocket works (frames masked).

-}

-- CHECK: server: upgrade /h2 Http2
-- CHECK: server: ws /h2: Closed | Normal "" clean True
-- CHECK: server: upgrade /h1only Http1_1
-- CHECK: server: ws /h1only: Closed | Normal "" clean True
-- CHECK: server: upgrade /noh2 Http1_1
-- CHECK: server: ws /noh2: Closed | Normal "" clean True
-- CHECK: client: h2 to h2: Text "hello" | Binary [1,2,3] | protocol chat | Normal "" clean True
-- CHECK: server: upgrade /large Http2
-- CHECK: server: ws /large: Closed | Normal "" clean True
-- CHECK: client: h2 large: 4194304 bytes back, 8 texts back | Normal "" clean True
-- CHECK: client: h2 to http/1.1 only: Text "hello" | Binary [1,2,3] | protocol chat | Normal "" clean True
-- CHECK: client: http/1.1 to h2: Text "hello" | Binary [1,2,3] | protocol chat | Normal "" clean True
-- CHECK: client: no extended CONNECT: Text "via http/1.1" | Normal "" clean True
-- CHECK: client: node: listening
-- CHECK: client: node: h2 session
-- CHECK: client: node: h2 goaway from the client NO_ERROR
-- CHECK: client: node: upgrade HTTP/1.1 /x alpn http/1.1
-- CHECK: client: node: client close 1000 masked true
-- CHECK: client: node: upgraded connection closed
-- CHECK-NOT: unexpected h2 stream
-- CHECK-NOT: failed
-- CHECK-NOT: still running
-- EXIT: 0

import Http.Server as Server
import Process
import Socket
import SocketTestHelp as T
import System.File as File
import System.File.Path as Path
import Task exposing (Task)
import WebSocket
import WebSocketH2Help as H
import WebSocketTestHelp as W


{-| A port nobody listens on (a listener's port, closed again).
-}
freePort : Task String Int
freePort =
    T.listenLocal
        |> Task.mapError Socket.errorToString
        |> Task.andThen
            (\l ->
                Socket.closeListener l
                    |> Task.mapError Socket.errorToString
                    |> Task.map (\_ -> T.portOf l)
            )


connectRetry : Int -> Int -> Task String (WebSocket.WebSocket WebSocket.Whole)
connectRetry tries port_ =
    H.wssConnect True port_ "/x"
        |> Task.onError
            (\e ->
                if tries > 0 && String.contains "ECONNREFUSED" e then
                    Process.sleep 100 |> Task.andThen (\_ -> connectRetry (tries - 1) port_)

                else
                    Task.fail e
            )


readLog : Int -> String -> Task String (List String)
readLog tries path =
    File.readFile (Path.fromPosixString path)
        |> Task.mapError File.errorToString
        |> Task.map (\b -> W.latin1 b |> String.lines |> List.filter ((/=) ""))
        |> Task.andThen
            (\lines ->
                -- The file is written when the server exits; read it again until it is complete.
                if tries > 0 && not (List.member "upgraded connection closed" lines || List.any (String.startsWith "node failed") lines) then
                    Task.fail "incomplete"

                else
                    Task.succeed lines
            )
        |> Task.onError
            (\e ->
                if tries > 0 then
                    Process.sleep 100 |> Task.andThen (\_ -> readLog (tries - 1) path)

                else
                    Task.fail ("no log: " ++ e)
            )


{-| The Node server without extended CONNECT runs (spawned) while the client connects; its lines
are written to a file when it exits.
-}
noEcpCase : H.Tools -> Task String (List String)
noEcpCase tools =
    let
        logPath =
            tools.dir ++ "/noecp.log"
    in
    freePort
        |> Task.andThen
            (\port_ ->
                Process.spawn
                    (H.node tools port_ "noecp-server" []
                        |> Task.onError (\e -> Task.succeed [ "node failed " ++ e ])
                        |> Task.andThen (\lines -> H.writeFile logPath (String.join "\n" lines ++ "\n"))
                        |> Task.onError (\_ -> Task.succeed ())
                    )
                    |> Task.andThen (\_ -> connectRetry 50 port_)
                    |> Task.andThen
                        (\ws ->
                            W.readMessages 1 ws
                                |> Task.andThen
                                    (\messages ->
                                        WebSocket.close WebSocket.Normal "" ws
                                            |> Task.mapError W.wsErr
                                            |> Task.andThen (\_ -> WebSocket.closed ws)
                                            |> Task.map
                                                (\info ->
                                                    String.join " | " (List.map W.messageString messages ++ [ W.closeInfoString info ])
                                                )
                                    )
                        )
                    |> Task.onError (\e -> Task.succeed ("failed " ++ e))
                    |> Task.andThen
                        (\line ->
                            readLog 100 logPath
                                |> Task.map (\logLines -> ("no extended CONNECT: " ++ line) :: List.map ((++) "node: ") logLines)
                        )
            )


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        [ h2, h1only ] ->
            Task.sequence
                [ H.echoCase "h2 to h2" True (Server.serverPort h2) "/h2" |> Task.map List.singleton
                , H.largeCase "h2 large" True (Server.serverPort h2) "/large" |> Task.map List.singleton
                , H.echoCase "h2 to http/1.1 only" True (Server.serverPort h1only) "/h1only" |> Task.map List.singleton
                , H.echoCase "http/1.1 to h2" False (Server.serverPort h2) "/noh2" |> Task.map List.singleton
                , noEcpCase tools
                ]
                |> Task.map List.concat

        _ ->
            Task.fail "two servers expected"


main =
    H.program { servers = [ identity, \o -> { o | http2 = False } ], client = client }
