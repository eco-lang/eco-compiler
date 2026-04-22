module MVarHoldingTaskValueStress exposing (main)

{-| Put a `Task Never Int` value (a heap object with internal pointer
    chains) into an MVar, force multiple minor GCs, take the task back,
    then execute it. Stresses Task-tag evacuation via the MVar
    scanner — Tasks are frequently in flight during compiler execution.
-}

-- CHECK: MVarHoldingTaskValueStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


taskEnc : Task.Task Never Int -> BE.Encoder
taskEnc _ =
    BE.unsignedInt8 0


taskDec : BD.Decoder (Task.Task Never Int)
taskDec =
    BD.succeed (Task.succeed 0)


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        inner : Task.Task Never Int
        inner =
            Task.succeed 777
                |> Task.andThen (\v -> Task.succeed (v + 23))

        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put taskEnc m inner
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> MV.take taskDec m)
                    )
                |> Task.andThen (\t -> t)
                |> Task.map (\v -> v == 800)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingTaskValueStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
