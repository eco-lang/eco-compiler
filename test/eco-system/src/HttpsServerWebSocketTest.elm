module HttpsServerWebSocketTest exposing (main)

{-| `Http.Server.upgradeRequest` over HTTPS: `wss` through `createServerWith` with `tls`
(plans/eco-system-websockets.md §3.5, §4 WS5), the test CA on the client side.

  - A raw TLS client pipelines a GET (answered after 300 ms), an opening request and a frame:
    the GET is answered first, then the 101, then the echo of the early frame (plaintext read
    past the request reaches the WebSocket over TLS). Nothing but frames follows the 101.
  - A `wss://localhost` client (`WebSocket.connect`): echo, an ordinary https request while it
    is open, and the close handshake.
  - `closeServer` leaves the upgraded `wss` WebSocket open.

-}

-- CHECK: server: again /chat: EINVAL
-- CHECK: server: again /ws?x=1: EINVAL
-- CHECK: server: echo /chat: Closed
-- CHECK: server: echo /kept: Closed
-- CHECK: server: echo /ws?x=1: Closed
-- CHECK: server: upgrade https /chat Http1_1
-- CHECK: server: upgrade https /kept Http1_1
-- CHECK: server: upgrade https /ws?x=1 Http1_1
-- CHECK: client: tls pipelined: 200 keep-alive slow
-- CHECK: client: tls pipelined: 101 upgrade websocket connection Upgrade accept ok
-- CHECK: client: tls pipelined: frames text "early" | close 1000 ""
-- CHECK: client: wss client: Text "hello" | Binary [1,2,3] | Normal "" clean True
-- CHECK: client: plain while open: 200 keep-alive plain
-- CHECK: client: after closeServer: new connection ECONNREFUSED
-- CHECK: client: after closeServer: Text "still open" | Normal "" clean True
-- EXIT: 0

import HttpServerWebSocketHelp as WS
import Task


main =
    WS.program
        { tls = True
        , client =
            \server ->
                Task.sequence
                    [ WS.pipelined "tls pipelined" (WS.tlsRaw server)
                    , WS.clientCase "wss" server (WS.tlsRaw server)
                    , WS.keptCase "wss" server
                    ]
                    |> Task.map List.concat
        }
