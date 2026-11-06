port module CmdBatchOrderTest exposing (main)

{-| The order in which an effect manager receives the commands of a `Cmd.batch`: last first, for both a port and `Task.perform`.

`init` returns one batch holding five `echoOut` port commands (3 and 4 inside a
nested `Cmd.batch`) and three `Task.perform Ran (Task.succeed n)` commands. Elm
0.19.1 hands each manager a batch's commands in reverse order, so the tasks
report 3, 2, 1 and the port is given 5, 4, 3, 2, 1, with the nested batch
flattened into place.

The tasks' order is logged once all three `Ran` messages have arrived. The
port's order relies on the host echoing each `echoOut` value back on `echoIn` in
the order the port delivered it; the list is logged once five values have come
back.

-}

-- CHECK: CmdBatchOrderTest tasks: [3,2,1]
-- CHECK: CmdBatchOrderTest port: [5,4,3,2,1]

import Platform
import Task


port echoOut : Int -> Cmd msg


port echoIn : (Int -> msg) -> Sub msg


type Msg
    = Echoed Int
    | Ran Int


type alias Model =
    { echoed : List Int
    , ran : List Int
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { echoed = [], ran = [] }
    , Cmd.batch
        [ echoOut 1
        , echoOut 2
        , Cmd.batch [ echoOut 3, echoOut 4 ]
        , echoOut 5
        , Task.perform Ran (Task.succeed 1)
        , Task.perform Ran (Task.succeed 2)
        , Task.perform Ran (Task.succeed 3)
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Echoed n ->
            let
                echoed =
                    model.echoed ++ [ n ]

                _ =
                    if List.length echoed == 5 then
                        Debug.log "CmdBatchOrderTest port" echoed

                    else
                        echoed
            in
            ( { model | echoed = echoed }, Cmd.none )

        Ran n ->
            let
                ran =
                    model.ran ++ [ n ]

                _ =
                    if List.length ran == 3 then
                        Debug.log "CmdBatchOrderTest tasks" ran

                    else
                        ran
            in
            ( { model | ran = ran }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if List.length model.echoed >= 5 then
        Sub.none

    else
        echoIn Echoed


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
