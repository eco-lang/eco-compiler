module FileStreamFailureTest exposing (main)

{-| A file stream whose file fails (plans/eco-system-typed-api.md B7): writing into a stream on
`/dev/full` fails with `ENOSPC`, which reaches the program as `Stream.Failed`, a failure of the
resource rather than a cancellation; `FileSystem.fromStreamFailure` reads it back as a
`FileSystem.Error` of kind `NoSpace`, and the other modules' `fromStreamFailure` give `Nothing`.
-}

-- CHECK: write: Failed file NoSpace
-- CHECK: errorToString starts Failed: True
-- CHECK: read back as FileSystem: Just NoSpace
-- CHECK: read back as Socket: Nothing
-- EXIT: 0

import Bytes.Encode
import ErrorNames
import FileSystem as File
import Path
import Socket
import Stream
import SocketTestHelp as H
import System
import Task exposing (Task)


main : Platform.Program System.Environment () ()
main =
    H.program
        (\_ ->
            File.writeFileStream File.Replace (Path.fromPosixString "/dev/full")
                |> Task.mapError File.errorToString
                |> Task.andThen
                    (\writable ->
                        Stream.write (Bytes.Encode.encode (Bytes.Encode.string "no room")) writable
                            |> Task.andThen (\w -> Stream.closeWritable w)
                            |> Task.map (\_ -> [ "write: ok?" ])
                            |> Task.onError (\e -> Task.succeed (describe e))
                    )
        )


describe : Stream.Error -> List String
describe e =
    [ "write: " ++ ErrorNames.streamError e
    , "errorToString starts Failed: " ++ H.boolString (String.startsWith "Failed: " (Stream.errorToString e))
    , "read back as FileSystem: "
        ++ (case e of
                Stream.Failed failure ->
                    case File.fromStreamFailure failure of
                        Just fe ->
                            "Just " ++ ErrorNames.fileError fe

                        Nothing ->
                            "Nothing"

                _ ->
                    "not Failed"
           )
    , "read back as Socket: "
        ++ (case e of
                Stream.Failed failure ->
                    case Socket.fromStreamFailure failure of
                        Just se ->
                            "Just " ++ ErrorNames.socketError se

                        Nothing ->
                            "Nothing"

                _ ->
                    "not Failed"
           )
    ]
