module ModifyMVarCounterStress exposing (main)

{-| Mimic the `modifyMVar` pattern from the compiler's `Utils.Main`:
    take the current value, produce a new one, put it back. Runs a
    counter loop N k times with per-iteration allocation pressure to
    force minor GCs during the take/put sequence.

    End state: counter == n.
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


n : Int
n =
    1000


m : Int
m =
    1000


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 m))


modifyInc : MV.MVar Int -> Task.Task Never ()
modifyInc mvar =
    MV.take intDec mvar
        |> Task.andThen (\v -> MV.put intEnc mvar (v + 1))


loop : MV.MVar Int -> Int -> Task.Task Never ()
loop mvar remaining =
    if remaining <= 0 then
        Task.succeed ()

    else
        modifyInc mvar
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> loop mvar (remaining - 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\mvar ->
                        MV.put intEnc mvar 0
                            |> Task.andThen (\_ -> loop mvar n)
                            |> Task.andThen (\_ -> MV.take intDec mvar)
                    )
                |> Task.map (\v -> v == n)
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
