module MVarBlockingReadAwaitsPutStress exposing (main)

{-| Exercise a genuinely blocking `MVar.read`:

    1. Create an empty data MVar and an empty result MVar.
    2. Spawn a reader fiber that calls `MV.read` on the
       empty data MVar. The reader MUST block here because
       the MVar is empty at the point it runs.
    3. The parent sleeps 100 ms — long enough for the reader
       fiber to be scheduled, reach the read, and park.
    4. The parent puts the expected value into the data MVar.
    5. The reader wakes, copies the value into the result MVar.
    6. The parent takes the result MVar and compares.

    Without working blocking reads the reader's `MV.read`
    hits an empty MVar and aborts.
-}

-- CHECK: MVarBlockingReadAwaitsPutStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Process
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


expected : Int
expected =
    m * 4 + 242


{-| The kernel MVar store ignores these encoders/decoders —
    values round-trip via the hidden HPointer slot. Stubs suffice.
-}
intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


reader : MV.MVar Int -> MV.MVar Int -> Task.Task Never ()
reader dataMVar resultMVar =
    MV.read intDec dataMVar
        |> Task.andThen (\v -> MV.put intEnc resultMVar v)


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\dataMVar ->
                MV.new
                    |> Task.andThen
                        (\resultMVar ->
                            Process.spawn (reader dataMVar resultMVar)
                                |> Task.andThen (\_ -> Process.sleep 100)
                                |> Task.andThen (\_ -> MV.put intEnc dataMVar expected)
                                |> Task.andThen (\_ -> MV.take intDec resultMVar)
                        )
            )
        |> Task.map (\v -> v == expected)


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
                    Debug.log "MVarBlockingReadAwaitsPutStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
