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


listLen : Int
listLen =
    20000


original : List Int
original =
    List.range 1 listLen


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


lEnc : List Int -> BE.Encoder
lEnc _ =
    BE.unsignedInt8 0


lDec : BD.Decoder (List Int)
lDec =
    BD.succeed []


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put lEnc m original
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> MV.take lDec m)
                    )
                |> Task.map
                    (\v ->
                        List.length v == listLen && List.sum v == List.sum original
                    )
    in
    ( Nothing, Task.perform GotResult task )


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
