module ModifyMVarCounterStress exposing (main)

{-| Mimic the `modifyMVar` pattern from the compiler's `Utils.Main`:
    take the current value, produce a new one, put it back. Runs a
    counter loop N k times with per-iteration allocation pressure to
    force minor GCs during the take/put sequence.

    End state: counter == iterations.
-}

-- CHECK: ModifyMVarCounterStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


iterations : Int
iterations =
    3000


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 200))


modifyInc : MV.MVar Int -> Task.Task Never ()
modifyInc m =
    MV.take intDec m
        |> Task.andThen (\v -> MV.put intEnc m (v + 1))


loop : MV.MVar Int -> Int -> Task.Task Never ()
loop m n =
    if n <= 0 then
        Task.succeed ()

    else
        modifyInc m
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> loop m (n - 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put intEnc m 0
                            |> Task.andThen (\_ -> loop m iterations)
                            |> Task.andThen (\_ -> MV.take intDec m)
                    )
                |> Task.map (\v -> v == iterations)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "ModifyMVarCounterStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
