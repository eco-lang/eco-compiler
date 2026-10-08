module SocketUnixTest exposing (main)

{-| Unix domain stream sockets (plans/eco-system-sockets.md §D.3):

  - listen in a temp directory with `permissions = Just 384` (0o600; checked with `stat`), set
    before any client can connect;
  - connect and echo; the accepted side's local endpoint is the path and its remote the empty
    path; the client's remote is the path and its local the empty path;
  - `closeListener` removes the socket file;
  - `removeExisting` replaces a stale socket (a hard link to a closed listener's socket file) and
    refuses a regular file (`EADDRINUSE`), as does a listen without it;
  - connecting to a missing path fails `ENOENT`; a 200-byte path fails `ENAMETOOLONG` before any
    system call, for connect and for listen.

-}

-- CHECK: permissions: 600
-- CHECK: server got: ping over unix
-- CHECK: client got: pong: ping over unix
-- CHECK: server local is the path: True
-- CHECK: server remote: unix ""
-- CHECK: client remote is the path: True
-- CHECK: client local: unix ""
-- CHECK: socket file after close: ENOENT
-- CHECK: stale without removeExisting: EADDRINUSE
-- CHECK: stale with removeExisting: ok
-- CHECK: regular file with removeExisting: EADDRINUSE
-- CHECK: missing path: ENOENT
-- CHECK: long path connect: ENAMETOOLONG
-- CHECK: long path listen: ENAMETOOLONG
-- EXIT: 0

import Bytes exposing (Bytes)
import Socket
import Socket.Address exposing (Endpoint(..))
import Socket.Unix
import SocketTestHelp as H
import System
import System.File as File
import System.File.Path as Path exposing (Path)
import System.Process as P
import Task exposing (Task)


fileErr : Task File.Error a -> Task String a
fileErr =
    Task.mapError File.errorToString


isPath : Path -> Endpoint -> Bool
isPath path endpoint =
    case endpoint of
        Unix p ->
            Path.toPosixString p == Path.toPosixString path

        Inet _ ->
            False


permissionsOf : Path -> Task String String
permissionsOf path =
    let
        d =
            P.defaultRunOptions
    in
    P.run "stat" [ "-c", "%a", Path.toPosixString path ] { d | shell = P.NoShell }
        |> Task.map (\r -> String.trim (H.bytesToString r.stdout))
        |> Task.mapError (\_ -> "stat failed")


listenWith : Path -> Bool -> Task Socket.Error Socket.Listener
listenWith path removeExisting =
    let
        d =
            Socket.Unix.defaultListenOptions path
    in
    Socket.Unix.listen { d | removeExisting = removeExisting }


codeOf : Task Socket.Error Socket.Listener -> Task x String
codeOf task =
    task
        |> Task.andThen (\l -> Socket.closeListener l |> Task.map (\_ -> "ok"))
        |> Task.onError (\e -> Task.succeed (Socket.errorCode e))


echo : Path -> Task String (List String)
echo path =
    let
        d =
            Socket.Unix.defaultListenOptions path
    in
    H.socketErr (Socket.Unix.listen { d | permissions = Just 384 })
        |> Task.andThen
            (\listener ->
                permissionsOf path
                    |> Task.andThen
                        (\perms ->
                            H.async
                                (H.socketErr (Socket.accept listener)
                                    |> Task.andThen
                                        (\s ->
                                            H.streamErr (H.readAll (Socket.readable s))
                                                |> Task.andThen
                                                    (\got ->
                                                        H.streamErr (H.writeAll ("pong: " ++ got) (Socket.writable s))
                                                            |> Task.map (\_ -> ( got, s ))
                                                    )
                                        )
                                )
                                |> Task.andThen
                                    (\served ->
                                        H.socketErr (Socket.Unix.connect path)
                                            |> Task.andThen
                                                (\c ->
                                                    H.send "ping over unix" c
                                                        |> Task.andThen (\reply -> served |> Task.map (\( got, s ) -> ( reply, got, ( c, s ) )))
                                                )
                                    )
                                |> Task.andThen
                                    (\( reply, got, ( c, s ) ) ->
                                        H.socketErr (Socket.closeListener listener)
                                            |> Task.andThen (\_ -> File.metadata { resolveLink = False } path |> Task.map (\_ -> "still there") |> Task.onError (\e -> Task.succeed (File.errorCode e)))
                                            |> Task.map
                                                (\after ->
                                                    [ "permissions: " ++ perms
                                                    , "server got: " ++ got
                                                    , "client got: " ++ reply
                                                    , "server local is the path: " ++ H.boolString (isPath path (Socket.localEndpoint s))
                                                    , "server remote: " ++ H.endpointToString (Socket.remoteEndpoint s)
                                                    , "client remote is the path: " ++ H.boolString (isPath path (Socket.remoteEndpoint c))
                                                    , "client local: " ++ H.endpointToString (Socket.localEndpoint c)
                                                    , "socket file after close: " ++ after
                                                    ]
                                                )
                                    )
                        )
            )


stale : Path -> Task String (List String)
stale dir =
    let
        original =
            Path.append (Path.fromPosixString "orig.sock") dir

        link =
            Path.append (Path.fromPosixString "stale.sock") dir

        regular =
            Path.append (Path.fromPosixString "regular.txt") dir
    in
    H.socketErr (listenWith original False)
        |> Task.andThen
            (\l ->
                fileErr (File.hardLink link original)
                    |> Task.andThen (\_ -> H.socketErr (Socket.closeListener l))
            )
        |> Task.andThen (\_ -> codeOf (listenWith link False))
        |> Task.andThen
            (\without ->
                codeOf (listenWith link True)
                    |> Task.andThen
                        (\with ->
                            fileErr (File.writeFile (H.bytesOf "not a socket") regular)
                                |> Task.andThen (\_ -> codeOf (listenWith regular True))
                                |> Task.map
                                    (\reg ->
                                        [ "stale without removeExisting: " ++ without
                                        , "stale with removeExisting: " ++ with
                                        , "regular file with removeExisting: " ++ reg
                                        ]
                                    )
                        )
            )


errors : Path -> Task String (List String)
errors dir =
    let
        missing =
            Path.append (Path.fromPosixString "missing.sock") dir

        long =
            Path.fromPosixString ("/tmp/" ++ String.repeat 195 "x")
    in
    H.describe (Socket.Unix.connect missing)
        |> Task.andThen
            (\m ->
                H.describe (Socket.Unix.connect long)
                    |> Task.andThen
                        (\lc ->
                            codeOf (listenWith long False)
                                |> Task.map
                                    (\ll ->
                                        [ "missing path: " ++ String.dropLeft 4 m
                                        , "long path connect: " ++ String.dropLeft 4 lc
                                        , "long path listen: " ++ ll
                                        ]
                                    )
                        )
            )


main : System.SimpleProgram ()
main =
    H.program
        (\_ ->
            fileErr (File.makeTempDirectory "eco-sock-unix")
                |> Task.andThen
                    (\dir ->
                        echo (Path.append (Path.fromPosixString "echo.sock") dir)
                            |> Task.andThen (\a -> stale dir |> Task.map (\b -> a ++ b))
                            |> Task.andThen (\ab -> errors dir |> Task.map (\c -> ab ++ c))
                            |> Task.andThen (\lines -> fileErr (File.remove { recursive = True } dir) |> Task.map (\_ -> lines))
                    )
        )
