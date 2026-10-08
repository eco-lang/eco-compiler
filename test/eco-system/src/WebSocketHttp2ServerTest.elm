module WebSocketHttp2ServerTest exposing (main)

{-| WebSockets over HTTP/2 in `Http.Server` (RFC 8441; plans/eco-system-websockets.md §3.9, §4
WS9), against a Node `http2` client that writes WebSocket frames by hand on extended CONNECT
streams:

  - `echo`: the server's SETTINGS allow extended CONNECT; `upgradeRequest` gives an HTTP/2
    `Upgrade`; `accept` answers 200 with the chosen protocol; text and binary are echoed (server
    frames unmasked); the client's Close is answered, the server then ends the stream
    (END_STREAM) and, when the client ends its side, the stream closes without error.
  - `quiet`: a client that answers no ping: the heartbeat (200 ms / 200 ms) fails the WebSocket
    (Close 1001, END_STREAM, `Abnormal`); as the client never ends its side, the stream is reset
    with CANCEL after the drain time (the abort).
  - `reset`: the client resets the stream (CANCEL) after one echo: the server's WebSocket ends
    `Abnormal`.
  - `reject`: `WebSocket.reject 403` answers the stream as an ordinary response.
  - `unknown`: an extended CONNECT with another `:protocol` is answered 501 by the server; the
    program never sees it.

-}

-- CHECK: server: upgrade /echo Http2
-- CHECK: server: ws /echo: Closed | Normal "bye" clean True
-- CHECK: server: upgrade /quiet Http2
-- CHECK: server: ws /quiet: Abnormal "" clean False
-- CHECK: server: upgrade /reset Http2
-- CHECK: server: ws /reset: {{.*}} | Abnormal "" clean False
-- CHECK: server: upgrade /reject Http2
-- CHECK: server: rejected /reject
-- CHECK: client: echo: enableConnectProtocol true
-- CHECK: client: echo: status 200 protocol chat
-- CHECK: client: echo: text hello
-- CHECK: client: echo: binary 010203
-- CHECK: client: echo: close 1000
-- CHECK: client: echo: server END_STREAM
-- CHECK: client: echo: stream closed NO_ERROR
-- CHECK: client: quiet: status 200
-- CHECK: client: quiet: ping (not answered)
-- CHECK: client: quiet: close 1001
-- CHECK: client: quiet: server END_STREAM
-- CHECK: client: quiet: stream closed CANCEL
-- CHECK: client: reset: status 200
-- CHECK: client: reset: text one
-- CHECK: client: reset: stream closed CANCEL
-- CHECK: client: reject: status 403 x-reason test
-- CHECK: client: reject: body forbidden
-- CHECK: client: unknown: status 501
-- CHECK-NOT: a server frame is masked
-- CHECK-NOT: upgrade /chat
-- CHECK-NOT: failed
-- CHECK-NOT: still running
-- EXIT: 0

import Http.Server as Server
import Task exposing (Task)
import WebSocketH2Help as H


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        server :: _ ->
            [ "echo", "quiet", "reset", "reject", "unknown" ]
                |> List.map
                    (\mode ->
                        H.node tools (Server.serverPort server) mode []
                            |> Task.map (List.map (\l -> mode ++ ": " ++ l))
                    )
                |> Task.sequence
                |> Task.map List.concat

        [] ->
            Task.fail "no server"


main =
    H.program { servers = [ identity ], client = client }
