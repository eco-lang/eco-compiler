module HarnessExitZeroTest exposing (main)

{-| Harness self-test (plans/eco-system-library.md Phase 1 step 8b/c): in this
suite CHECK patterns are verified by the parent after the child exits, and the
`-- EXIT:` directive is enforced. A Platform.worker that goes quiescent ends
normally with exit code 0 (eco_get_exit_code() is 0 unless set). The output is
produced from `update`, after a Task round trip, so it is only seen if the
eco-thread output is captured up to the program's end.

Non-zero EXIT, fd-output CHECK and STDIN self-tests need eco/system APIs
(exitWithCode, Stream stdout/stdin); they arrive with Phase 3.

-}

-- CHECK: harness: "done"
-- CHECK-NOT: harness: "never"
-- EXIT: 0

import Platform
import Task


type Msg
    = Done


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.perform (\_ -> Done) (Task.succeed ()) )


update : Msg -> () -> ( (), Cmd Msg )
update Done m =
    let
        _ =
            Debug.log "harness" "done"
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
