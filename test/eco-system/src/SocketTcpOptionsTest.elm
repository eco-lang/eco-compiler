module SocketTcpOptionsTest exposing (main)

{-| Connection options (plans/eco-system-sockets.md Appendix A, §D.3): `setNoDelay` and
`setKeepAlive` succeed on a TCP connection (also when set at connect time) and succeed with no
effect on a Unix domain connection.
-}

-- CHECK: tcp connect with options: ok
-- CHECK: tcp noDelay True: ok
-- CHECK: tcp noDelay False: ok
-- CHECK: tcp keepAlive 1500: ok
-- CHECK: tcp keepAlive off: ok
-- CHECK: unix noDelay: ok
-- CHECK: unix keepAlive: ok
-- EXIT: 0

import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tcp
import Socket.Unix
import SocketTestHelp as H
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)


connectPair : Socket.Listener -> Task String Socket.Connection -> Task String ( Socket.Connection, Socket.Connection )
connectPair listener connect =
    H.async (H.socketErr (Socket.accept listener))
        |> Task.andThen (\accepted -> connect |> Task.andThen (\c -> accepted |> Task.map (\s -> ( c, s ))))


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            H.socketErr H.listenLocal
                |> Task.andThen
                    (\listener ->
                        let
                            d =
                                Socket.Tcp.defaultConnectOptions (Address.loopback IPv4) (H.portOf listener)
                        in
                        connectPair listener (H.socketErr (Socket.Tcp.connect { d | noDelay = True, keepAlive = Just 1500 }))
                            |> Task.andThen
                                (\( c, s ) ->
                                    Task.sequence
                                        [ Task.succeed "tcp connect with options: ok"
                                        , H.describe (Socket.Tcp.setNoDelay True c) |> Task.map ((++) "tcp noDelay True: ")
                                        , H.describe (Socket.Tcp.setNoDelay False s) |> Task.map ((++) "tcp noDelay False: ")
                                        , H.describe (Socket.Tcp.setKeepAlive (Just 1500) c) |> Task.map ((++) "tcp keepAlive 1500: ")
                                        , H.describe (Socket.Tcp.setKeepAlive Nothing c) |> Task.map ((++) "tcp keepAlive off: ")
                                        ]
                                        |> Task.andThen
                                            (\lines ->
                                                Socket.close c
                                                    |> Task.andThen (\_ -> Socket.close s)
                                                    |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                                    |> Task.map (\_ -> lines)
                                            )
                                )
                    )
                |> Task.andThen
                    (\tcpLines ->
                        Task.mapError File.errorToString (File.makeTempDirectory "eco-sock-opt")
                            |> Task.andThen
                                (\dir ->
                                    let
                                        path =
                                            Path.append (Path.fromPosixString "o.sock") dir
                                    in
                                    H.socketErr (Socket.Unix.listen (Socket.Unix.defaultListenOptions path))
                                        |> Task.andThen
                                            (\listener ->
                                                connectPair listener (H.socketErr (Socket.Unix.connect path))
                                                    |> Task.andThen
                                                        (\( c, s ) ->
                                                            Task.sequence
                                                                [ H.describe (Socket.Tcp.setNoDelay True c) |> Task.map ((++) "unix noDelay: ")
                                                                , H.describe (Socket.Tcp.setKeepAlive (Just 1500) s) |> Task.map ((++) "unix keepAlive: ")
                                                                ]
                                                                |> Task.andThen
                                                                    (\lines ->
                                                                        Socket.close c
                                                                            |> Task.andThen (\_ -> Socket.close s)
                                                                            |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                                                            |> Task.map (\_ -> lines)
                                                                    )
                                                        )
                                            )
                                        |> Task.andThen
                                            (\lines ->
                                                File.remove { recursive = True } dir
                                                    |> Task.map (\_ -> tcpLines ++ lines)
                                                    |> Task.mapError File.errorToString
                                            )
                                )
                    )
        )
