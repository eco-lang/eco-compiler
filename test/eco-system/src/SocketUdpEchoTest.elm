module SocketUdpEchoTest exposing (main)

{-| UDP echo over loopback (plans/eco-system-sockets.md §4 S4): two sockets bound to
`127.0.0.1:0`. Socket B receives through `Socket.Udp.onMessage` and replies to the sender; socket
A sends, then receives the reply with `Socket.Udp.receive`. Each side sees the other's
`localEndpoint` as the sender. Both sockets are closed and the program exits by itself.
-}

-- CHECK: b got: ping over udp
-- CHECK: b saw a as sender: True
-- CHECK: a got: echo: ping over udp
-- CHECK: a saw b as sender: True
-- CHECK: ports nonzero: True
-- CHECK: a local address: 127.0.0.1
-- EXIT: 0

import Socket.Address as Address
import Socket.Udp
import SocketTestHelp as H
import SocketUdpTestHelp as U
import Stream.Log
import System
import Task


type Msg
    = Bound (Result String ( Socket.Udp.Socket, Socket.Udp.Socket ))
    | GotOnB Socket.Udp.Datagram
    | Replied (Result String ())
    | AGot (Result String ( String, Address.InetEndpoint ))
    | Finished


type alias Model =
    { env : System.Environment
    , sockets : Maybe ( Socket.Udp.Socket, Socket.Udp.Socket )
    , bGot : Maybe ( String, Address.InetEndpoint )
    , aGot : Maybe ( String, Address.InetEndpoint )
    }


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, sockets = Nothing, bGot = Nothing, aGot = Nothing }
                , Task.map2 Tuple.pair U.bindLocal U.bindLocal
                    |> H.socketErr
                    |> Task.attempt Bound
                )
        , update = update
        , subscriptions =
            \model ->
                case model.sockets of
                    Just ( _, b ) ->
                        Socket.Udp.onMessage b GotOnB

                    Nothing ->
                        Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Bound (Ok ( a, b )) ->
            ( { model | sockets = Just ( a, b ) }
            , U.sendText (Socket.Udp.localEndpoint b) "ping over udp" a
                |> Task.andThen (\_ -> U.receiveText a)
                |> Task.attempt AGot
            )

        Bound (Err e) ->
            finish { model | sockets = Nothing } [ "bind failed: " ++ e ]

        GotOnB d ->
            case model.sockets of
                Just ( _, b ) ->
                    let
                        text =
                            H.bytesToString d.data
                    in
                    ( { model | bGot = Just ( text, d.from ) }
                    , U.sendText d.from ("echo: " ++ text) b |> Task.attempt Replied
                    )

                Nothing ->
                    ( model, Cmd.none )

        Replied (Ok ()) ->
            check model

        Replied (Err e) ->
            finish model [ "reply failed: " ++ e ]

        AGot (Ok r) ->
            check { model | aGot = Just r }

        AGot (Err e) ->
            finish model [ "a failed: " ++ e ]

        Finished ->
            ( model, Cmd.none )


check : Model -> ( Model, Cmd Msg )
check model =
    case ( model.sockets, model.bGot, model.aGot ) of
        ( Just ( a, b ), Just ( bText, bFrom ), Just ( aText, aFrom ) ) ->
            let
                aEp =
                    Socket.Udp.localEndpoint a

                bEp =
                    Socket.Udp.localEndpoint b
            in
            finish model
                [ "b got: " ++ bText
                , "b saw a as sender: " ++ H.boolString (U.sameEndpoint bFrom aEp)
                , "a got: " ++ aText
                , "a saw b as sender: " ++ H.boolString (U.sameEndpoint aFrom bEp)
                , "ports nonzero: " ++ H.boolString (aEp.port_ /= 0 && bEp.port_ /= 0)
                , "a local address: " ++ Address.toString aEp.address
                ]

        _ ->
            ( model, Cmd.none )


finish : Model -> List String -> ( Model, Cmd Msg )
finish model lines =
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
