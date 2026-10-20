module OnEmptyEventLoopLogTest exposing (main)

{-| A handler that logs on every delivery is delivered once: the IO it starts does not arm the
hook again, so the program ends after the log line. A loop would be killed by the watchdog.
(plans/program-liveness-rule.md §11.1, L-REARM.)
-}

-- CHECK: fired: 1
-- CHECK: logged 1
-- CHECK-NOT: fired: 2
-- EXIT: 0

import LiveTestHelp as L
import System


type Msg
    = Empty
    | Logged


main : Platform.Program System.Environment ( System.Environment, Int ) Msg
main =
    Platform.worker
        { init = \env -> ( ( env, 0 ), Cmd.none )
        , update =
            \msg ( env, n ) ->
                case msg of
                    Empty ->
                        let
                            _ =
                                Debug.log "fired" (n + 1)
                        in
                        ( ( env, n + 1 ), L.log env Logged ("logged " ++ String.fromInt (n + 1)) )

                    Logged ->
                        ( ( env, n ), Cmd.none )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
