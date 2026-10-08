module HttpServerWebSocketTest exposing (main)

{-| `Http.Server.upgradeRequest` over HTTP/1.1 (plans/eco-system-websockets.md §3.4 "Upgrade and
CONNECT", §3.6, §4 WS5): HTTP and WebSocket on one port.

  - A raw client pipelines a GET (answered after 300 ms), an opening request and a WebSocket
    frame in one write: the GET is answered first, then the 101, then the echo of the early
    frame (the bytes read past the request reach the WebSocket). The request's `Response`,
    sent after the upgrade, writes nothing (only frames follow the 101); a second
    `upgradeRequest` on it fails `EINVAL`; `upgradeTarget` is the raw target with its query.
  - A `WebSocket.connect` client: echo; an ordinary request on another connection while the
    WebSocket is open; `upgradeRequest` on an ordinary request fails `EINVAL`.
  - A declined opening request (426) is answered with `Connection: close` and closed.
  - `closeServer` closes the port but leaves the upgraded WebSocket open: it still echoes after
    the close deadline.

-}

-- CHECK: server: again /chat: EINVAL
-- CHECK: server: again /kept: EINVAL
-- CHECK: server: again /ws?x=1: EINVAL
-- CHECK: server: echo /chat: Closed
-- CHECK: server: echo /kept: Closed
-- CHECK: server: echo /ws?x=1: Closed
-- CHECK: server: not an upgrade /plain: EINVAL
-- CHECK: server: taken /chat: upgradeTarget /chat
-- CHECK: server: taken /kept: upgradeTarget /kept
-- CHECK: server: taken /ws?x=1: upgradeTarget /ws?x=1
-- CHECK: server: upgrade http /chat Http1_1
-- CHECK: server: upgrade http /kept Http1_1
-- CHECK: server: upgrade http /ws?x=1 Http1_1
-- CHECK: client: pipelined: 200 keep-alive slow
-- CHECK: client: pipelined: 101 upgrade websocket connection Upgrade accept ok
-- CHECK: client: pipelined: frames text "early" | close 1000 ""
-- CHECK: client: ws client: Text "hello" | Binary [1,2,3] | Normal "" clean True
-- CHECK: client: plain while open: 200 keep-alive plain
-- CHECK: client: declined: 426 close declined
-- CHECK: client: declined: closed
-- CHECK: client: after closeServer: new connection ECONNREFUSED
-- CHECK: client: after closeServer: Text "still open" | Normal "" clean True
-- EXIT: 0

import HttpServerWebSocketHelp as WS
import Task


main =
    WS.program
        { tls = False
        , client =
            \server ->
                Task.sequence
                    [ WS.pipelined "pipelined" (WS.tcp server)
                    , WS.clientCase "ws" server (WS.tcp server)
                    , WS.declined server
                    , WS.keptCase "ws" server
                    ]
                    |> Task.map List.concat
        }
