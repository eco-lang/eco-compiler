module MVarNewPutTakeRoundtripTest exposing (main)

{-| Basic MVar lifecycle smoke test. Exercises, in order:

      Eco.Kernel.MVar_new   (via Eco.MVar.new)
      Eco.Kernel.MVar_put   (via Eco.MVar.put)
      Eco.Kernel.MVar_take  (via Eco.MVar.take)

    Puts a boxed Int, takes it back, compares for equality. Value is
    heap-allocated (boxed Int) so the HPointer round-trips through the
    kernel's single-slot storage; the encoder/decoder parameters are
    ignored by the native kernel but still type-check the value shape.
-}

-- CHECK: MVarNewPutTakeRoundtripTest: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = Got Int


type alias Model =
    Maybe Int


intEnc : Int -> BE.Encoder
intEnc n =
    BE.signedInt32 BE n


intDec : BD.Decoder Int
intDec =
    BD.signedInt32 BE


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put intEnc m 424242
                            |> Task.andThen (\_ -> MV.take intDec m)
                    )
    in
    ( Nothing, Task.perform Got task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        Got v ->
            let
                ok =
                    v == 424242

                _ =
                    Debug.log "MVarNewPutTakeRoundtripTest" ok
            in
            ( Just v, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
