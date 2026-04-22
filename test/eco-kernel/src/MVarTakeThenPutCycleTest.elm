module MVarTakeThenPutCycleTest exposing (main)

{-| Three take/put cycles on a single MVar with distinct values:

      put 10 → take (expect 10) → put 20 → take (expect 20) → put 30 → take (expect 30)

    Exercises the invariant that `take` empties the slot so a subsequent
    `put` into the same MVar succeeds (a `put` on a full slot assert-crashes
    in the native kernel). Also verifies each take returns the immediately
    preceding put value, i.e. no stale-state leakage.
-}

-- CHECK: MVarTakeThenPutCycleTest: True

import Bytes exposing (Endianness(..))
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
intEnc n =
    BE.signedInt32 BE n


intDec : BD.Decoder Int
intDec =
    BD.signedInt32 BE


cycle : MV.MVar Int -> Int -> Task.Task Never Int
cycle m v =
    MV.put intEnc m v
        |> Task.andThen (\_ -> MV.take intDec m)


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        cycle m 10
                            |> Task.andThen
                                (\v1 ->
                                    cycle m 20
                                        |> Task.andThen
                                            (\v2 ->
                                                cycle m 30
                                                    |> Task.map (\v3 -> ( v1, v2, v3 ))
                                            )
                                )
                    )
                |> Task.map (\( v1, v2, v3 ) -> v1 == 10 && v2 == 20 && v3 == 30)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarTakeThenPutCycleTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
