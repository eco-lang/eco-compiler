module EcoSystemSocket exposing (main)

{-| Stress program for eco/system TCP sockets (plans/eco-system-sockets.md §4 S3, base plan §3.3.3
gate 3).

  - `2 * numLoops` waves (`-n 10`: 20 waves, 2 000 connections) of 100 concurrent short
    connections over loopback: 100 parked `Socket.accept` tasks and 100 clients at once; every
    client sends a different message (index-dependent length), half-closes and reads the echo to
    `Closed`; every server reads to `Closed`, replies and closes. Every reply is checked.
  - one 64 MiB transfer in 64 KiB chunks (1 024 writes), checksummed on both sides: the sender
    computes the 32-bit word sum of what it sends, the receiver of what arrives (whatever the
    chunking on the way), and the receiver's sum and length come back for comparison.

  - a UDP burst (S4): `numLoops` waves (`-n 10`: 1 000 datagrams) of 100 parked
    `Socket.Udp.receive` tasks and 100 datagrams of index-dependent sizes (up to about 4 KiB) sent
    one after another; every datagram must arrive exactly once with its contents intact.

The listener and the UDP sockets are closed at the end, so the program exits by itself.
-}

-- CHECK: EcoSystemSocket: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Process
import Socket
import Socket.Address as Address exposing (Endpoint(..), Family(..))
import Socket.Tcp
import Socket.Udp
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram { label = "EcoSystemSocket", run = run }


