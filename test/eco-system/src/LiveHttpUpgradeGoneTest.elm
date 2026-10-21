module LiveHttpUpgradeGoneTest exposing (main)

{-| A handed-over upgrade request holds until its connection goes away
(plans/program-liveness-rule.md N5, §2.2 note 4): a Detached Node client sends a WebSocket
opening request to the program's server 300 ms after it starts, and ends its connection 500 ms
after sending it. The handler drops its `onRequest` subscription and takes the request over with
`upgradeRequest`, and then forgets the `Upgrade`: only the handshake's hold keeps the program
running, until the client goes away. The empty event loop that follows (`onEmptyEventLoop`) comes
only then, at least 300 ms after the upgrade; accepting the `Upgrade` then fails with a `SocketError` of kind `ConnectionReset`.
-}

-- CHECK: upgraded
-- CHECK: waited: True
-- CHECK: accept: SocketError ConnectionReset
-- EXIT: 0

import ErrorNames
import Http.Server as Server
import LiveTestHelp as L
import Socket
import Socket.Address as Address exposing (Family(..))
import System
import Task
import Time
import WebSocket


type Msg
    = Started (Result Server.Error Server.Server)
    | GotRequest Server.Request Server.Response
    | Upgraded (Result WebSocket.Error ( WebSocket.Upgrade, Time.Posix ))
    | Empty
    | EmptyAt Time.Posix
    | Accepted (Result WebSocket.Error (WebSocket.WebSocket WebSocket.Whole))
    | Logged
    | Peer


type alias Model =
    { env : System.Environment
    , server : Maybe Server.Server
    , done : Bool
    , upgrade : Maybe ( WebSocket.Upgrade, Time.Posix )
    }


client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{"
        , "s.write('GET / HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
        , "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n');"
        , "setTimeout(()=>s.end(),500);});"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),20000);"
        ]


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, server = Nothing, done = False, upgrade = Nothing }
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
                        ( { model | done = True }
                        , Server.upgradeRequest request response
                            |> Task.andThen (\u -> Task.map (\t -> ( u, t )) Time.now)
                            |> Task.attempt Upgraded
                        )

                    Upgraded (Ok u) ->
                        ( { model | upgrade = Just u }, L.log model.env Logged "upgraded" )

                    Upgraded (Err e) ->
                        ( model, L.log model.env Logged ("upgrade error " ++ WebSocket.errorToString e) )

                    Empty ->
                        ( model, Task.perform EmptyAt Time.now )

                    EmptyAt t ->
                        case model.upgrade of
                            Just ( upgrade, t0 ) ->
                                let
                                    _ =
                                        Debug.log "waited" (Time.posixToMillis t - Time.posixToMillis t0 >= 300)
                                in
                                ( model, Task.attempt Accepted (WebSocket.accept WebSocket.defaultAcceptOptions upgrade) )

                            Nothing ->
                                ( model, L.log model.env Logged "empty before the upgrade" )

                    Accepted (Ok ws) ->
                        ( model
                        , Cmd.batch
                            [ L.log model.env Logged "accept: ok"
                            , WebSocket.close WebSocket.Normal "" ws |> Task.attempt (\_ -> Logged)
                            ]
                        )

                    Accepted (Err e) ->
                        ( model, L.log model.env Logged ("accept: " ++ ErrorNames.webSocketError e) )

                    Logged ->
                        ( model, Cmd.none )

                    Peer ->
                        ( model, Cmd.none )
        , subscriptions =
            \model ->
                Sub.batch
                    [ System.onEmptyEventLoop Empty
                    , case ( model.server, model.done ) of
                        ( Just server, False ) ->
                            Server.onRequest server GotRequest

                        _ ->
                            Sub.none
                    ]
        }
