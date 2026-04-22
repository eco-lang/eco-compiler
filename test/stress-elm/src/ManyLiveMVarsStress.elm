module ManyLiveMVarsStress exposing (main)

{-| Create a large number of MVars each holding a distinct `Int`, force
    several GCs, then take from every one and verify the values match
    their expected keys. Stresses the scanner iterating the full
    `s_mvars` hashmap on every collection.
-}

-- CHECK: ManyLiveMVarsStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


count : Int
count =
    500


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


{-| Make `n` MVars each pre-filled with its index `i` in [1..n]. Returns
    the list of MVars in index order. -}
makeAll : Int -> Task.Task Never (List (MV.MVar Int))
makeAll n =
    let
        go : Int -> List (MV.MVar Int) -> Task.Task Never (List (MV.MVar Int))
        go i acc =
            if i > n then
                Task.succeed (List.reverse acc)

            else
                MV.new
                    |> Task.andThen
                        (\m ->
                            MV.put intEnc m i
                                |> Task.andThen (\_ -> go (i + 1) (m :: acc))
                        )
    in
    go 1 []


takeAll : List (MV.MVar Int) -> Task.Task Never (List Int)
takeAll mvars =
    let
        go : List (MV.MVar Int) -> List Int -> Task.Task Never (List Int)
        go ms acc =
            case ms of
                [] ->
                    Task.succeed (List.reverse acc)

                m :: rest ->
                    MV.take intDec m
                        |> Task.andThen (\v -> go rest (v :: acc))
    in
    go mvars []


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            makeAll count
                |> Task.andThen
                    (\mvars ->
                        heavyAlloc
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> takeAll mvars)
                    )
                |> Task.map (\vs -> vs == List.range 1 count)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "ManyLiveMVarsStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
