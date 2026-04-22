module MVarHoldingTaskDirectTest exposing (main)

{-| Put a `Task Never Int` value into an MVar, take it back out, and
    execute it — verifies that Task-typed values (heap-allocated with
    internal pointer chains) survive the kernel's HPointer storage
    intact. A regression that mis-decoded the stored HPointer would
    either crash when executing the taken Task or return the wrong
    value.
-}

-- CHECK: MVarHoldingTaskDirectTest: True

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


init : () -> ( Model, Cmd Msg )
init _ =
    let
        inner : Task.Task Never Int
        inner =
            Task.succeed 99

        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put taskEnc m inner
                            |> Task.andThen (\_ -> MV.take taskDec m)
                    )
                |> Task.andThen (\t -> t)
                |> Task.map (\v -> v == 99)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingTaskDirectTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
