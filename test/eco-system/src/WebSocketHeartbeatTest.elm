module WebSocketHeartbeatTest exposing (main)

{-| Heartbeat and ping (plans/eco-system-websockets.md §4 WS4, W5, Appendix D.6), with a heartbeat
of 100 ms / 200 ms: a raw server that stops answering gets a ping, then a Close 1001, and the
client reports `Abnormal` (its readable fails "heartbeat ETIMEDOUT"); `ping` measures a round
trip, and fails `ECANCELED` once the connection is closed; a frame that trickles in for longer
than interval + timeout keeps the connection alive (liveness is counted in bytes); and a client
that does not read for a second while over 1 024 messages wait (reading paused) does not time
out.
-}

-- CHECK: silent peer: Cancelled: heartbeat ETIMEDOUT | Abnormal "" clean False | raw ping 8 | close 1001 ""
-- CHECK: ping: rtt ok True | after close err ECANCELED
-- CHECK: trickle: Binary 12000 bytes | Normal "" clean True
-- CHECK: backpressure: read 1100 | raw heartbeat close False | Normal "" clean True
-- EXIT: 0

import Bytes exposing (Bytes)
import Process
import Socket
import SocketTestHelp as H
import System
import Task exposing (Task)
import WebSocket
import WebSocketSha1 exposing (acceptFor)
import WebSocketTestHelp as W


main : System.SimpleProgram ()
main =
    H.program run


fast : WebSocket.ConnectOptions -> WebSocket.ConnectOptions
fast o =
    { o | heartbeat = Just { interval = 100, timeout = 200 } }


silentPeer : Socket.Listener -> Task String String
silentPeer listener =
    H.async
        (W.rawUpgradeClient listener (\key -> W.switching acceptFor key [])
            |> Task.andThen (\( conn, _ ) -> W.rawReadAll conn |> Task.andThen (\r -> H.socketErr (Socket.close conn) |> Task.map (\_ -> r)))
        )
        |> Task.andThen
            (\serverDone ->
                W.connectWith fast listener
                    |> Task.andThen
                        (\ws ->
                            W.readAll ws
                                |> Task.andThen
                                    (\( _, end ) ->
                                        WebSocket.closed ws
                                            |> Task.andThen
                                                (\info ->
                                                    serverDone
                                                        |> Task.map
                                                            (\received ->
                                                                "silent peer: " ++ end ++ " | " ++ W.closeInfoString info ++ " | raw " ++ W.framesString (W.parseFrames received)
                                                            )
                                                )
                                    )
                        )
            )


pingCase : Socket.Listener -> Task String String
pingCase listener =
    H.async (W.acceptOne listener |> Task.andThen W.echo)
        |> Task.andThen
            (\serverDone ->
                W.connect listener
                    |> Task.andThen
                        (\ws ->
                            WebSocket.ping ws
                                |> Task.mapError W.wsErr
                                |> Task.andThen
                                    (\rtt ->
                                        WebSocket.close WebSocket.Normal "" ws
                                            |> Task.mapError W.wsErr
                                            |> Task.andThen (\_ -> WebSocket.closed ws)
                                            |> Task.andThen (\_ -> W.describe (WebSocket.ping ws))
                                            |> Task.andThen (\after -> serverDone |> Task.map (\_ -> after))
                                            |> Task.map (\after -> "ping: rtt ok " ++ H.boolString (rtt >= 0 && rtt < 5000) ++ " | after close " ++ after)
                                    )
                        )
            )


trickle : Socket.Listener -> Task String String
trickle listener =
    let
        payload =
            W.bytesOfList (List.repeat 12000 9)

        whole =
            W.frame True 0 2 payload

        pieces =
            chunk 1000 (W.listOfBytes whole)
    in
    H.async
        (W.rawUpgradeClient listener (\key -> W.switching acceptFor key [])
            |> Task.andThen
                (\( conn, _ ) ->
                    pieces
                        |> List.map (\p -> Process.sleep 50 |> Task.andThen (\_ -> W.rawWrite (W.bytesOfList p) conn))
                        |> List.foldl (\t acc -> acc |> Task.andThen (\_ -> t)) (Task.succeed ())
                        |> Task.andThen (\_ -> W.rawWrite (W.frame True 0 8 (W.closePayload 1000 "")) conn)
                        |> Task.andThen (\_ -> W.rawRead conn)
                        |> Task.andThen (\_ -> H.socketErr (Socket.close conn))
                )
        )
        |> Task.andThen
            (\serverDone ->
                W.connectWith fast listener
                    |> Task.andThen
                        (\ws ->
                            W.readAll ws
                                |> Task.andThen
                                    (\( got, _ ) ->
                                        serverDone
                                            |> Task.andThen (\_ -> WebSocket.closed ws)
                                            |> Task.map (\info -> "trickle: " ++ String.join " | " (List.map W.messageString got) ++ " | " ++ W.closeInfoString info)
                                    )
                        )
            )


chunk : Int -> List a -> List (List a)
chunk n list =
    if List.isEmpty list then
        []

    else
        List.take n list :: chunk n (List.drop n list)


backpressure : Socket.Listener -> Task String String
backpressure listener =
    let
        flood =
            List.foldl (\b acc -> W.concatBytes acc b) (W.bytesOfList []) (List.repeat 1100 (W.frame True 0 2 (W.bytesOfList [ 1, 2, 3 ])))
    in
    H.async
        (W.rawUpgradeClient listener (\key -> W.concatBytes (W.switching acceptFor key []) flood)
            |> Task.andThen (\( conn, _ ) -> W.rawUntilClose conn)
        )
        |> Task.andThen
            (\serverDone ->
                W.connectWith fast listener
                    |> Task.andThen
                        (\ws ->
                            Process.sleep 1000
                                |> Task.andThen (\_ -> W.readMessages 1100 ws)
                                |> Task.andThen
                                    (\got ->
                                        WebSocket.close WebSocket.Normal "" ws
                                            |> Task.mapError W.wsErr
                                            |> Task.andThen (\_ -> serverDone)
                                            |> Task.andThen
                                                (\frames ->
                                                    WebSocket.closed ws
                                                        |> Task.map
                                                            (\info ->
                                                                "backpressure: read "
                                                                    ++ String.fromInt (List.length got)
                                                                    ++ " | raw heartbeat close "
                                                                    ++ H.boolString (List.any (\( op, p ) -> op == 8 && List.take 2 p == [ 3, 233 ]) frames)
                                                                    ++ " | "
                                                                    ++ W.closeInfoString info
                                                            )
                                                )
                                    )
                        )
            )


run : a -> Task String (List String)
run _ =
    H.socketErr H.listenLocal
        |> Task.andThen
            (\listener ->
                [ silentPeer listener, pingCase listener, trickle listener, backpressure listener ]
                    |> sequence
                    |> Task.andThen (\lines -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> lines))
            )


sequence : List (Task String String) -> Task String (List String)
sequence tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            t |> Task.andThen (\x -> sequence rest |> Task.map ((::) x))
