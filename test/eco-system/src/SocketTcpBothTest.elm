module SocketTcpBothTest exposing (main)

{-| The delivery rule (plans/eco-system-sockets.md §3.4): with a parked `Socket.accept` and an
`onConnection` subscription on the same listener, the first connection goes to the oldest parked
accept; the second, with no accept waiting, goes to the subscription.
-}

-- CHECK: accept got: first
-- CHECK: subscription got: second
-- CHECK-NOT: subscription got: first
-- CHECK-NOT: accept got: second
-- EXIT: 0

import Process
import Socket
import SocketTestHelp as H
import Stream.Log
import System
import Task exposing (Task)


type Msg
    = Listening (Result String Socket.Listener)
    | AcceptGot (Result String String)
    | SubConnection Socket.Connection
    | SubGot (Result String String)
    | ClientSent (Result String ())
    | Finished


type alias Model =
    { env : System.Environment
    , listener : Maybe Socket.Listener
    , accepted : Maybe String
    , subscribed : Maybe String
    }


client : Socket.Listener -> String -> Task String ()
client listener text =
    H.socketErr (H.connectTo listener)
        |> Task.andThen (\conn -> H.streamErr (H.writeAll text (Socket.writable conn)))


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, listener = Nothing, accepted = Nothing, subscribed = Nothing }
                , Task.attempt Listening (H.socketErr H.listenLocal)
                )
        , update = update
        , subscriptions =
            \model ->
                case model.listener of
                    Just l ->
                        Socket.onConnection l SubConnection

                    Nothing ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Listening (Ok l) ->
            ( { model | listener = Just l }
            , Cmd.batch
                [ Task.attempt AcceptGot (H.acceptRead l)
                , Process.sleep 300
                    |> Task.andThen (\_ -> client l "first")
                    |> Task.attempt ClientSent
                ]
            )

        Listening (Err e) ->
            report model [ "listen failed: " ++ e ]

        AcceptGot (Ok text) ->
            check
                { model | accepted = Just text }
                (case model.listener of
                    Just l ->
                        Task.attempt ClientSent (client l "second")

                    Nothing ->
                        Cmd.none
                )

        AcceptGot (Err e) ->
            report model [ "accept failed: " ++ e ]

        SubConnection conn ->
            ( model, Task.attempt SubGot (H.streamErr (H.readAll (Socket.readable conn))) )

        SubGot (Ok text) ->
            check { model | subscribed = Just text } Cmd.none

        SubGot (Err e) ->
            report model [ "subscription read failed: " ++ e ]

        ClientSent (Ok ()) ->
            ( model, Cmd.none )

        ClientSent (Err e) ->
            report model [ "client failed: " ++ e ]

        Finished ->
            ( model, Cmd.none )


check : Model -> Cmd Msg -> ( Model, Cmd Msg )
check model cmd =
    case ( model.accepted, model.subscribed ) of
        ( Just a, Just s ) ->
            report model [ "accept got: " ++ a, "subscription got: " ++ s ]

        _ ->
            ( model, cmd )


report : Model -> List String -> ( Model, Cmd Msg )
report model lines =
    ( { model | listener = Nothing }
    , Stream.Log.line model.env.stdout (String.join "\n" lines)
        |> Task.andThen
            (\_ ->
                case model.listener of
                    Just l ->
                        Socket.closeListener l |> Task.onError (\_ -> Task.succeed ())

                    Nothing ->
                        Task.succeed ()
            )
        |> Task.perform (\_ -> Finished)
    )
