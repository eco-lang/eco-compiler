module WebSocketSubscriptionTest exposing (main)

{-| `onMessage` and `onClose` (plans/eco-system-websockets.md §4 WS4, W3, Appendix C.2):

1.  a `Stream.read` is parked on the client's readable, then `onMessage` subscribes: the next
    message completes the read (the subscription waits for it), the one after goes to the
    subscription;
2.  with two subscriptions, a message goes to both, in subscription order;
3.  after the subscriptions are gone, messages wait on the readable again;
4.  the server closes while nobody subscribes to `onClose`: a later subscriber receives the
    `CloseInfo`, once.

-}

-- CHECK: read got: Text "first"
-- CHECK: sub1 got: Text "second"
-- CHECK: sub1 got: Text "third"
-- CHECK-NEXT: sub2 got: Text "third"
-- CHECK: read after unsubscribe: Text "fourth"
-- CHECK: closed: Normal "end" clean True
-- CHECK: late onClose: Normal "end" clean True
-- CHECK-NOT: onClose twice
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import Stream
import Stream.Log
import System
import Task exposing (Task)
import WebSocket exposing (WebSocket, Whole)
import WebSocketTestHelp as W


type Msg
    = Listening (Result String Socket.Listener)
    | ServerReady (Result String (WebSocket Whole))
    | ClientReady (Result String (WebSocket Whole))
    | ReadDone String Bool (Result Stream.Error WebSocket.Message)
    | Step Int
    | Sub1 WebSocket.Message
    | Sub2 WebSocket.Message
    | CloseSeen WebSocket.CloseInfo
    | Closed WebSocket.CloseInfo
    | Sent
    | Exit
    | Quit


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , server : Maybe (WebSocket Whole)
    , client : Maybe (WebSocket Whole)
    , sub1 : Bool
    , sub2 : Bool
    , closeSub : Bool
    , closeSeen : Int
    , log : List String
    }


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, listener = Nothing, server = Nothing, client = Nothing, sub1 = False, sub2 = False, closeSub = False, closeSeen = 0, log = [] }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.client of
        Just c ->
            Sub.batch
                [ if model.sub1 then
                    WebSocket.onMessage c Sub1

                  else
                    Sub.none
                , if model.sub2 then
                    WebSocket.onMessage c Sub2

                  else
                    Sub.none
                , if model.closeSub then
                    WebSocket.onClose c CloseSeen

                  else
                    Sub.none
                ]

        Nothing ->
            Sub.none


after : Int -> Msg -> Cmd Msg
after ms msg =
    Process.sleep (toFloat ms) |> Task.perform (\_ -> msg)


send : Model -> String -> Cmd Msg
send model text =
    case model.server of
        Just s ->
            Stream.write (WebSocket.Text text) (WebSocket.writable s) |> Task.attempt (\_ -> Sent)

        Nothing ->
            Cmd.none


readClient : Model -> String -> Bool -> Cmd Msg
readClient model label final =
    case model.client of
        Just c ->
            Stream.read (WebSocket.readable c) |> Task.attempt (ReadDone label final)

        Nothing ->
            Cmd.none


note : String -> Model -> Model
note line model =
    { model | log = model.log ++ [ line ] }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }
            , Cmd.batch [ Task.attempt ServerReady (W.acceptOne l), Task.attempt ClientReady (W.connect l) ]
            )

        Listening (Err e) ->
            finish (note ("error " ++ e) model)

        ServerReady (Ok s) ->
            start { model | server = Just s }

        ClientReady (Ok c) ->
            start { model | client = Just c }

        ServerReady (Err e) ->
            finish (note ("error " ++ e) model)

        ClientReady (Err e) ->
            finish (note ("error " ++ e) model)

        -- 1. a read is parked; the subscription comes later and waits for it.
        Step 1 ->
            ( { model | sub1 = True }, after 100 (Step 2) )

        Step 2 ->
            ( model, send model "first" )

        ReadDone "read" _ (Ok m) ->
            ( note ("read got: " ++ W.messageString m) model, after 100 (Step 3) )

        Step 3 ->
            ( model, send model "second" )

        Sub1 m ->
            let
                m2 =
                    note ("sub1 got: " ++ W.messageString m) model
            in
            if m == WebSocket.Text "second" then
                -- 2. two subscriptions
                ( { m2 | sub2 = True }, after 100 (Step 4) )

            else
                ( m2, Cmd.none )

        Step 4 ->
            ( model, send model "third" )

        Sub2 m ->
            -- 3. unsubscribe, then the next message waits on the readable
            ( { model | sub1 = False, sub2 = False } |> note ("sub2 got: " ++ W.messageString m), after 100 (Step 5) )

        Step 5 ->
            ( model, Cmd.batch [ send model "fourth", readClient model "after" False ] )

        ReadDone "after" _ (Ok m) ->
            -- 4. the server closes; nobody subscribes to onClose yet
            ( note ("read after unsubscribe: " ++ W.messageString m) model
            , case ( model.server, model.client ) of
                ( Just s, Just c ) ->
                    WebSocket.close WebSocket.Normal "end" s
                        |> Task.onError (\_ -> Task.succeed ())
                        |> Task.andThen (\_ -> WebSocket.closed c)
                        |> Task.perform Closed

                _ ->
                    Cmd.none
            )

        Closed info ->
            ( { model | closeSub = True } |> note ("closed: " ++ W.closeInfoString info), after 300 Exit )

        CloseSeen info ->
            ( { model | closeSeen = model.closeSeen + 1 }
                |> note
                    (if model.closeSeen == 0 then
                        "late onClose: " ++ W.closeInfoString info

                     else
                        "onClose twice"
                    )
            , Cmd.none
            )

        ReadDone label _ r ->
            finish
                (note
                    ("unexpected read "
                        ++ label
                        ++ " "
                        ++ (case r of
                                Ok m ->
                                    W.messageString m

                                Err e ->
                                    Stream.errorToString e
                           )
                    )
                    model
                )

        Step _ ->
            ( model, Cmd.none )

        Sent ->
            ( model, Cmd.none )

        Exit ->
            finish model

        Quit ->
            ( model, System.exit )


start : Model -> ( Model, Cmd Msg )
start model =
    case ( model.server, model.client ) of
        ( Just _, Just _ ) ->
            ( model, Cmd.batch [ readClient model "read" False, after 100 (Step 1) ] )

        _ ->
            ( model, Cmd.none )


finish : Model -> ( Model, Cmd Msg )
finish model =
    ( { model | sub1 = False, sub2 = False, closeSub = False, client = Nothing }
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
