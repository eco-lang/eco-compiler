module LiveListenerSubscribedTest exposing (main)

{-| An `onConnection` subscription holds its listener (plans/program-liveness-rule.md L2,
LIVE_001): the program listens and subscribes, and a Detached Node client connects 300 ms later.
Nothing but the subscription keeps the program running until the connection arrives. The handler
logs `conn`, drops the subscription, closes the connection and the listener, and logs `closed`;
then nothing holds and the program ends.
-}

-- CHECK: conn
-- CHECK: closed
-- EXIT: 0

import LiveTestHelp as L
import Socket
import SocketTestHelp as H
import System
import Task


type Msg
    = Listening (Result Socket.Error Socket.Listener)
    | Conn Socket.Connection
    | Closed
    | Logged
    | Peer


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    }


client : Int -> String
client port_ =
    String.join ""
        [ "setTimeout(()=>{const s=require('net').connect(" ++ String.fromInt port_ ++ ",'127.0.0.1');"
        , "s.on('error',()=>process.exit(0));s.on('close',()=>process.exit(0));},300);"
        , "setTimeout(()=>process.exit(0),20000);"
        ]


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init = \env -> ( { env = env, listener = Nothing }, Task.attempt Listening H.listenLocal )
        , update =
            \msg model ->
                case msg of
                    Listening (Ok l) ->
                        ( { model | listener = Just l }, L.node Peer (client (H.portOf l)) )

                    Listening (Err e) ->
                        ( model, L.log model.env Logged ("error " ++ Socket.errorToString e) )

                    Conn conn ->
                        case model.listener of
                            Just l ->
                                ( { model | listener = Nothing }
                                , Cmd.batch
                                    [ L.log model.env Logged "conn"
                                    , Socket.close conn
                                        |> Task.andThen (\_ -> Socket.closeListener l)
                                        |> Task.attempt (\_ -> Closed)
                                    ]
                                )

                            Nothing ->
                                ( model, Task.perform (\_ -> Logged) (Socket.close conn) )

                    Closed ->
                        ( model, L.log model.env Logged "closed" )

                    Logged ->
                        ( model, Cmd.none )

                    Peer ->
                        ( model, Cmd.none )
        , subscriptions =
            \model ->
                case model.listener of
                    Just l ->
                        Socket.onConnection l Conn

                    Nothing ->
                        Sub.none
        }
