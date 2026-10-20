module LiveHttpServerOnRequestTest exposing (main)

{-| An `onRequest` subscription holds its server (plans/program-liveness-rule.md L2, LIVE_001):
the program starts a server and subscribes, and a Detached Node client sends one request 300 ms
later. Nothing but the subscription keeps the program running until the request arrives. The
handler answers 200, drops the subscription and logs `served`; the client's connection then stays
open, idle (keep-alive), which holds nothing, so the program ends.
-}

-- CHECK: served
-- EXIT: 0

import Http.Server as Server
import LiveTestHelp as L
import Socket.Address as Address exposing (Family(..))
import System
import Task


type Msg
    = Started (Result Server.Error Server.Server)
    | GotRequest Server.Request Server.Response
    | Logged
    | Peer


type alias Model =
    { env : System.Environment
    , server : Maybe Server.Server
    , done : Bool
    }


client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1',()=>{"
        , "s.write('GET /a HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n');});"
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

                    GotRequest _ response ->
                        ( { model | done = True }
                        , Cmd.batch
                            [ response |> Server.setBody "ok" |> Server.send
                            , L.log model.env Logged "served"
                            ]
                        )

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
