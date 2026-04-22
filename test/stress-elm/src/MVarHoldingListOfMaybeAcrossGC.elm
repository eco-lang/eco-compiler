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
    Task.succeed (List.sum (List.range 1 8000))


valEnc : List (Maybe Item) -> BE.Encoder
valEnc _ =
    BE.unsignedInt8 0


valDec : BD.Decoder (List (Maybe Item))
valDec =
    BD.succeed []


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put valEnc m original
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> MV.take valDec m)
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
