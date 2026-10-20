module LiveHttpServerCloseUnansweredTest exposing (main)

{-| `closeWithin` bounds a request the program never answers (plans/program-liveness-rule.md N1,
§2.2 note 2): the program starts a server and subscribes; a Detached Node client sends one
request 300 ms later and then waits 120 s without ever timing out. The handler drops the
subscription, leaves the request unanswered (it is owed an answer, so it holds) and closes the
server with a 300 ms deadline. At the deadline the remaining connection is closed, the request
stops holding, and the program ends. A request that kept holding would be killed by the watchdog.
-}

-- CHECK: closing
-- CHECK: close done
-- EXIT: 0

import Http.Server as Server
import LiveTestHelp as L
import Socket.Address as Address exposing (Family(..))
import System
import Task


type Msg
    = Started (Result Server.Error Server.Server)
    | GotRequest Server.Request Server.Response
    | CloseDone
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
        , "s.write('GET /never HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n');});"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),120000);"
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

                    GotRequest _ _ ->
                        case model.server of
                            Just server ->
                                ( { model | done = True }
                                , Cmd.batch
                                    [ L.log model.env Logged "closing"
                                    , Task.perform (\_ -> CloseDone) (Server.closeWithin 300 server)
                                    ]
                                )

                            Nothing ->
                                ( model, Cmd.none )

                    CloseDone ->
                        ( model, L.log model.env Logged "close done" )

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
