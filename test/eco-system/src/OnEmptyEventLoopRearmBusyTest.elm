module OnEmptyEventLoopRearmBusyTest exposing (main)

{-| `System.rearmEmptyEventLoop` with no other work (plans/program-liveness-rule.md
§7.2, §11.1): the event loop is empty again at once, so the message arrives again
at once. The handler rearms while fewer than five deliveries have happened, so the
message arrives exactly five times and the program then ends.
-}

-- CHECK: fired: 5
-- CHECK-NOT: fired: 6
-- EXIT: 0

import System


type Msg
    = Empty


main : Platform.Program System.Environment Int Msg
main =
    Platform.worker
        { init = \_ -> ( 0, Cmd.none )
        , update =
            \Empty n ->
                let
                    _ =
                        Debug.log "fired" (n + 1)
                in
                ( n + 1
                , if n + 1 < 5 then
                    System.rearmEmptyEventLoop

                  else
                    Cmd.none
                )
        , subscriptions = \_ -> System.onEmptyEventLoop Empty
        }
