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


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 100


original : String
original =
    String.repeat (m // 2) "The quick brown fox jumps over the lazy dog. "


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


sEnc : String -> BE.Encoder
sEnc _ =
    BE.unsignedInt8 0


sDec : BD.Decoder String
sDec =
    BD.succeed ""


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put sEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take sDec mv)
            )
        |> Task.map (\v -> v == original)


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
