module FileReadDirectoryTest exposing (main)

{-| FILE-NEW-1 (plans/kernel-lib-bug-fixes.md): `Eco.File.readString` and
`readBytes` of a directory. Both open the path with an `std::ifstream` (which
succeeds on a directory) and size it with `tellg`, which on a directory
returns whatever `lseek(SEEK_END)` gives: about 2^63 on ext4, an error
(EINVAL) on tmpfs/overlayfs. On ext4 readBytes fails with EFBIG
(`OtherIOError`) but readString has no cap and passes the size to
`allocByteBufferBlank`, which runs a minor and a major GC and then aborts
(largeBodyExhausted). After the fix every case is `IsADirectory`.

Directories: "/" and "/tmp" (overlayfs on the test host) and the harness
child's cwd (under the build tree; ext4 on the test host). Each result is
logged as it arrives; the ext4 readString runs last, since it aborts today.
-}

-- LINUX-ONLY: directory lseek semantics
-- CHECK: FileReadDirectoryTest: True

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task exposing (Task)


type Msg
    = Done (List String)


name : Result IOError a -> String
name r =
    case r of
        Ok _ ->
            "Ok"

        Err (IsADirectory _) ->
            "isdir"

        Err (FileNotFound _) ->
            "FileNotFound"

        Err (PermissionDenied _) ->
            "PermissionDenied"

        Err (OtherIOError e) ->
            "OtherIOError " ++ String.fromInt e.tag ++ " " ++ e.message

        Err _ ->
            "other"


probe : String -> String -> Task IOError a -> Task Never String
probe label dir task =
    task
        |> Task.map (\_ -> ())
        |> Task.map Ok
        |> Task.onError (\e -> Task.succeed (Err e))
        |> Task.map
            (\r ->
                let
                    s =
                        name r

                    _ =
                        Debug.log ("FileReadDirectoryTest " ++ label ++ " " ++ dir ++ " -> " ++ s) ()
                in
                s
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , File.getCwd
        |> Task.onError (\_ -> Task.succeed ".")
        |> Task.andThen
            (\cwd ->
                [ probe "readBytes" "/" (File.readBytes "/")
                , probe "readString" "/" (File.readString "/")
                , probe "readBytes" "/tmp" (File.readBytes "/tmp")
                , probe "readString" "/tmp" (File.readString "/tmp")
                , probe "readBytes" cwd (File.readBytes cwd)
                , probe "readString" cwd (File.readString cwd)
                ]
                    |> Task.sequence
            )
        |> Task.perform Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done results) m =
    let
        _ =
            Debug.log "FileReadDirectoryTest" (List.all ((==) "isdir") results)
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
