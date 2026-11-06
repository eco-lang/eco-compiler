module TaskPerformValueTest exposing (main)

{-| `Task.perform` delivers the task's value to `update` in a `Platform.worker`, for messages that carry an `Int`, a negative `Int` or a `String`, and for a message built by a function that ignores the value.

`init` batches four `Task.perform` commands on `Task.succeed`; `update` logs the
payload of each message.
-}

-- CHECK: a: 42
-- CHECK: b: "nullary ok"
-- CHECK: c: -7
-- CHECK: d: "hello"

import Platform
import Task


type Msg
    = GotInt Int
    | GotNullary
    | GotNeg Int
    | GotStr String


init : () -> ( Int, Cmd Msg )
init _ =
    ( 0
    , Cmd.batch
        [ Task.perform GotInt (Task.succeed 42)
        , Task.perform (\_ -> GotNullary) (Task.succeed 1)
        , Task.perform GotNeg (Task.succeed -7)
        , Task.perform GotStr (Task.succeed "hello")
        ]
    )


update : Msg -> Int -> ( Int, Cmd Msg )
update msg model =
    case msg of
        GotInt v ->
            let
                _ =
                    Debug.log "a" v
            in
            ( model + 1, Cmd.none )

        GotNullary ->
            let
                _ =
                    Debug.log "b" "nullary ok"
            in
            ( model + 1, Cmd.none )

        GotNeg v ->
            let
                _ =
                    Debug.log "c" v
            in
            ( model + 1, Cmd.none )

        GotStr s ->
            let
                _ =
                    Debug.log "d" s
            in
            ( model + 1, Cmd.none )


main : Program () Int Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
