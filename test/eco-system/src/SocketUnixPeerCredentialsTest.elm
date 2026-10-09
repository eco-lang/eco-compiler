module SocketUnixPeerCredentialsTest exposing (main)

-- SKIP-JS: Node has no peer credentials (plans/eco-system-sockets.md Appendix E)

{-| `Socket.Unix.peerCredentials` (plans/eco-system-sockets.md §D.3): both ends of a Unix domain
connection made by this program see this program's process id (the `$PPID` of a shell it runs:
`/proc/self` is Linux-only), user id and group id
(those of a directory it created); a TCP connection fails with `EINVAL`.
-}

-- CHECK: client side: pid True uid True gid True
-- CHECK: server side: pid True uid True gid True
-- CHECK: tcp: EINVAL
-- EXIT: 0

import ProcessTestHelp exposing (bytesToString, noShell)
import Socket
import Socket.Unix
import SocketTestHelp as H
import System
import System.File as File
import System.File.Path as Path
import System.Process as P
import Task exposing (Task)


fileErr : Task File.Error a -> Task String a
fileErr =
    Task.mapError File.errorToString


describeCreds : { pid : Int, uid : Int, gid : Int } -> { pid : Int, uid : Int, gid : Int } -> String
describeCreds expected got =
    "pid "
        ++ H.boolString (expected.pid == got.pid)
        ++ " uid "
        ++ H.boolString (expected.uid == got.uid)
        ++ " gid "
        ++ H.boolString (expected.gid == got.gid)


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            ownPid
                |> Task.andThen
                    (\self ->
                        fileErr (File.makeTempDirectory "eco-sock-cred")
                            |> Task.andThen
                                (\dir ->
                                    fileErr (File.metadata { resolveLink = False } dir)
                                        |> Task.andThen
                                            (\meta ->
                                                let
                                                    expected =
                                                        { pid = self
                                                        , uid = meta.userID
                                                        , gid = meta.groupID
                                                        }

                                                    path =
                                                        Path.append (Path.fromPosixString "c.sock") dir
                                                in
                                                H.socketErr (Socket.Unix.listen (Socket.Unix.defaultListenOptions path))
                                                    |> Task.andThen
                                                        (\listener ->
                                                            H.async (H.socketErr (Socket.accept listener))
                                                                |> Task.andThen
                                                                    (\accepted ->
                                                                        H.socketErr (Socket.Unix.connect path)
                                                                            |> Task.andThen (\c -> accepted |> Task.map (\s -> ( c, s )))
                                                                    )
                                                                |> Task.andThen
                                                                    (\( c, s ) ->
                                                                        H.socketErr (Socket.Unix.peerCredentials c)
                                                                            |> Task.andThen
                                                                                (\cc ->
                                                                                    H.socketErr (Socket.Unix.peerCredentials s)
                                                                                        |> Task.map (\sc -> [ "client side: " ++ describeCreds expected cc, "server side: " ++ describeCreds expected sc ])
                                                                                )
                                                                            |> Task.andThen
                                                                                (\lines ->
                                                                                    Socket.close c
                                                                                        |> Task.andThen (\_ -> Socket.close s)
                                                                                        |> Task.andThen (\_ -> H.socketErr (Socket.closeListener listener))
                                                                                        |> Task.map (\_ -> lines)
                                                                                )
                                                                    )
                                                        )
                                                    |> Task.andThen (\lines -> fileErr (File.remove { recursive = True } dir) |> Task.map (\_ -> lines))
                                            )
                                )
                    )
                |> Task.andThen
                    (\unixLines ->
                        H.socketErr H.listenLocal
                            |> Task.andThen
                                (\listener ->
                                    H.socketErr (H.connectTo listener)
                                        |> Task.andThen
                                            (\c ->
                                                Socket.Unix.peerCredentials c
                                                    |> Task.map (\_ -> "ok?!")
                                                    |> Task.onError (\e -> Task.succeed (Socket.errorCode e))
                                                    |> Task.andThen (\r -> Socket.close c |> Task.map (\_ -> r))
                                            )
                                        |> Task.andThen (\r -> H.socketErr (Socket.closeListener listener) |> Task.map (\_ -> r))
                                )
                            |> Task.map (\tcp -> unixLines ++ [ "tcp: " ++ tcp ])
                    )
        )


ownPid : Task String Int
ownPid =
    P.run "sh" [ "-c", "echo $PPID" ] noShell
        |> Task.mapError (\_ -> "sh -c 'echo $PPID' failed")
        |> Task.map (\r -> bytesToString r.stdout |> String.trim |> String.toInt |> Maybe.withDefault -1)
