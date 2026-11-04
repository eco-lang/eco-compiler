module FileFindExecutableEmptyPathTrailingTest exposing (main)

{-| FILE-10 (plans/kernel-lib-bug-fixes.md): an empty PATH entry. Decision D22:
an empty entry means `.` everywhere in PATH (POSIX; Haskell's
`splitSearchPath`), and `findExecutable` returns `./name`. The program copies
/bin/true to `ecoprobe` in a scratch directory, makes it the cwd, and looks
`ecoprobe` up with PATH=/nonexistent-eco:.

Today the split loop stops at the trailing separator, so the empty last entry is never tried: `Nothing`.
-}

-- LINUX-ONLY: POSIX PATH search
-- ENV: PATH=/nonexistent-eco:
-- CHECK: FileFindExecutableEmptyPathTrailingTest: Just "./ecoprobe"

import Eco.File as File
import Eco.Process as P
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-FileFindExecutableEmptyPathTrailingTest"


type Msg
    = Done (Result String (Maybe String))


setup : Task String ()
setup =
    File.createDir True dir
        |> Task.mapError (\_ -> "createDir failed")
        |> Task.andThen (\_ -> P.spawn "/bin/cp" [ "/bin/true", dir ++ "/ecoprobe" ] |> Task.mapError (\_ -> "spawn cp failed"))
        |> Task.andThen (\h -> P.wait h |> Task.mapError never)
        |> Task.andThen
            (\code ->
                if code == P.ExitSuccess then
                    File.setCwd dir |> Task.mapError (\_ -> "setCwd failed")

                else
                    Task.fail "cp failed"
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , setup
        |> Task.andThen (\_ -> File.findExecutable "ecoprobe" |> Task.mapError never)
        |> Task.attempt Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done r) m =
    let
        _ =
            case r of
                Ok found ->
                    Debug.log "FileFindExecutableEmptyPathTrailingTest" found

                Err e ->
                    Debug.log ("FileFindExecutableEmptyPathTrailingTest setup error: " ++ e) Nothing
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
