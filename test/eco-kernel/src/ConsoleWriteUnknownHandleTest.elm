module ConsoleWriteUnknownHandleTest exposing (main)

{-| PROC-NEW-1 (plans/kernel-lib-bug-fixes.md, group 07), the unknown-handle half: decision D28
(user, 2026-11-04) is that `Eco.Console.write` to a handle that is neither stdout, stderr nor a
live `spawnProcess` stdin handle fails with an IOError (EBADF) on both backends. Natively
`Console.write` (eco-kernel-cpp/src/eco-kernel/Console.cpp `writeBody`) returned success for any
handle other than 1 and 2 without writing anything, so the data was silently lost (fixed: EBADF).
-}

-- CHECK: unknown handle: error
-- CHECK-NOT: unknown handle: ok
-- EXIT: 0

import Eco.Console as Console
import Platform
import Task


type Msg
    = Done String


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Console.write (Console.Handle 987654) "lost\n"
                    |> Task.map (\_ -> "ok")
                    |> Task.onError (\_ -> Task.succeed "error")
                    |> Task.perform Done
                )
        , update =
            \(Done s) _ ->
                let
                    _ =
                        Debug.log ("unknown handle: " ++ s) ()
                in
                ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
