module MVarHoldingLargeStringAcrossGC exposing (main)

{-| Put a multi-KB String into an MVar, force several minor GCs, take
    back and compare. Focused on `Tag_String` evacuation via the MVar
    scanner — the exact tag last-scanned in the Stage 7 crash dump.
-}

-- CHECK: MVarHoldingLargeStringAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


original : String
original =
    String.repeat 500 "The quick brown fox jumps over the lazy dog. "


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


sEnc : String -> BE.Encoder
sEnc _ =
    BE.unsignedInt8 0


sDec : BD.Decoder String
sDec =
    BD.succeed ""


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put sEnc m original
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> MV.take sDec m)
                    )
                |> Task.map (\v -> v == original)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingLargeStringAcrossGC" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
