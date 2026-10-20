module LiveHttpUpgradeTest exposing (main)

{-| The upgrade hand-over keeps the peer's reply held (plans/program-liveness-rule.md N5, L14):
a Detached Node client sends a WebSocket opening request to the program's server 300 ms after it
starts. The handler drops its `onRequest` subscription, takes the request over with
`upgradeRequest`, waits 500 ms and only then accepts it, logs `accepted` and closes the
WebSocket. Between `upgradeRequest` and `accept` the request's hold has moved to the handshake,
with no gap and no double count; the program ends once the WebSocket is closed.
-}

-- CHECK: upgraded
-- CHECK: accepted
-- CHECK: closed
-- EXIT: 0

import Http.Server as Server
import LiveTestHelp as L
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import System
import Task
import WebSocket


type Msg
    = Started (Result Server.Error Server.Server)
    | GotRequest Server.Request Server.Response
    | Upgraded (Result Socket.Error WebSocket.Upgrade)
    | Accepted (Result Socket.Error (WebSocket.WebSocket WebSocket.Whole))
    | Closed
    | Logged
    | Peer


type alias Model =
    { env : System.Environment
    , server : Maybe Server.Server
    , done : Bool
    }


{-| Sends the opening request; destroys the connection when the close frame (the data after the
101) arrives.
-}
client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{"
        , "s.write('GET / HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
        , "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n');});"
        , "let n=0;s.on('data',()=>{if(++n>=2)s.destroy();});"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),20000);"
        ]


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, server = Nothing, done = False }
                , Task.attempt Started (Server.listen (Server.defaultListenOptions (Address.loopback IPv4) 0))
                )
        , update =
            \msg model ->
                case msg of
                    Started (Ok server) ->
                        ( { model | server = Just server }, L.node Peer (client (Server.endpoint server).port_) )

                    Started (Err e) ->
                        ( model, L.log model.env Logged ("error " ++ Server.errorToString e) )

                    GotRequest request response ->
                        ( { model | done = True }, Task.attempt Upgraded (Server.upgradeRequest request response) )

                    Upgraded (Ok upgrade) ->
                        ( model
                        , Cmd.batch
                            [ L.log model.env Logged "upgraded"
                            , Process.sleep 500
                                |> Task.andThen (\_ -> WebSocket.accept WebSocket.defaultAcceptOptions upgrade)
                                |> Task.attempt Accepted
                            ]
                        )

                    Upgraded (Err e) ->
                        ( model, L.log model.env Logged ("upgrade error " ++ Socket.errorToString e) )

                    Accepted (Ok ws) ->
                        ( model
                        , Cmd.batch
                            [ L.log model.env Logged "accepted"
                            , WebSocket.close WebSocket.Normal "" ws |> Task.attempt (\_ -> Closed)
                            ]
                        )

                    Accepted (Err e) ->
                        ( model, L.log model.env Logged ("accept error " ++ Socket.errorToString e) )

                    Closed ->
                        ( model, L.log model.env Logged "closed" )

                    Logged ->
                        ( model, Cmd.none )

                    Peer ->
                        ( model, Cmd.none )
        , subscriptions =
            \model ->
                case ( model.server, model.done ) of
                    ( Just server, False ) ->
                        Server.onRequest server GotRequest

                    _ ->
                        Sub.none
        }
