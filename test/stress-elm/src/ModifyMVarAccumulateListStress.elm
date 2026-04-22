module ModifyMVarAccumulateListStress exposing (main)

{-| Same take/put shape as `ModifyMVarCounterStress`, but the payload
    is a growing `List String`: each iteration takes the list out,
    prepends a freshly-allocated String, and puts it back. The stored
    graph expands linearly, so the scanner's re-encode/evacuate cost
    climbs across GCs.

    End state: list length == iterations, head is the last-pushed value.
-}

-- CHECK: ModifyMVarAccumulateListStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


iterations : Int
iterations =
    1500


listEnc : List String -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List String)
listDec =
    BD.succeed []


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 200))


prependOne : MV.MVar (List String) -> Int -> Task.Task Never ()
prependOne m i =
    MV.take listDec m
        |> Task.andThen
            (\xs ->
                let
                    s =
                        "v" ++ String.fromInt i
                in
                MV.put listEnc m (s :: xs)
            )


loop : MV.MVar (List String) -> Int -> Task.Task Never ()
loop m i =
    if i > iterations then
        Task.succeed ()

    else
        prependOne m i
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> loop m (i + 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put listEnc m []
                            |> Task.andThen (\_ -> loop m 1)
                            |> Task.andThen (\_ -> MV.take listDec m)
                    )
                |> Task.map
                    (\xs ->
                        List.length xs == iterations && List.head xs == Just ("v" ++ String.fromInt iterations)
                    )
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "ModifyMVarAccumulateListStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
