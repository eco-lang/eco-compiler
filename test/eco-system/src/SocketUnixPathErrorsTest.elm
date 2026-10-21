module SocketUnixPathErrorsTest exposing (main)

{-| A Unix domain socket's address is a file-system path, so `Socket.Unix.connect` and `listen`
fail as a file operation on that path would (plans/eco-system-typed-api.md S2): the failure is
`AddressPathFailed` with the `FileSystem.ErrorKind`, while a path that exists but has no listener
is the socket-level `ConnectionRefused`, and an occupied path for `listen` is `AddressInUse`.

  - connect to a path with nothing at it: `AddressPathFailed NoSuchFileOrDirectory`;
  - listen in a directory that does not exist: `AddressPathFailed NoSuchFileOrDirectory`;
  - listen under a path component that is a regular file: `AddressPathFailed NotADirectory`;
  - connect to a regular file: `ConnectionRefused`;
  - listen at a regular file: `AddressInUse`.

-}

-- CHECK: connect missing: err AddressPathFailed NoSuchFileOrDirectory
-- CHECK: listen in missing directory: err AddressPathFailed NoSuchFileOrDirectory
-- CHECK: listen under a file: err AddressPathFailed NotADirectory
-- CHECK: connect to a file: err ConnectionRefused
-- CHECK: listen at a file: err AddressInUse
-- EXIT: 0

import Bytes.Encode
import FileSystem as File
import Path exposing (Path)
import Socket
import Socket.Unix
import SocketTestHelp as H
import System
import Task exposing (Task)


under : Path -> String -> Path
under dir name =
    Path.append (Path.fromPosixString name) dir


listen : Path -> Task Socket.Error Socket.Listener
listen path =
    Socket.Unix.listen (Socket.Unix.defaultListenOptions path)


labelled : String -> Task x String -> Task x String
labelled label task =
    task |> Task.map (\r -> label ++ ": " ++ r)


cases : Path -> Path -> Task x (List String)
cases dir file =
    Task.sequence
        [ labelled "connect missing" (H.describe (Socket.Unix.connect (under dir "missing.sock")))
        , labelled "listen in missing directory" (H.describe (listen (under dir "no-such-dir/x.sock")))
        , labelled "listen under a file" (H.describe (listen (Path.append (Path.fromPosixString "x.sock") file)))
        , labelled "connect to a file" (H.describe (Socket.Unix.connect file))
        , labelled "listen at a file" (H.describe (listen file))
        ]


main : Platform.Program System.Environment () ()
main =
    H.program
        (\_ ->
            File.makeTempDirectory "eco-sock-path"
                |> Task.andThen
                    (\dir ->
                        let
                            file =
                                under dir "plain-file"
                        in
                        File.writeFile (Bytes.Encode.encode (Bytes.Encode.string "x")) file
                            |> Task.andThen (\_ -> cases dir file)
                            |> Task.andThen
                                (\lines ->
                                    File.remove { recursive = True } dir
                                        |> Task.map (\_ -> lines)
                                )
                    )
                |> Task.mapError File.errorToString
        )
