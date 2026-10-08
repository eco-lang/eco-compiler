module SocketUdpBothTest exposing (main)

{-| The delivery rule (plans/eco-system-sockets.md §3.4) for UDP: with a parked
`Socket.Udp.receive` and an `onMessage` subscription on the same socket, the first datagram goes to
the oldest parked receive; the second, with no receive waiting, goes to the subscription.
-}

-- CHECK: receive got: first
-- CHECK: subscription got: second
-- CHECK-NOT: subscription got: first
-- CHECK-NOT: receive got: second
-- EXIT: 0

import Process
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import Stream.Log
import System
import Task exposing (Task)


type Msg
    = Bound (Result String ( Socket.Udp.Socket, Socket.Udp.Socket ))
    | ReceiveGot (Result String ( String, Socket.Udp.Datagram ))
    | SubGot Socket.Udp.Datagram
    | Sent (Result String ())
    | Finished


type alias Model =
    { env : System.Environment
    , sockets : Maybe ( Socket.Udp.Socket, Socket.Udp.Socket )
    , received : Maybe String
    , subscribed : Maybe String
    }


send : ( Socket.Udp.Socket, Socket.Udp.Socket ) -> String -> Task String ()
send ( a, b ) text =
    U.sendText (Socket.Udp.localEndpoint b) text a


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, sockets = Nothing, received = Nothing, subscribed = Nothing }
                , Task.map2 Tuple.pair U.bindLocal U.bindLocal
                    |> H.socketErr
                    |> Task.attempt Bound
                )
        , update = update
        , subscriptions =
            \model ->
                case model.sockets of
                    Just ( _, b ) ->
                        Socket.Udp.onMessage b SubGot

                    Nothing ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Bound (Ok ( a, b )) ->
            ( { model | sockets = Just ( a, b ) }
            , Cmd.batch
                [ H.socketErr (Socket.Udp.receive b)
                    |> Task.map (\d -> ( H.bytesToString d.data, d ))
                    |> Task.attempt ReceiveGot
                , Process.sleep 300
                    |> Task.andThen (\_ -> send ( a, b ) "first")
                    |> Task.attempt Sent
                ]
            )

        Bound (Err e) ->
            report { model | sockets = Nothing } [ "bind failed: " ++ e ]

        ReceiveGot (Ok ( text, _ )) ->
            check
                { model | received = Just text }
                (case model.sockets of
                    Just pair ->
                        Task.attempt Sent (send pair "second")

                    Nothing ->
                        Cmd.none
                )

        ReceiveGot (Err e) ->
            report model [ "receive failed: " ++ e ]

        SubGot d ->
            check { model | subscribed = Just (H.bytesToString d.data) } Cmd.none

        Sent (Ok ()) ->
            ( model, Cmd.none )

        Sent (Err e) ->
            report model [ "send failed: " ++ e ]

        Finished ->
            ( model, Cmd.none )


check : Model -> Cmd Msg -> ( Model, Cmd Msg )
check model cmd =
    case ( model.received, model.subscribed ) of
        ( Just r, Just s ) ->
            report model [ "receive got: " ++ r, "subscription got: " ++ s ]

        _ ->
            ( model, cmd )


report : Model -> List String -> ( Model, Cmd Msg )
report model lines =
    ( { model | sockets = Nothing }
    , Stream.Log.line model.env.stdout (String.join "\n" lines)
        |> Task.andThen
            (\_ ->
                case model.sockets of
                    Just ( a, b ) ->
                        U.closeAll [ a, b ]

                    Nothing ->
                        Task.succeed ()
            )
        |> Task.perform (\_ -> Finished)
    )
