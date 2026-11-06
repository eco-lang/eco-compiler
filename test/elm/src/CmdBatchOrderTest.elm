port module CmdBatchOrderTest exposing (main)

{-| The order in which one effect manager receives the commands of a `Cmd.batch`.

Elm 0.19.1 gathers each manager's commands by consing onto a list, so a manager gets a batch's
commands in reverse order: the port `echoOut` is handed `Cmd.batch [ echoOut 1, echoOut 2,
Cmd.batch [ echoOut 3, echoOut 4 ], echoOut 5 ]` as 5, 4, 3, 2, 1, and the Task manager runs a
batch of `Task.perform`s last first. Eco's native port and Task managers handled the commands first
first instead, delivering 1 to 5, until 2026-11-06 (PORT_005).

Found 2026-11-06 by the JS-versus-Node-addon parity host (test/embed/embed_host.js). The harness
echo feeds each `echoOut` payload back through `echoIn`, in the order the port delivered it.
Expected output recorded from Elm 0.19.1 on node.

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
