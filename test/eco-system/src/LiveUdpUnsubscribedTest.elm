module LiveUdpUnsubscribedTest exposing (main)

{-| A bound UDP socket holds nothing of its own, and neither do held datagrams
(plans/program-liveness-rule.md L2, LIVE-2): the program binds a socket, starts a Detached Node
sender that sends a datagram to it every 100 ms for two seconds, starting 300 ms later, and
sleeps one second, so datagrams have arrived and are held. With no `receive` and no `onMessage`
subscription, nothing holds after the sleep and the program ends while the socket is still open.
A bound socket that kept the program running would be killed by the watchdog.
-}

-- CHECK: bound
-- CHECK: slept
-- EXIT: 0

import LiveTestHelp as L
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Udp as Udp
import System
import Task


type Msg
    = Bound (Result Socket.Error Udp.Socket)
    | Slept
    | Logged
    | Peer


sender : Int -> String
sender port_ =
    String.join ""
        [ "const d=require('dgram').createSocket('udp4');d.on('error',()=>{});"
        , "setTimeout(()=>{setInterval(()=>d.send('hello'," ++ String.fromInt port_ ++ ",'127.0.0.1'),100);},300);"
        , "setTimeout(()=>process.exit(0),2300);"
        ]


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.attempt Bound (Udp.bind (Udp.defaultBindOptions (Address.loopback IPv4) 0)) )
        , update =
            \msg env ->
                case msg of
                    Bound (Ok s) ->
                        ( env
                        , Cmd.batch
                            [ L.log env Logged "bound"
                            , L.node Peer (sender (Udp.localEndpoint s).port_)
                            , Task.perform (\_ -> Slept) (Process.sleep 1000)
                            ]
                        )

                    Bound (Err e) ->
                        ( env, L.log env Logged ("error " ++ Socket.errorToString e) )

                    Slept ->
                        ( env, L.log env Logged "slept" )

                    Logged ->
                        ( env, Cmd.none )

                    Peer ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
