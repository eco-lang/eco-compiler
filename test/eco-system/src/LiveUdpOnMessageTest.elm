module LiveUdpOnMessageTest exposing (main)

{-| An `onMessage` subscription holds its UDP socket (plans/program-liveness-rule.md L2,
LIVE_001): the program binds a socket and subscribes, and a Detached Node sender starts sending
`hello` to it 300 ms later (every 100 ms, for two seconds). Nothing but the subscription keeps
the program running until the first datagram arrives. The handler logs it, drops the
subscription, closes the socket and logs `closed`; then nothing holds and the program ends.
-}

-- CHECK: got hello
-- CHECK: closed
-- EXIT: 0

import Bytes.Decode
import Bytes
import LiveTestHelp as L
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Udp as Udp
import System
import Task


type Msg
    = Bound (Result Socket.Error Udp.Socket)
    | Got Udp.Datagram
    | Closed
    | Logged
    | Peer


type alias Model =
    { env : System.Environment
    , socket : Maybe Udp.Socket
    }


sender : Int -> String
sender port_ =
    String.join ""
        [ "const d=require('dgram').createSocket('udp4');d.on('error',()=>{});"
        , "setTimeout(()=>{setInterval(()=>d.send('hello'," ++ String.fromInt port_ ++ ",'127.0.0.1'),100);},300);"
        , "setTimeout(()=>process.exit(0),2300);"
        ]


text : Bytes.Bytes -> String
text b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b |> Maybe.withDefault "?"


main : Platform.Program System.Environment Model Msg
main =
    Platform.worker
        { init =
            \env ->
                ( { env = env, socket = Nothing }
                , Task.attempt Bound (Udp.bind (Udp.defaultBindOptions (Address.loopback IPv4) 0))
                )
        , update =
            \msg model ->
                case msg of
                    Bound (Ok s) ->
                        ( { model | socket = Just s }, L.node Peer (sender (Udp.localEndpoint s).port_) )

                    Bound (Err e) ->
                        ( model, L.log model.env Logged ("error " ++ Socket.errorToString e) )

                    Got d ->
                        case model.socket of
                            Just s ->
                                ( { model | socket = Nothing }
                                , Cmd.batch
                                    [ L.log model.env Logged ("got " ++ text d.data)
                                    , Task.perform (\_ -> Closed) (Udp.close s)
                                    ]
                                )

                            Nothing ->
                                ( model, Cmd.none )

                    Closed ->
                        ( model, L.log model.env Logged "closed" )

                    Logged ->
                        ( model, Cmd.none )

                    Peer ->
                        ( model, Cmd.none )
        , subscriptions =
            \model ->
                case model.socket of
                    Just s ->
                        Udp.onMessage s Got

                    Nothing ->
                        Sub.none
        }
