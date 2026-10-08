module WebSocketCloseOrderTest exposing (main)

{-| `onClose` comes after every message received before the close (plans/eco-system-websockets.md
W3, W4, Appendix C.2): the client subscribes to `onMessage` and `onClose`; a raw server then writes 200
text frames and a Close frame in one write, so they arrive in one read. The `CloseInfo` must reach
the app after all 200 messages, in order, although the Closed event is posted while the messages
are still queued on the readable.
On the close the app drops both subscriptions (as a chat client does), so a message delivered
late would be lost.
-}

-- CHECK: received before close: 200, in order True
-- CHECK: onClose: Normal "bye" clean True
-- CHECK-NOT: after close
-- CHECK-NOT: error
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Process
import Socket
import SocketTestHelp as H
import Stream.Log
import System
import Task exposing (Task)
import WebSocket exposing (WebSocket, Whole)
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


count : Int
count =
    200


type Msg
    = Listening (Result String Socket.Listener)
    | ClientReady (Result String (WebSocket Whole))
    | Got WebSocket.Message
    | CloseSeen WebSocket.CloseInfo
    | ServerDone (Result String ())
    | Exit
    | Quit


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , client : Maybe (WebSocket Whole)
    , subscribed : Bool
    , received : Int
    , inOrder : Bool
    , log : List String
    }


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, listener = Nothing, client = Nothing, subscribed = False, received = 0, inOrder = True, log = [] }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    case ( model.client, model.subscribed ) of
        ( Just c, True ) ->
            Sub.batch [ WebSocket.onMessage c Got, WebSocket.onClose c CloseSeen ]

        _ ->
            Sub.none


note : String -> Model -> Model
note line model =
    { model | log = model.log ++ [ line ] }


burst : Bytes
burst =
    E.encode
        (E.sequence
            (List.map (\i -> E.bytes (W.frame True 0 1 (H.bytesOf (String.fromInt i)))) (List.range 1 count)
                ++ [ E.bytes (W.frame True 0 8 (W.closePayload 1000 "bye")) ]
            )
        )


{-| The raw server: the 101, a pause (the client subscribes), then the burst in one write; it
waits for the client's Close and closes the connection.
-}
serve : Socket.Listener -> Task String ()
serve listener =
    W.rawUpgradeClient listener (\key -> W.switching acceptFor key [])
        |> Task.andThen
            (\( conn, _ ) ->
                Process.sleep 300
                    |> Task.andThen (\_ -> W.rawWrite burst conn)
                    |> Task.andThen (\_ -> W.rawUntilClose conn)
                    |> Task.map (\_ -> ())
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }
            , Cmd.batch [ Task.attempt ServerDone (serve l), Task.attempt ClientReady (W.connect l) ]
            )

        Listening (Err e) ->
            finish (note ("error " ++ e) model)

        ClientReady (Ok c) ->
            ( { model | client = Just c, subscribed = True }, Cmd.none )

        ClientReady (Err e) ->
            finish (note ("error " ++ e) model)

        Got m ->
            if model.subscribed then
                ( { model
                    | received = model.received + 1
                    , inOrder = model.inOrder && m == WebSocket.Text (String.fromInt (model.received + 1))
                  }
                , Cmd.none
                )

            else
                ( note ("message after close: " ++ W.messageString m) model, Cmd.none )

        CloseSeen info ->
            ( { model | subscribed = False }
                |> note
                    ("received before close: "
                        ++ String.fromInt model.received
                        ++ ", in order "
                        ++ (if model.inOrder then
                                "True"

                            else
                                "False"
                           )
                    )
                |> note ("onClose: " ++ W.closeInfoString info)
            , Process.sleep 300 |> Task.perform (\_ -> Exit)
            )

        ServerDone (Ok ()) ->
            ( model, Cmd.none )

        ServerDone (Err e) ->
            finish (note ("error server " ++ e) model)

        Exit ->
            finish model

        Quit ->
            ( model, System.exit )


finish : Model -> ( Model, Cmd Msg )
finish model =
    ( { model | subscribed = False, client = Nothing }
    , Stream.Log.line model.env.stdout (String.join "\n" model.log)
        |> Task.andThen
            (\_ ->
                case model.listener of
                    Just l ->
                        Socket.closeListener l |> Task.onError (\_ -> Task.succeed ())

                    Nothing ->
                        Task.succeed ()
            )
        |> Task.perform (\_ -> Quit)
    )
