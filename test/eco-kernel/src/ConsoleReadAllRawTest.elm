module ConsoleReadAllRawTest exposing (main)

{-| CONSOLE-01 (plans/kernel-lib-bug-fixes.md): `Eco.Console.readAll` must return stdin
byte-exact. The native kernel (`readAllBody`, eco-kernel-cpp/src/eco-kernel/Console.cpp) joins
`std::getline` lines with '\n' and skips the separator while the result is still empty, so it
dropped every leading empty line and the final newline: for the input "\n\na\n\nb\n\n" it returned
"a\n\nb\n" (length 5) instead of the 8 characters fed in. Fixed: the stdin reader returns the
raw bytes. The XHR/JS backend returns stdin
unchanged; the expected lines follow from the input.
-}

-- STDIN: \n\na\n\nb\n\n
-- EXIT: 0
-- CHECK: len: 8
-- CHECK: lines: ["","","a","","b","",""]

import Eco.Console
import Platform
import Task


type Msg
    = Done (Result String String)


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , Eco.Console.readAll
        |> Task.mapError (\_ -> "readAll failed")
        |> Task.attempt Done
    )


update : Msg -> () -> ( (), Cmd Msg )
update (Done result) _ =
    case result of
        Ok s ->
            let
                _ =
                    Debug.log "len" (String.length s)

                _ =
                    Debug.log "lines" (String.split "\n" s)
            in
            ( (), Cmd.none )

        Err e ->
            let
                _ =
                    Debug.log "error" e
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
