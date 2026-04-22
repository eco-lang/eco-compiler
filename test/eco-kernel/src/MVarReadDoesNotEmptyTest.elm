module MVarReadDoesNotEmptyTest exposing (main)

{-| Verify that `Eco.MVar.read` is non-destructive: after five reads the
    slot must still be full so a subsequent `take` succeeds. The native
    kernel's `MVar_read` returns the stored HPointer without clearing
    the slot; `MVar_take` clears it. A regression where `read` behaved
    like `take` would either assert-crash on the second read (empty-take)
    or return a stale value.
-}

-- CHECK: MVarReadDoesNotEmptyTest: True

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


type alias Readings =
    { r1 : Int
    , r2 : Int
    , r3 : Int
    , r4 : Int
    , r5 : Int
    , t : Int
    }


intEnc : Int -> BE.Encoder
intEnc n =
    BE.signedInt32 BE n


intDec : BD.Decoder Int
intDec =
    BD.signedInt32 BE


readN : MV.MVar Int -> Task.Task Never Readings
readN m =
    MV.read intDec m
        |> Task.andThen
            (\r1 ->
                MV.read intDec m
                    |> Task.andThen
                        (\r2 ->
                            MV.read intDec m
                                |> Task.andThen
                                    (\r3 ->
                                        MV.read intDec m
                                            |> Task.andThen
                                                (\r4 ->
                                                    MV.read intDec m
                                                        |> Task.andThen
                                                            (\r5 ->
                                                                MV.take intDec m
                                                                    |> Task.map (\t -> { r1 = r1, r2 = r2, r3 = r3, r4 = r4, r5 = r5, t = t })
                                                            )
                                                )
                                    )
                        )
            )


init : () -> ( Model, Cmd Msg )
init _ =
    let
        payload =
            1234567

        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put intEnc m payload
                            |> Task.andThen (\_ -> readN m)
                    )
                |> Task.map
                    (\rs ->
                        rs.r1 == payload && rs.r2 == payload && rs.r3 == payload && rs.r4 == payload && rs.r5 == payload && rs.t == payload
                    )
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarReadDoesNotEmptyTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
