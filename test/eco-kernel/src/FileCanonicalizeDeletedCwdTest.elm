module FileCanonicalizeDeletedCwdTest exposing (main)

{-| ABI-04 (plans/kernel-lib-bug-fixes.md, group 09): `Eco.File.canonicalize` of a relative
path after the working directory was deleted.

The program makes `/tmp/eco-kernel-FileCanonicalizeDeletedCwdTest/gone`, moves into it with
`File.setCwd`, removes it, and canonicalizes `"rel"`. `std::filesystem::canonical("rel", ec)`
fails, and the fallback `std::filesystem::absolute("rel")` calls the throwing
`current_path()`; `getcwd` fails with ENOENT, so `filesystem_error` escapes the binding body
and the program dies in `std::terminate` (SIGABRT) instead of getting an `Err`. This case
throws with libc++ too. Each E2E test is its own process, so changing the cwd is safe.

-}

-- CHECK: deleted-cwd: "Err
-- LINUX-ONLY: needs a removable current working directory


import Eco.File as File
import Eco.IO.Error as IOError exposing (IOError)
import Platform
import Task exposing (Task)


base : String
base =
    "/tmp/eco-kernel-FileCanonicalizeDeletedCwdTest"


gone : String
gone =
    base ++ "/gone"


type Msg
    = Setup (Result IOError ())
    | Done (Result IOError String)


setup : Task IOError ()
setup =
    File.createDir True gone
        |> Task.andThen (\_ -> File.setCwd gone)
        |> Task.andThen (\_ -> File.removeDir gone)


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.attempt Setup setup )


update : Msg -> () -> ( (), Cmd Msg )
update msg m =
    case msg of
        Setup (Ok ()) ->
            ( m, Task.attempt Done (File.canonicalize "rel") )

        Setup (Err e) ->
            let
                _ =
                    Debug.log "setup failed" (IOError.toString e)
            in
            ( m, Cmd.none )

        Done r ->
            let
                _ =
                    case r of
                        Ok s ->
                            Debug.log "deleted-cwd" ("Ok " ++ s)

                        Err e ->
                            Debug.log "deleted-cwd" ("Err " ++ IOError.toString e)
            in
            ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
