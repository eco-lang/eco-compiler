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
import Stream.Transformation
import System
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            case List.drop 1 env.args of
                host :: rest ->
                    let
                        port_ =
                            rest |> List.head |> Maybe.andThen String.toInt |> Maybe.withDefault 443
                    in
                    fetch host port_
                        |> Task.andThen (\statusLine -> Stream.logLine statusLine env.stdout)
                        |> Task.onError
                            (\err ->
                                Stream.logLine ("tls-get: " ++ err) env.stderr
                                    |> Task.andThen (\_ -> System.setExitCode 1)
                            )

                [] ->
                    Stream.logLine "usage: tls-get <host> [port]" env.stderr
                        |> Task.andThen (\_ -> System.setExitCode 2)
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
        |> Stream.writeString ("GET / HTTP/1.1\r\nHost: " ++ host ++ "\r\nConnection: close\r\n\r\n")
        |> Task.andThen (\_ -> Stream.awaitAndPipeThrough Stream.Transformation.textDecoder (Socket.readable conn))
        |> Task.andThen (Stream.readUntilClosed (\chunk acc -> Ok (acc ++ chunk)) "")
        |> Task.mapError Stream.errorToString
        |> Task.map (\response -> response |> String.lines |> List.head |> Maybe.withDefault "")
