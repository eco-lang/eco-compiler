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


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 100


taskEnc : Task.Task Never Int -> BE.Encoder
taskEnc _ =
    BE.unsignedInt8 0


taskDec : BD.Decoder (Task.Task Never Int)
taskDec =
    BD.succeed (Task.succeed 0)


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


singleCycle : Task.Task Never Bool
singleCycle =
    let
        inner : Task.Task Never Int
        inner =
            Task.succeed 777
                |> Task.andThen (\v -> Task.succeed (v + 23))
    in
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put taskEnc mv inner
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take taskDec mv)
            )
        |> Task.andThen (\t -> t)
        |> Task.map (\v -> v == 800)


repeatCycle : Int -> Task.Task Never Bool
repeatCycle remaining =
    if remaining <= 0 then
        Task.succeed True

    else
        singleCycle
            |> Task.andThen
                (\ok ->
                    if ok then
                        repeatCycle (remaining - 1)

                    else
                        Task.succeed False
                )


init : () -> ( Model, Cmd Msg )
init _ =
    ( Nothing, Task.perform GotResult (repeatCycle loopCount) )


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
