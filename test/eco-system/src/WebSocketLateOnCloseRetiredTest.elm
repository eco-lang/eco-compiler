module WebSocketLateOnCloseRetiredTest exposing (main)

{-| WS-19 (plans/kernel-lib-bug-fixes.md, group 05): a close nobody was subscribed to is lost
once the WebSocket's table entry has been retired.

Decision D25: a close nobody was subscribed to is delivered once to a later `onClose`
subscriber, as on JS (whose socket records are never deleted).

  - "alive" (a control that works today): the server closes with "bye", the client
    `awaitClose`s, and only then subscribes `onClose`; the close is delivered.
  - "retired": the same, but before subscribing the client reads its readable to its end
    (`W.readAll`) and closes its writable, so both of its stream pairs end and are erased; the
    last face gone, the manager retires the entry. 50 ms later the client subscribes `onClose`
    and waits up to 500 ms.

Native before the fix: the retired entry was gone, `reconcile` found nothing to deliver, and the
late subscriber received nothing ("retired: late onClose none"). The close is now kept, undelivered,
in the entry's recently closed record.

-}

-- CHECK: alive: late onClose Normal "bye" clean True
-- CHECK: retired: late onClose Normal "bye" clean True
-- CHECK-NOT: onClose twice
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import Stream
import System
import Task exposing (Task)
import WebSocket exposing (WebSocket, Whole)
import WebSocketTestHelp as W


type Msg
    = Listening (Result String Socket.Listener)
    | PairReady String (Result String ( WebSocket Whole, WebSocket Whole ))
    | Ended String
    | Subscribe String
    | CloseSeen String WebSocket.CloseInfo
    | Timeout String
    | Quit


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , pair : Maybe ( WebSocket Whole, WebSocket Whole )
    , phase : String
    , subscribed : Bool
    , seen : Int
    , log : List String
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, listener = Nothing, pair = Nothing, phase = "alive", subscribed = False, seen = 0, log = [] }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    case ( model.subscribed, model.pair ) of
        ( True, Just ( _, c ) ) ->
            WebSocket.onClose c (CloseSeen model.phase)

        _ ->
            Sub.none


after : Int -> Msg -> Cmd Msg
after ms msg =
    Process.sleep (toFloat ms) |> Task.perform (\_ -> msg)


note : String -> Model -> Model
note line model =
    { model | log = model.log ++ [ line ] }


openPair : Socket.Listener -> Task String ( WebSocket Whole, WebSocket Whole )
openPair l =
    H.async (W.acceptOne l)
        |> Task.andThen (\server -> W.connect l |> Task.andThen (\c -> server |> Task.map (\s -> ( s, c ))))


{-| The server closes with "bye" and the client waits for the end. In the "retired" phase the
client then also reads its readable to its end and closes its writable, so both faces end.
-}
closeAndWait : String -> ( WebSocket Whole, WebSocket Whole ) -> Task x ()
closeAndWait phase ( s, c ) =
    WebSocket.close WebSocket.Normal "bye" s
        |> Task.onError (\_ -> Task.succeed ())
        |> Task.andThen (\_ -> WebSocket.awaitClose c)
        |> Task.andThen (\_ -> WebSocket.awaitClose s)
        |> Task.andThen
            (\_ ->
                if phase == "retired" then
                    W.readAll c
                        |> Task.andThen (\_ -> Stream.closeWritable (WebSocket.writable c) |> Task.onError (\_ -> Task.succeed ()))

                else
                    Task.succeed ()
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }, Task.attempt (PairReady "alive") (openPair l) )

        Listening (Err e) ->
            finish (note ("error " ++ e) model)

        PairReady phase (Ok p) ->
            ( { model | pair = Just p, phase = phase, subscribed = False, seen = 0 }
            , closeAndWait phase p |> Task.perform (\_ -> Ended phase)
            )

        PairReady _ (Err e) ->
            finish (note ("error " ++ e) model)

        Ended phase ->
            ( model, after 50 (Subscribe phase) )

        Subscribe phase ->
            ( { model | subscribed = True }, after 500 (Timeout phase) )

        CloseSeen phase info ->
            if phase /= model.phase then
                ( model, Cmd.none )

            else if model.seen > 0 then
                ( note (phase ++ ": onClose twice") model, Cmd.none )

            else
                ( { model | seen = model.seen + 1 } |> note (phase ++ ": late onClose " ++ W.closeInfoString info), Cmd.none )

        Timeout phase ->
            let
                m2 =
                    if model.seen == 0 then
                        note (phase ++ ": late onClose none") model

                    else
                        model
            in
            case ( phase, m2.listener ) of
                ( "alive", Just l ) ->
                    ( { m2 | subscribed = False }, Task.attempt (PairReady "retired") (openPair l) )

                _ ->
                    finish m2

        Quit ->
            ( model, System.exit )


finish : Model -> ( Model, Cmd Msg )
finish model =
    ( { model | subscribed = False, pair = Nothing }
    , Stream.logLine (String.join "\n" model.log) model.env.stdout
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
