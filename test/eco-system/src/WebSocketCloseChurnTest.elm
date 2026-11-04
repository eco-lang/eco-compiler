module WebSocketCloseChurnTest exposing (main)

{-| WS-18 (plans/kernel-lib-bug-fixes.md, group 05): a held close is marked delivered although
no tagger ran.

Two client/server pairs A and B are opened, both servers close, and both clients `awaitClose`, so
both connections have ended with their closes undelivered (the model keeps all four sockets, so
their entries stay alive). Then one update subscribes `onClose` for both clients at once: the
manager's `deliverHeldCloses` runs over [A, B]. The handler of the first close (whichever comes
first) drops the other client's `onClose` and, 50 ms later, subscribes it again. The second close
must reach the resubscribed `onClose` (decision D25: a close nobody was subscribed to is delivered
once to a later subscriber, as on JS).

Native before the fix: `deliverClose` marked the second id delivered before `deliver` found that
its subscription was gone, so nothing was sent, and the resubscribed `onClose` never received it.

-}

-- CHECK: first close: Normal "" clean True
-- CHECK: second close after resubscribe: Normal "" clean True
-- CHECK-NOT: second close never delivered
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
    | PairReady (Result String ( WebSocket Whole, WebSocket Whole ))
    | BothClosed
    | CloseSeen Int WebSocket.CloseInfo
    | SubscribeBoth
    | Resubscribe Int
    | Timeout
    | Quit


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , pairs : List ( WebSocket Whole, WebSocket Whole )
    , subA : Bool
    , subB : Bool
    , first : Maybe Int
    , done : Bool
    , log : List String
    }


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, listener = Nothing, pairs = [], subA = False, subB = False, first = Nothing, done = False, log = [] }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions = subscriptions
        }


{-| Pair 0 is A, pair 1 is B; each pair is ( server, client ).
-}
client : Int -> Model -> Maybe (WebSocket Whole)
client i model =
    model.pairs |> List.drop i |> List.head |> Maybe.map Tuple.second


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        sub i on =
            case ( on, client i model ) of
                ( True, Just c ) ->
                    WebSocket.onClose c (CloseSeen i)

                _ ->
                    Sub.none
    in
    Sub.batch [ sub 0 model.subA, sub 1 model.subB ]


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


closeAndWait : ( WebSocket Whole, WebSocket Whole ) -> Task x ()
closeAndWait ( s, c ) =
    WebSocket.close WebSocket.Normal "" s
        |> Task.onError (\_ -> Task.succeed ())
        |> Task.andThen (\_ -> WebSocket.awaitClose c)
        |> Task.andThen (\_ -> WebSocket.awaitClose s)
        |> Task.map (\_ -> ())


setSub : Int -> Bool -> Model -> Model
setSub i on model =
    if i == 0 then
        { model | subA = on }

    else
        { model | subB = on }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }, Task.attempt PairReady (openPair l) )

        Listening (Err e) ->
            finish (note ("error " ++ e) model)

        PairReady (Ok p) ->
            let
                m2 =
                    { model | pairs = model.pairs ++ [ p ] }
            in
            case ( List.length m2.pairs, m2.listener ) of
                ( 1, Just l ) ->
                    ( m2, Task.attempt PairReady (openPair l) )

                _ ->
                    ( m2
                    , Task.sequence (List.map closeAndWait m2.pairs)
                        |> Task.perform (\_ -> BothClosed)
                    )

        PairReady (Err e) ->
            finish (note ("error " ++ e) model)

        BothClosed ->
            -- Both ended, closes undelivered: subscribe both in one update. Wait a little first so
            -- that each end has been fully processed.
            ( model, after 100 SubscribeBoth )

        SubscribeBoth ->
            ( { model | subA = True, subB = True }, Cmd.none )

        CloseSeen i info ->
            case model.first of
                Nothing ->
                    let
                        other =
                            1 - i
                    in
                    ( { model | first = Just i }
                        |> setSub other False
                        |> note ("first close: " ++ W.closeInfoString info)
                    , after 50 (Resubscribe other)
                    )

                Just f ->
                    if i == f then
                        ( note "first onClose twice" model, Cmd.none )

                    else if model.done then
                        ( note "second onClose twice" model, Cmd.none )

                    else
                        finish ({ model | done = True } |> note ("second close after resubscribe: " ++ W.closeInfoString info))

        Resubscribe i ->
            ( setSub i True model, after 500 Timeout )

        Timeout ->
            if model.done then
                ( model, Cmd.none )

            else
                finish ({ model | done = True } |> note "second close never delivered")

        Quit ->
            ( model, System.exit )


finish : Model -> ( Model, Cmd Msg )
finish model =
    ( { model | subA = False, subB = False, pairs = [] }
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
