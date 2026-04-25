module MVarHoldingHugeListAcrossGC exposing (main)

{-| Put a 20 000-element `List Int` into an MVar, force several minor
    GCs, take it back. Stresses Cons-spine evacuation rooted from an
    MVar: every Cons cell must be copied through the scanner on every
    collection.
-}

-- CHECK: MVarHoldingHugeListAcrossGC: True

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


listLen : Int
listLen =
    m * 20


original : List Int
original =
    List.range 1 listLen


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


lEnc : List Int -> BE.Encoder
lEnc _ =
    BE.unsignedInt8 0


lDec : BD.Decoder (List Int)
lDec =
    BD.succeed []


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put lEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take lDec mv)
            )
        |> Task.map
            (\v ->
                List.length v == listLen && List.sum v == List.sum original
            )


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
                    Debug.log "MVarHoldingHugeListAcrossGC" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
