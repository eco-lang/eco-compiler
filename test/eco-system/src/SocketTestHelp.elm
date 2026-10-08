module SocketTestHelp exposing
    ( program, async, socketErr, streamErr, describe
    , bytesOf, bytesToString, readAll, writeAll, send
    , listenLocal, portOf, connectTo, endpointToString, testPort, boolString
    , acceptRead
    )

{-| Shared helpers for the socket tests (not a test: no `main`;
plans/eco-system-sockets.md §4 S3).

The tests print their observations to the program's real stdout through `Stream.Log`, so the
`-- CHECK:` patterns are matched against raw fd output. `async` runs a task in its own process and
hands back a task that waits for its result (through an in-memory stream), so a simple program can
run a server and a client side by side.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Process
import Socket
import Socket.Address as Address exposing (Endpoint(..), Family(..))
import Socket.Tcp
import Stream
import Stream.Log
import System
import System.File.Path as Path
import Task exposing (Task)


{-| A simple program that runs `run env` and prints every line it returns, or `error: <reason>`
if it fails.
-}
program : (System.Environment -> Task String (List String)) -> System.SimpleProgram ()
program run =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (run env
                    |> Task.map (String.join "\n")
                    |> Task.onError (\err -> Task.succeed ("error: " ++ err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )


{-| Start `task` in its own process; the returned task waits for its result.
-}
async : Task String a -> Task x (Task String a)
async task =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Process.spawn
                    (task
                        |> Task.map Ok
                        |> Task.onError (\e -> Task.succeed (Err e))
                        |> Task.andThen (\r -> Stream.write r (Stream.writable t))
                        |> Task.map (\_ -> ())
                        |> Task.onError (\_ -> Task.succeed ())
                    )
                    |> Task.map
                        (\_ ->
                            Stream.read (Stream.readable t)
                                |> Task.mapError Stream.errorToString
                                |> Task.andThen
                                    (\r ->
                                        case r of
                                            Ok v ->
                                                Task.succeed v

                                            Err e ->
                                                Task.fail e
                                    )
                        )
            )


socketErr : Task Socket.Error a -> Task String a
socketErr =
    Task.mapError Socket.errorToString


streamErr : Task Stream.Error a -> Task String a
streamErr =
    Task.mapError Stream.errorToString


{-| `"ok"`, or `"err <code>"` for a failed socket task.
-}
describe : Task Socket.Error a -> Task x String
describe task =
    task
        |> Task.map (\_ -> "ok")
        |> Task.onError (\e -> Task.succeed ("err " ++ Socket.errorCode e))


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


bytesOf : String -> Bytes
bytesOf s =
    Bytes.Encode.encode (Bytes.Encode.string s)


bytesToString : Bytes -> String
bytesToString b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b
        |> Maybe.withDefault "<invalid utf-8>"


{-| Read a byte stream to `Closed`, as text.
-}
readAll : Stream.Readable Bytes -> Task Stream.Error String
readAll stream =
    Stream.readUntilClosed (\chunk acc -> Ok (acc ++ bytesToString chunk)) "" stream


{-| Write `text` and close the writable (a half-close on a connection).
-}
writeAll : String -> Stream.Writable Bytes -> Task Stream.Error ()
writeAll text w =
    Stream.write (bytesOf text) w
        |> Task.andThen Stream.closeWritable


{-| Client side of an echo exchange: write `text`, half-close, read the reply to `Closed`.
-}
send : String -> Socket.Connection -> Task String String
send text conn =
    streamErr (writeAll text (Socket.writable conn))
        |> Task.andThen (\_ -> streamErr (readAll (Socket.readable conn)))


{-| Accept one connection and read it to `Closed`.
-}
acceptRead : Socket.Listener -> Task String String
acceptRead listener =
    socketErr (Socket.accept listener)
        |> Task.andThen (\conn -> streamErr (readAll (Socket.readable conn)))


{-| Listen on 127.0.0.1 with a port picked by the system.
-}
listenLocal : Task Socket.Error Socket.Listener
listenLocal =
    Socket.Tcp.listen (Socket.Tcp.defaultListenOptions (Address.loopback IPv4) 0)


portOf : Socket.Listener -> Int
portOf listener =
    case Socket.listenerEndpoint listener of
        Inet ep ->
            ep.port_

        Unix _ ->
            0


connectTo : Socket.Listener -> Task Socket.Error Socket.Connection
connectTo listener =
    Socket.Tcp.connect (Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (portOf listener))


endpointToString : Endpoint -> String
endpointToString endpoint =
    case endpoint of
        Inet ep ->
            "inet " ++ Address.toString ep.address ++ " " ++ String.fromInt ep.port_

        Unix path ->
            if path == Path.empty then
                -- an unnamed socket (`Unix ""`)
                "unix \"\""

            else
                "unix \"" ++ Path.toPosixString path ++ "\""


{-| The free, unbound port the test harness hands every test (`ECO_TEST_PORT`).
-}
testPort : Task x Int
testPort =
    System.getEnvironmentVariables
        |> Task.map (Dict.get "ECO_TEST_PORT" >> Maybe.andThen String.toInt >> Maybe.withDefault 9)
