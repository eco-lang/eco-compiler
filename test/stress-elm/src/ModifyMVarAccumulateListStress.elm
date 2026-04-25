module ModifyMVarAccumulateListStress exposing (main)

{-| Same take/put shape as `ModifyMVarCounterStress`, but the payload
    is a growing `List String`: each iteration takes the list out,
    prepends a freshly-allocated String, and puts it back. The stored
    graph expands linearly, so the scanner's re-encode/evacuate cost
    climbs across GCs.

    End state: list length == n, head is the last-pushed value.
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


n : Int
n =
    1000


m : Int
m =
    1000


listEnc : List String -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List String)
listDec =
    BD.succeed []


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 m))


prependOne : MV.MVar (List String) -> Int -> Task.Task Never ()
prependOne mvar i =
    MV.take listDec mvar
        |> Task.andThen
            (\xs ->
                let
                    s =
                        "v" ++ String.fromInt i
                in
                MV.put listEnc mvar (s :: xs)
            )


loop : MV.MVar (List String) -> Int -> Task.Task Never ()
loop mvar i =
    if i > n then
        Task.succeed ()

    else
        prependOne mvar i
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> loop mvar (i + 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\mvar ->
                        MV.put listEnc mvar []
                            |> Task.andThen (\_ -> loop mvar 1)
                            |> Task.andThen (\_ -> MV.take listDec mvar)
                    )
                |> Task.map
                    (\xs ->
                        List.length xs == n && List.head xs == Just ("v" ++ String.fromInt n)
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
