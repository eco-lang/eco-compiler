module TlsGet exposing (main)

{-| Fetches `/` from an HTTPS server over a raw TLS connection and prints the status line.

    eco make src/TlsGet.elm --output=tls-get && ./tls-get example.com

The host is the first argument, the port the optional second (default 443). The server's
certificate is checked against the system's certificate store.

-}

import Socket
import Socket.Tcp
import Socket.Tls
import Stream
import Stream.Log
import System
import Task exposing (Task)


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env ->
            case List.drop 1 env.args of
                host :: rest ->
                    let
                        port_ =
                            rest |> List.head |> Maybe.andThen String.toInt |> Maybe.withDefault 443
                    in
                    fetch host port_
                        |> Task.andThen (Stream.Log.line env.stdout)
                        |> Task.onError
                            (\err ->
                                Stream.Log.line env.stderr ("tls-get: " ++ err)
                                    |> Task.andThen (\_ -> System.setExitCode 1)
                            )
                        |> System.endSimpleProgram

                [] ->
                    Stream.Log.line env.stderr "usage: tls-get <host> [port]"
                        |> Task.andThen (\_ -> System.setExitCode 2)
                        |> System.endSimpleProgram
        )


fetch : String -> Int -> Task String String
fetch host port_ =
    Socket.lookup host
        |> Task.mapError Socket.errorToString
        |> Task.andThen
            (\addresses ->
                case addresses of
                    address :: _ ->
                        Socket.Tls.connect (Socket.Tls.defaultClientOptions host)
                            (Socket.Tcp.defaultConnectOptions address port_)
                            |> Task.mapError Socket.errorToString

                    [] ->
                        Task.fail ("no address for " ++ host)
            )
        |> Task.andThen (request host)


request : String -> Socket.Connection -> Task String String
request host conn =
    Socket.writable conn
        |> Stream.writeStringAsBytes ("GET / HTTP/1.1\r\nHost: " ++ host ++ "\r\nConnection: close\r\n\r\n")
        |> Task.andThen (\_ -> Stream.awaitAndPipeThrough Stream.textDecoder (Socket.readable conn))
        |> Task.andThen (Stream.readUntilClosed (\chunk acc -> Ok (acc ++ chunk)) "")
        |> Task.mapError Stream.errorToString
        |> Task.map (\response -> response |> String.lines |> List.head |> Maybe.withDefault "")
