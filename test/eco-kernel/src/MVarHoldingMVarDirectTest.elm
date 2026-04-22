module MVarHoldingMVarDirectTest exposing (main)

{-| Put one MVar (the inner) into another MVar (the outer), take the
    inner back out, then use the inner normally. Verifies that MVar
    values themselves roundtrip through the kernel's single-slot storage
    with their identity preserved — a regression that overwrote the id
    field or double-wrapped the constructor would break the inner
    lookup.

    Sequence:

      inner ← new          (holds an Int)
      put 77 → inner
      outer ← new          (holds an MVar Int)
      put inner → outer
      inner' ← take outer
      take inner'  →  expect 77
-}

-- CHECK: MVarHoldingMVarDirectTest: True

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


{-| Dummy encoder/decoder for the outer MVar<MVar Int>. The native kernel
    ignores both — storage is the HPointer bits — but Elm needs a
    well-typed value to type-check the `put`/`take` call.
-}
mvarEnc : MV.MVar Int -> BE.Encoder
mvarEnc _ =
    BE.unsignedInt8 0


mvarDec : BD.Decoder (MV.MVar Int)
mvarDec =
    BD.succeed (MV.MVar 0)


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\inner ->
                        MV.put intEnc inner 77
                            |> Task.andThen (\_ -> MV.new)
                            |> Task.andThen
                                (\outer ->
                                    MV.put mvarEnc outer inner
                                        |> Task.andThen (\_ -> MV.take mvarDec outer)
                                )
                            |> Task.andThen (MV.take intDec)
                    )
                |> Task.map (\v -> v == 77)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingMVarDirectTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