run : StressFlags -> Task Never Bool
run flags =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 0)
        |> Task.andThen
            (\listener ->
                StressHarness.loopWhile flags (max 1 (2 * flags.numLoops)) (wave listener)
                    |> Task.andThen
                        (\wavesOk ->
                            if wavesOk then
                                bigTransfer listener

                            else
                                Task.succeed False
                        )
                    |> Task.andThen
                        (\ok ->
                            if ok then
                                udpBurst flags

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


{-| Start `task` in its own process; the returned task waits for its result (through an in-memory
stream).
-}
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



-- SHORT CONNECTIONS


toBytes : String -> Bytes
toBytes s =
    E.encode (E.string s)


fromBytes : Bytes -> String
fromBytes b =
    D.decode (D.string (Bytes.width b)) b |> Maybe.withDefault "<invalid>"


readText : Stream.Readable Bytes -> Task Stream.Error String
readText stream =
    Stream.readUntilClosed (\piece acc -> Ok (acc ++ fromBytes piece)) "" stream


portOf : Socket.Listener -> Int
portOf listener =
    case Socket.listenerEndpoint listener of
        Inet ep ->
            ep.port_

        Unix _ ->
            0


connect : Socket.Listener -> Task Socket.Error Socket.Connection
connect listener =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (portOf listener))


server : Socket.Listener -> Task Never Bool
server listener =
    Socket.accept listener
        |> Task.mapError (\_ -> Stream.Closed)
        |> Task.andThen
            (\conn ->
                readText (Socket.readable conn)
                    |> Task.andThen
                        (\text ->
                            Stream.write (toBytes ("echo:" ++ text)) (Socket.writable conn)
                                |> Task.andThen Stream.closeWritable
                        )
            )
        |> Task.map (\_ -> True)
        |> Task.onError (\_ -> Task.succeed False)


client : Socket.Listener -> Int -> Int -> Task Never Bool
client listener w j =
    let
        message =
            "w" ++ String.fromInt w ++ "c" ++ String.fromInt j ++ ":" ++ String.repeat (modBy 97 (w * 31 + j * 7)) "x"
    in
    connect listener
        |> Task.mapError (\_ -> Stream.Closed)
        |> Task.andThen
            (\conn ->
                Stream.write (toBytes message) (Socket.writable conn)
                    |> Task.andThen Stream.closeWritable
                    |> Task.andThen (\_ -> readText (Socket.readable conn))
            )
        |> Task.map (\reply -> reply == "echo:" ++ message)
        |> Task.onError (\_ -> Task.succeed False)


wave : Socket.Listener -> Int -> Task Never Bool
wave listener w =
    let
        indexes =
            List.range 0 99
    in
    Task.sequence (List.map (\_ -> async (server listener)) indexes)
        |> Task.andThen
            (\servers ->
                Task.sequence (List.map (\j -> async (client listener w j)) indexes)
                    |> Task.andThen (\clients -> all (clients ++ servers))
            )



-- ONE BIG TRANSFER


chunkCount : Int
chunkCount =
    1024


wordOf : Int -> Int
wordOf i =
    modBy 4294967296 (i * 2654435761 + 12345)


{-| 64 KiB: the 32-bit little-endian word `wordOf i`, repeated (by doubling).
-}
chunk : Int -> Bytes
chunk i =
    let
        double n b =
            if n <= 0 then
                b

            else
                double (n - 1) (E.encode (E.sequence [ E.bytes b, E.bytes b ]))
    in
    double 14 (E.encode (E.unsignedInt32 LE (wordOf i)))


{-| The 32-bit word sum of everything sent: 16 384 copies of each chunk's word.
-}
expectedSum : Int
expectedSum =
    List.foldl (\i acc -> modBy 4294967296 (acc + 16384 * wordOf i)) 0 (List.range 0 (chunkCount - 1))


sender : Stream.Writable Bytes -> Int -> Task Stream.Error ()
sender w i =
    if i >= chunkCount then
        Stream.closeWritable w

    else
        Stream.write (chunk i) w
            |> Task.andThen (\_ -> sender w (i + 1))


{-| ( stream offset, word sum ): the sum of the stream's 32-bit little-endian words, aligned to the
stream (not to the chunks it arrives in).
-}
type alias Sum =
    ( Int, Int )


byteWeight : Int -> Int
byteWeight offset =
    case modBy 4 offset of
        0 ->
            1

        1 ->
            256

        2 ->
            65536

        _ ->
            16777216


addChunk : Bytes -> Sum -> Sum
addChunk bytes ( offset, sum ) =
    let
        width =
            Bytes.width bytes

        lead =
            min width (modBy 4 (4 - modBy 4 offset))

        words =
            (width - lead) // 4

        tail =
            width - lead - 4 * words

        oneByte ( off, s ) =
            D.unsignedInt8 |> D.map (\b -> ( off + 1, modBy 4294967296 (s + b * byteWeight off) ))

        bytesStep n state =
            if n <= 0 then
                D.succeed (D.Done state)

            else
                D.map (\st -> D.Loop ( n - 1, st )) (oneByte state)

        bytesLoop n state =
            D.loop ( n, state ) (\( m, st ) -> bytesStep m st)

        wordsLoop n ( off, s ) =
            D.loop ( n, s )
                (\( m, acc ) ->
                    if m <= 0 then
                        D.succeed (D.Done ( off + 4 * n, acc ))

                    else
                        D.unsignedInt32 LE |> D.map (\x -> D.Loop ( m - 1, modBy 4294967296 (acc + x) ))
                )

        decoder =
            bytesLoop lead ( offset, sum )
                |> D.andThen (wordsLoop words)
                |> D.andThen (bytesLoop tail)
    in
    D.decode decoder bytes |> Maybe.withDefault ( -1, -1 )


receiver : Stream.Readable Bytes -> Task Stream.Error Sum
receiver stream =
    Stream.readUntilClosed (\b acc -> Ok (addChunk b acc)) ( 0, 0 ) stream


bigTransfer : Socket.Listener -> Task Never Bool
bigTransfer listener =
    async
        (Socket.accept listener
            |> Task.mapError (\_ -> Stream.Closed)
            |> Task.andThen
                (\conn ->
                    receiver (Socket.readable conn)
                        |> Task.andThen
                            (\( length, sum ) ->
                                Stream.write (toBytes (String.fromInt length ++ " " ++ String.fromInt sum)) (Socket.writable conn)
                                    |> Task.andThen Stream.closeWritable
                            )
                )
            |> Task.map (\_ -> True)
            |> Task.onError (\_ -> Task.succeed False)
        )
        |> Task.andThen
            (\served ->
                connect listener
                    |> Task.mapError (\_ -> Stream.Closed)
                    |> Task.andThen
                        (\conn ->
                            sender (Socket.writable conn) 0
                                |> Task.andThen (\_ -> readText (Socket.readable conn))
                        )
                    |> Task.map (\reply -> reply == String.fromInt (chunkCount * 65536) ++ " " ++ String.fromInt expectedSum)
                    |> Task.onError (\_ -> Task.succeed False)
                    |> Task.andThen (\ok -> served |> Task.map (\s -> ok && s == Just True))
            )



-- UDP BURST


udpBurst : StressFlags -> Task Never Bool
udpBurst flags =
    let
        bind =
            Socket.Udp.bind (Socket.Udp.defaultBindOptions (Address.loopback IPv4) 0)
    in
    Task.map2 Tuple.pair bind bind
        |> Task.andThen
            (\( a, b ) ->
                StressHarness.loopWhile flags (max 1 flags.numLoops) (udpWave a b)
                    |> Task.andThen (\ok -> Socket.Udp.close a |> Task.andThen (\_ -> Socket.Udp.close b) |> Task.map (\_ -> ok))
                    |> Task.mapError never
            )
        |> Task.onError (\_ -> Task.succeed False)


udpWave : Socket.Udp.Socket -> Socket.Udp.Socket -> Int -> Task Never Bool
udpWave a b w =
    let
        indexes =
            List.range 0 99

        message j =
            "u" ++ String.fromInt w ++ "d" ++ String.fromInt j ++ ":" ++ String.repeat (modBy 4001 (w * 977 + j * 389)) "y"

        to =
            Socket.Udp.localEndpoint b

        udpReceiver =
            Socket.Udp.receive b
                |> Task.map (\d -> fromBytes d.data)
                |> Task.onError (\_ -> Task.succeed "<error>")
    in
    Task.sequence (List.map (\_ -> async udpReceiver) indexes)
        |> Task.andThen
            (\waits ->
                Task.sequence (List.map (\j -> Socket.Udp.send to (toBytes (message j)) a) indexes)
                    |> Task.map (\_ -> True)
                    |> Task.onError (\_ -> Task.succeed False)
                    |> Task.andThen
                        (\sent ->
                            Task.sequence waits
                                |> Task.map
                                    (\got ->
                                        sent
                                            && (List.sort (List.map (Maybe.withDefault "<lost>") got)
                                                    == List.sort (List.map message indexes)
                                               )
                                    )
                        )
            )
