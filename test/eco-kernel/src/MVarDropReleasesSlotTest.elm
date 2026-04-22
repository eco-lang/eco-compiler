module MVarDropReleasesSlotTest exposing (main)

{-| Verify `Eco.MVar.drop` removes the slot from the kernel table:
    after `drop`, a subsequent `new` returns a fresh MVar independent
    of the dropped one. The native kernel's `MVar_drop` calls
    `s_mvars.erase(id)`; a regression that forgot to erase would leave
    a stale slot and the next `new` could collide on ID.

    Semantic check: put 111 into m1, drop m1, new m2, put 222 into m2,
    take m2 → expect 222. (We deliberately do not take from m1 after
    drop — that's undefined per the kernel contract.)
-}

-- CHECK: MVarDropReleasesSlotTest: True

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


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m1 ->
                        MV.put intEnc m1 111
                            |> Task.andThen (\_ -> MV.drop m1)
                            |> Task.andThen (\_ -> MV.new)
                            |> Task.andThen
                                (\m2 ->
                                    MV.put intEnc m2 222
                                        |> Task.andThen (\_ -> MV.take intDec m2)
                                )
                    )
                |> Task.map (\v -> v == 222)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarDropReleasesSlotTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
