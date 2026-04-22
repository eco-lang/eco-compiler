module MVarHoldingMVarStress exposing (main)

{-| Put an inner MVar (itself holding an Int) into an outer MVar,
    force multiple minor GCs, retrieve the inner across the collection,
    then use the inner's value. Verifies MVars-as-values keep their id
    identity across scanner roundtrips.
-}

-- CHECK: MVarHoldingMVarStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


mvarEnc : MV.MVar Int -> BE.Encoder
mvarEnc _ =
    BE.unsignedInt8 0


mvarDec : BD.Decoder (MV.MVar Int)
mvarDec =
    BD.succeed (MV.MVar 0)


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\inner ->
                        MV.put intEnc inner 424242
                            |> Task.andThen (\_ -> MV.new)
                            |> Task.andThen
                                (\outer ->
                                    MV.put mvarEnc outer inner
                                        |> Task.andThen (\_ -> heavyAlloc)
                                        |> Task.andThen (\_ -> heavyAlloc)
                                        |> Task.andThen (\_ -> heavyAlloc)
                                        |> Task.andThen (\_ -> MV.take mvarDec outer)
                                )
                            |> Task.andThen (MV.take intDec)
                    )
                |> Task.map (\v -> v == 424242)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingMVarStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
