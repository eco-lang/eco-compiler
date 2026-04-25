module MVarHoldingNestedRecordAcrossGC exposing (main)

{-| Put a deeply-nested record into an MVar, force several minor GCs,
    then take it back. Every internal pointer in the record graph must
    be updated correctly by the MVar GC-root scanner across each
    evacuation cycle.
-}

-- CHECK: MVarHoldingNestedRecordAcrossGC: True

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


type alias Inner =
    { name : String, values : List Int }


type alias Nested =
    { id : Int, label : String, children : List Inner }


original : Nested
original =
    { id = 42
    , label = "nested-record"
    , children =
        [ { name = "alpha", values = [ 1, 2, 3, 4, 5 ] }
        , { name = "beta", values = [ 10, 20, 30 ] }
        , { name = "gamma", values = [ 100, 200, 300, 400 ] }
        ]
    }


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


recEnc : Nested -> BE.Encoder
recEnc _ =
    BE.unsignedInt8 0


recDec : BD.Decoder Nested
recDec =
    BD.succeed { id = 0, label = "", children = [] }


singleCycle : Task.Task Never Bool
singleCycle =
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put recEnc mv original
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take recDec mv)
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
                    Debug.log "MVarHoldingNestedRecordAcrossGC" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
