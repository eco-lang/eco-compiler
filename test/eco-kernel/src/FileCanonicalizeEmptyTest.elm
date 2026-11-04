module FileCanonicalizeEmptyTest exposing (main)

{-| ABI-04 (plans/kernel-lib-bug-fixes.md, group 09): `Eco.File.canonicalize ""`.

`canonicalizeBody` (eco-kernel-cpp/src/eco-kernel/File.cpp) tries
`std::filesystem::canonical(path, ec)` and, when that fails, falls back to the THROWING
overload `std::filesystem::absolute(path)`. With libstdc++, `absolute("")` throws
`filesystem_error` ("cannot make absolute path"), which escapes the binding body: the program
dies in `std::terminate` (SIGABRT) instead of getting an `Err`. Decision D2: `canonicalize ""`
fails with an IOError.

-}

-- CHECK: empty: "Err


import Eco.File as File
import Eco.IO.Error as IOError exposing (IOError)
import Platform
import Task


type Msg
    = Done (Result IOError String)


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.attempt Done (File.canonicalize "") )


update : Msg -> () -> ( (), Cmd Msg )
update (Done r) m =
    let
        _ =
            case r of
                Ok s ->
                    Debug.log "empty" ("Ok " ++ s)

                Err e ->
                    Debug.log "empty" ("Err " ++ IOError.toString e)
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
