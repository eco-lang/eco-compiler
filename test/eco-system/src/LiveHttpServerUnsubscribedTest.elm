module LiveHttpServerUnsubscribedTest exposing (main)

{-| A listening server holds nothing of its own, and neither does a request nobody has asked for
(plans/program-liveness-rule.md L2, N4, LIVE-2): the program starts a server with no `onRequest`
subscription, a Detached Node client sends one request 300 ms later and then keeps its connection
open for 120 s, and the program sleeps one second, so the request has arrived and is held (parked).
Nothing holds after the sleep and the program ends. A parked request or an open server that kept
the program running would be killed by the watchdog (120 s > 60 s).
-}

-- CHECK: listening
-- CHECK: slept
-- EXIT: 0

import Http.Server as Server
import LiveTestHelp as L
import Process
import Socket.Address as Address exposing (Family(..))
import System
import Task


type Msg
    = Started (Result Server.Error Server.Server)
    | Slept
    | Logged
    | Peer


client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{"
        , "s.write('GET /held HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n');});"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),120000);"
        ]


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Started (Server.listen (Server.defaultListenOptions (Address.loopback IPv4) 0)) )
        , update =
            \msg env ->
                case msg of
                    Started (Ok server) ->
                        ( env
                        , Cmd.batch
                            [ L.log env Logged "listening"
                            , L.node Peer (client (Server.endpoint server).port_)
                            , Task.perform (\_ -> Slept) (Process.sleep 1000)
                            ]
                        )

                    Started (Err e) ->
                        ( env, L.log env Logged ("error " ++ Server.errorToString e) )

                    Slept ->
                        ( env, L.log env Logged "slept" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
