module LiveHttpUpgradeLateTest exposing (main)

{-| Taking over an upgrade request whose client already went away (plans/kernel-lib-bug-fixes.md,
HTTPSRV-12): a Detached Node client sends a WebSocket opening request and resets its connection
(RST, `resetAndDestroy`) 200 ms later. The handler drops its `onRequest` subscription and calls
`upgradeRequest` only 600 ms after the request arrived, when the server has seen the connection
go. The take must fail as "socket closed", a `SocketError` of kind `Cancelled` (ECANCELED), the
error `HttpUpgrade.cpp` gives when it finds the connection gone after the take.

Before the fix the server erased the request on ConnGone, so the late take found an unknown key
and failed with EINVAL ("the request was answered already or is not an upgrade request"), kind
`InvalidInput`, on both backends. Now ConnGone leaves a tombstone for a delivered upgrade request
(decision D4; HttpTables.cpp, `_HttpServer_goneUpgrades` in HttpServer.js), which the take reports
as ECANCELED. If the request never arrives the program prints `no request` after 10 s.

-}

-- CHECK: upgrade: SocketError Cancelled
-- CHECK-NOT: no request
-- EXIT: 0

import ErrorNames
import Http.Server as Server
import LiveTestHelp as L
import Process
import Socket.Address as Address exposing (Family(..))
import System
import Task
import WebSocket


type Msg
    = Started (Result Server.Error Server.Server)
    | GotRequest Server.Request Server.Response
    | Upgraded (Result WebSocket.Error WebSocket.Upgrade)
    | Timeout
    | Exit
    | Peer


type alias Model =
    { env : System.Environment
    , server : Maybe Server.Server
    , done : Bool
    }


client : Int -> String
client port_ =
    String.join ""
        [ "const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{"
        , "s.write('GET / HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
        , "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n');"
        , "setTimeout(()=>{s.resetAndDestroy();process.exit(0);},200);});"
        , "s.on('error',()=>process.exit(0));"
        , "setTimeout(()=>process.exit(0),20000);"
        ]


exitAfter : System.Environment -> String -> Cmd Msg
exitAfter env line =
    L.log env Exit line


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, server = Nothing, done = False }
                , Cmd.batch
                    [ Task.attempt Started (Server.listen (Server.defaultListenOptions (Address.loopback IPv4) 0))
                    , Process.sleep 10000 |> Task.perform (\_ -> Timeout)
                    ]
                )
        , update =
            \msg model ->
                case msg of
                    Started (Ok server) ->
                        ( { model | server = Just server }, L.node Peer (client (Server.endpoint server).port_) )

                    Started (Err e) ->
                        ( model, exitAfter model.env ("error " ++ Server.errorToString e) )

                    GotRequest request response ->
                        ( { model | done = True }
                        , Process.sleep 600
                            |> Task.andThen (\_ -> Server.upgradeRequest request response)
                            |> Task.attempt Upgraded
                        )

                    Upgraded (Ok _) ->
                        ( model, exitAfter model.env "upgrade: ok" )

                    Upgraded (Err e) ->
                        ( model
                        , exitAfter model.env
                            ("upgrade: " ++ ErrorNames.webSocketError e ++ "\nupgrade text: " ++ WebSocket.errorToString e)
                        )

                    Timeout ->
                        ( model, exitAfter model.env "no request" )

                    Exit ->
                        ( model, System.exit )

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
