module EcoSystemWebSocket exposing (main)

{-| Stress program for eco/system WebSockets (plans/eco-system-websockets.md §4 WS4, base plan
§3.3.3 gate 3).

  - `max 1 (numLoops // 5)` waves (`-n 10`: 2 waves, 1 000 connections) of 500 concurrent echo
    connections over loopback, both sides with a 50 ms heartbeat (so pings and pongs flow while
    the wave runs): 500 servers accept and upgrade a `Socket.Tcp` connection and echo until their
    readable is `Closed`; 500 clients send a text, a binary and a text message (index-dependent),
    read the three echoes back, close and check that both sides report a clean close.
  - 64 MiB of messages on one connection: 1 024 binary messages of 64 KiB, checksummed on both
    sides (the 32-bit word sum); the server answers the count and the sum in a text message.

The listener is closed at the end, so the program exits by itself.
-}

-- CHECK: EcoSystemWebSocket: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Process
import Socket
import Socket.Address as Address exposing (Endpoint(..), Family(..))
import Socket.Tcp
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)
import WebSocket exposing (WebSocket, Whole)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram { label = "EcoSystemWebSocket", run = run }


run : StressFlags -> Task Never Bool
run flags =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 0)
        |> Task.andThen
            (\listener ->
                StressHarness.loopWhile flags (max 1 (flags.numLoops // 5)) (wave listener)
                    |> Task.andThen
                        (\wavesOk ->
                            if wavesOk then
                                bigTransfer listener

                            else
                                Task.succeed False
                        )
                    |> Task.andThen
                        (\ok ->
                            Socket.closeListener listener
                                |> Task.map (\_ -> ok)
                                |> Task.onError (\_ -> Task.succeed False)
                        )
                    |> Task.mapError never
            )
        |> Task.onError (\_ -> Task.succeed False)



-- CONCURRENCY


async : Task Never a -> Task x (Task Never (Maybe a))
async task =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn
                    (task
                        |> Task.andThen (\v -> Stream.write v (Stream.writable t) |> Task.map (\_ -> ()) |> Task.onError (\_ -> Task.succeed ()))
                    )
                    |> Task.map
                        (\_ ->
                            Stream.read (Stream.readable t)
                                |> Task.map Just
                                |> Task.onError (\_ -> Task.succeed Nothing)
                        )
            )


all : List (Task Never (Maybe Bool)) -> Task Never Bool
all waits =
    Task.sequence waits
        |> Task.map (List.all ((==) (Just True)))



-- CONNECTIONS


heartbeat : Maybe WebSocket.Heartbeat
heartbeat =
    Just { interval = 50, timeout = 2000 }


portOf : Socket.Listener -> Int
portOf listener =
    case Socket.listenerEndpoint listener of
        Inet ep ->
            ep.port_

        Unix _ ->
            0


connect : Socket.Listener -> Task Socket.Error (WebSocket Whole)
connect listener =
    WebSocket.defaultConnectOptions ("ws://127.0.0.1:" ++ String.fromInt (portOf listener) ++ "/stress")
        |> (\o -> { o | heartbeat = heartbeat })
        |> WebSocket.connect


accept : Socket.Listener -> Task Socket.Error (WebSocket Whole)
accept listener =
    let
        options =
            WebSocket.defaultAcceptOptions
    in
    Socket.accept listener
        |> Task.andThen WebSocket.upgradeRequest
        |> Task.andThen (WebSocket.accept { options | heartbeat = heartbeat })


{-| Echo until the readable ends; True if it ended `Closed` (a clean close).
-}
echo : WebSocket Whole -> Task Never Bool
echo ws =
    Stream.read (WebSocket.readable ws)
        |> Task.andThen (\m -> Stream.write m (WebSocket.writable ws) |> Task.map (\_ -> Nothing))
        |> Task.onError (\e -> Task.succeed (Just (e == Stream.Closed)))
        |> Task.andThen
            (\r ->
                case r of
                    Nothing ->
                        echo ws

                    Just clean ->
                        Task.succeed clean
            )


server : Socket.Listener -> Task Never Bool
server listener =
    accept listener
        |> Task.andThen (\ws -> echo ws |> Task.mapError never |> Task.andThen (\clean -> WebSocket.closed ws |> Task.map (\info -> clean && info.clean)))
        |> Task.onError (\_ -> Task.succeed False)


bytesFor : Int -> Bytes
bytesFor n =
    E.encode (E.sequence (List.map E.unsignedInt8 (List.range 0 (modBy 64 n))))


client : Socket.Listener -> Int -> Int -> Task Never Bool
client listener w j =
    let
        messages =
            [ WebSocket.Text ("w" ++ String.fromInt w ++ "c" ++ String.fromInt j ++ ":" ++ String.repeat (modBy 97 (w * 31 + j * 7)) "é")
            , WebSocket.Binary (bytesFor (w * 13 + j))
            , WebSocket.Text "end"
            ]

        readN n ws acc =
            if n <= 0 then
                Task.succeed (List.reverse acc)

            else
                Stream.read (WebSocket.readable ws) |> Task.andThen (\m -> readN (n - 1) ws (m :: acc))
    in
    connect listener
        |> Task.mapError (\_ -> Stream.Closed)
        |> Task.andThen
            (\ws ->
                List.foldl (\m acc -> acc |> Task.andThen (\_ -> Stream.write m (WebSocket.writable ws) |> Task.map (\_ -> ()))) (Task.succeed ()) messages
                    |> Task.andThen (\_ -> readN 3 ws [])
                    |> Task.andThen
                        (\got ->
                            WebSocket.close WebSocket.Normal "" ws
                                |> Task.mapError (\_ -> Stream.Closed)
                                |> Task.andThen (\_ -> WebSocket.closed ws)
                                |> Task.map (\info -> got == messages && info.clean)
                        )
            )
        |> Task.onError (\_ -> Task.succeed False)


wave : Socket.Listener -> Int -> Task Never Bool
wave listener w =
    let
        indexes =
            List.range 0 499
    in
    Task.sequence (List.map (\_ -> async (server listener)) indexes)
        |> Task.andThen
            (\servers ->
                Task.sequence (List.map (\j -> async (client listener w j)) indexes)
                    |> Task.andThen (\clients -> all (clients ++ servers))
            )



-- 64 MIB


messageCount : Int
messageCount =
    1024


wordOf : Int -> Int
wordOf i =
    modBy 4294967296 (i * 2654435761 + 12345)


{-| 64 KiB: the 32-bit word `wordOf i`, repeated (by doubling).
-}
message : Int -> Bytes
message i =
    let
        double n b =
            if n <= 0 then
                b

            else
                double (n - 1) (E.encode (E.sequence [ E.bytes b, E.bytes b ]))
    in
    double 14 (E.encode (E.unsignedInt32 LE (wordOf i)))


expectedSum : Int
expectedSum =
    List.foldl (\i acc -> modBy 4294967296 (acc + 16384 * wordOf i)) 0 (List.range 0 (messageCount - 1))


wordSum : Bytes -> Int -> Int
wordSum bytes start =
    let
        words =
            Bytes.width bytes // 4
    in
    D.decode
        (D.loop ( words, start )
            (\( m, acc ) ->
                if m <= 0 then
                    D.succeed (D.Done acc)

                else
                    D.unsignedInt32 LE |> D.map (\x -> D.Loop ( m - 1, modBy 4294967296 (acc + x) ))
            )
        )
        bytes
        |> Maybe.withDefault -1


{-| Read binary messages until a text one arrives; ( count, byte length, word sum ).
-}
receiver : WebSocket Whole -> ( Int, Int, Int ) -> Task Stream.Error ( Int, Int, Int )
receiver ws ( count, length, sum ) =
    Stream.read (WebSocket.readable ws)
        |> Task.andThen
            (\m ->
                case m of
                    WebSocket.Binary b ->
                        receiver ws ( count + 1, length + Bytes.width b, wordSum b sum )

                    WebSocket.Text _ ->
                        Task.succeed ( count, length, sum )
            )


sender : WebSocket Whole -> Int -> Task Stream.Error ()
sender ws i =
    if i >= messageCount then
        Stream.write (WebSocket.Text "done") (WebSocket.writable ws) |> Task.map (\_ -> ())

    else
        Stream.write (WebSocket.Binary (message i)) (WebSocket.writable ws)
            |> Task.andThen (\_ -> sender ws (i + 1))


bigTransfer : Socket.Listener -> Task Never Bool
bigTransfer listener =
    async
        (accept listener
            |> Task.mapError (\_ -> Stream.Closed)
            |> Task.andThen
                (\ws ->
                    receiver ws ( 0, 0, 0 )
                        |> Task.andThen
                            (\( count, length, sum ) ->
                                Stream.write (WebSocket.Text (String.join " " (List.map String.fromInt [ count, length, sum ]))) (WebSocket.writable ws)
                                    |> Task.andThen (\_ -> Stream.read (WebSocket.readable ws))
                                    |> Task.map (\_ -> False)
                                    |> Task.onError (\e -> Task.succeed (e == Stream.Closed))
                            )
                )
            |> Task.onError (\_ -> Task.succeed False)
        )
        |> Task.andThen
            (\served ->
                connect listener
                    |> Task.mapError (\_ -> Stream.Closed)
                    |> Task.andThen
                        (\ws ->
                            sender ws 0
                                |> Task.andThen (\_ -> Stream.read (WebSocket.readable ws))
                                |> Task.andThen
                                    (\answer ->
                                        WebSocket.close WebSocket.Normal "" ws
                                            |> Task.mapError (\_ -> Stream.Closed)
                                            |> Task.map
                                                (\_ ->
                                                    answer
                                                        == WebSocket.Text
                                                            (String.join " "
                                                                (List.map String.fromInt [ messageCount, messageCount * 65536, expectedSum ])
                                                            )
                                                )
                                    )
                        )
                    |> Task.onError (\_ -> Task.succeed False)
                    |> Task.andThen (\ok -> served |> Task.map (\s -> ok && s == Just True))
            )
