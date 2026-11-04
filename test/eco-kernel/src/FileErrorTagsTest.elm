module FileErrorTagsTest exposing (main)

{-| FILE-12 (plans/kernel-lib-bug-fixes.md): the `Eco.File` kernels that use
`std::filesystem` (K/File.cpp `listBody`, `setCwdBody`, `createDir`, ...)
report their failures with the right `Eco.IO.Error` kind.

Those kernels pass `std::error_code::value()` to the errno-based tag mapping.
On POSIX the value is an errno, so the kinds below are right and this test
passes: on Linux it is a regression guard. On Windows the value is a Win32
code (ERROR_PATH_NOT_FOUND = 3, ERROR_DIRECTORY = 267, ERROR_ALREADY_EXISTS =
183), which the errno mapping does not know, so every one of these is
`OtherIOError` there today. Windows is low priority (user rule) and no XFAIL
can be scoped to it, so the test carries none: it fails only on a Windows
build until the fix lands.

-}

-- CHECK: list missing: FileNotFound
-- CHECK: list file: NotADirectory
-- CHECK: createDir over file: AlreadyExists
-- CHECK: setCwd missing: FileNotFound
-- CHECK: FileErrorTagsTest done

import Eco.File as File
import Eco.IO.Error exposing (IOError(..))
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileErrorTagsTest"


kind : IOError -> String
kind err =
    case err of
        FileNotFound _ ->
            "FileNotFound"

        PermissionDenied _ ->
            "PermissionDenied"

        NotADirectory _ ->
            "NotADirectory"

        IsADirectory _ ->
            "IsADirectory"

        AlreadyExists _ ->
            "AlreadyExists"

        NoSpaceLeft _ ->
            "NoSpaceLeft"

        TooManyOpenFiles ->
            "TooManyOpenFiles"

        BrokenPipe _ ->
            "BrokenPipe"

        BadFileDescriptor ->
            "BadFileDescriptor"

        OtherIOError o ->
            "OtherIOError " ++ String.fromInt o.tag ++ " " ++ o.message


{-| `<label>: <error kind>`, or `<label>: no error`.
-}
outcome : String -> Task IOError a -> Task Never String
outcome label task =
    task
        |> Task.map (\_ -> label ++ ": no error")
        |> Task.onError (\e -> Task.succeed (label ++ ": " ++ kind e))


checks : Task Never (List String)
checks =
    let
        file =
            dir ++ "/regular.txt"
    in
    File.createDir True dir
        |> Task.andThen (\_ -> File.writeString file "x")
        |> Task.map (\_ -> [])
        |> Task.onError (\e -> Task.succeed [ "setup failed: " ++ kind e ])
        |> Task.andThen
            (\setup ->
                Task.sequence
                    [ outcome "list missing" (File.list (dir ++ "/missing-parent/missing"))
                    , outcome "list file" (File.list file)
                    , outcome "createDir over file" (File.createDir False file)
                    , outcome "setCwd missing" (File.setCwd (dir ++ "/missing"))
                    ]
                    |> Task.map (\lines -> setup ++ lines)
            )
        |> Task.andThen
            (\lines ->
                File.removeFile file
                    |> Task.andThen (\_ -> File.removeDir dir)
                    |> Task.onError (\_ -> Task.succeed ())
                    |> Task.map (\_ -> lines)
            )


type Msg
    = Done (List String)


update : Msg -> () -> ( (), Cmd Msg )
update (Done lines) m =
    let
        _ =
            List.map (\l -> Debug.log l ()) lines

        _ =
            Debug.log "FileErrorTagsTest done" ()
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Done checks )
        , update = update
        , subscriptions = \_ -> Sub.none
        }
