module TaskAttemptErrorTest exposing (main)

{-| `Task.attempt` delivers both outcomes to `update` in a `Platform.worker`: `Ok` with the value of a succeeding task and `Err` with the error of a failing one.

`init` batches `Task.attempt Got (Task.succeed 42)` and
`Task.attempt Got (Task.fail "boom")`; `update` logs the value of each `Ok` and
`Err` it receives.
-}

-- CHECK: ok: 42
-- CHECK: err: "boom"

import Platform
import Task


type Msg
    = Got (Result String Int)


init : () -> ( Int, Cmd Msg )
init _ =
    ( 0
    , Cmd.batch
        [ Task.attempt Got (Task.succeed 42)
        , Task.attempt Got (Task.fail "boom")
        ]
    )


update : Msg -> Int -> ( Int, Cmd Msg )
update msg model =
    case msg of
        Got (Ok v) ->
            let
                _ =
                    Debug.log "ok" v
            in
            ( model + 1, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "err" e
            in
            ( model + 1, Cmd.none )


main : Program () Int Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
