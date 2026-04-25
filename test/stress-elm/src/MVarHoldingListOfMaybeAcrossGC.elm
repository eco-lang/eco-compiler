module MVarHoldingListOfMaybeAcrossGC exposing (main)

{-| Put a `List (Maybe Record)` — interleaved embedded-constant `Nothing`s
    and heap-allocated `Just` records — into an MVar, force several
    minor GCs, then take it back. Heterogeneous pointer-vs-constant slot
    values flow through the scanner's encode→evacuate→decode path on
    every collection.
-}

-- CHECK: MVarHoldingListOfMaybeAcrossGC: True

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


type alias Item =
    { tag : Int, label : String }


original : List (Maybe Item)
original =
    [ Just { tag = 1, label = "a" }
    , Nothing
    , Just { tag = 2, label = "b" }
    , Nothing
    , Nothing
    , Just { tag = 3, label = "c" }
    , Just { tag = 4, label = "d" }
    , Nothing
    ]


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


valEnc : List (Maybe Item) -> BE.Encoder
valEnc _ =
    BE.unsignedInt8 0


valDec : BD.Decoder (List (Maybe Item))
valDec =
    BD.succeed []


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put valEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take valDec mv)
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
                    Debug.log "MVarHoldingListOfMaybeAcrossGC" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
