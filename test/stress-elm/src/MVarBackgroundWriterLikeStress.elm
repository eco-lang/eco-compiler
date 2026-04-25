module MVarBackgroundWriterLikeStress exposing (main)

{-| Reproduces `Builder.BackgroundWriter`'s `addMVarToWorkList` /
    `waitForAllWork` shape:

      workList : MVar (List (MVar ()))

    The loop creates a new inner MVar, takes the outer list, prepends
    the new MVar, puts the list back — the closest in-process match to
    the Stage 7 crash site. At the end we verify the list length
    matches the iteration count.

    This is the highest-value stress for reproducing the Stage 7 bug.
-}

-- CHECK: MVarBackgroundWriterLikeStress: True

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


unitEnc : () -> BE.Encoder
unitEnc _ =
    BE.unsignedInt8 0


unitDec : BD.Decoder ()
unitDec =
    BD.succeed ()


listEnc : List (MV.MVar ()) -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List (MV.MVar ()))
listDec =
    BD.succeed []


smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 m))


addOne : MV.MVar (List (MV.MVar ())) -> Task.Task Never ()
addOne workList =
    MV.new
        |> Task.andThen
            (\inner ->
                MV.take listDec workList
                    |> Task.andThen
                        (\xs -> MV.put listEnc workList (inner :: xs))
            )


loop : MV.MVar (List (MV.MVar ())) -> Int -> Task.Task Never ()
loop workList remaining =
    if remaining <= 0 then
        Task.succeed ()

    else
        addOne workList
            |> Task.andThen (\_ -> smallAlloc)
            |> Task.andThen (\_ -> loop workList (remaining - 1))


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\workList ->
                        MV.put listEnc workList []
                            |> Task.andThen (\_ -> loop workList n)
                            |> Task.andThen (\_ -> MV.take listDec workList)
                    )
                |> Task.map (\xs -> List.length xs == n)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarBackgroundWriterLikeStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
