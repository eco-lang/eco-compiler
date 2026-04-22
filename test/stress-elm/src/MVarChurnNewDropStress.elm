module MVarChurnNewDropStress exposing (main)

{-| Tight loop of `new` + `put` + `drop` many thousand times, interleaved
    with `put`/`take` on a persistent MVar so GCs fire throughout.
    Detects leaked slot IDs, stale table entries, and drop-vs-scanner
    interaction bugs.

    At the end, the persistent MVar must still hold its expected value.
-}

-- CHECK: MVarChurnNewDropStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


churnCount : Int
churnCount =
    2000


intEnc : Int -> BE.Encoder
intEnc _ =
    BE.unsignedInt8 0


intDec : BD.Decoder Int
intDec =
    BD.succeed 0


{-| Builds a throwaway list to churn nursery memory on each churn iter. -}
smallAlloc : Task.Task Never Int
smallAlloc =
    Task.succeed (List.sum (List.range 1 100))


churn : MV.MVar Int -> Int -> Task.Task Never ()
churn persistent i =
    if i <= 0 then
        Task.succeed ()

    else
        MV.new
            |> Task.andThen
                (\m ->
                    MV.put intEnc m i
                        |> Task.andThen (\_ -> MV.drop m)
                        |> Task.andThen (\_ -> smallAlloc)
                        |> Task.andThen
                            (\_ ->
                                if modBy 16 i == 0 then
                                    MV.take intDec persistent
                                        |> Task.andThen
                                            (\v ->
                                                MV.put intEnc persistent (v + 1)
                                                    |> Task.andThen (\_ -> churn persistent (i - 1))
                                            )

                                else
                                    churn persistent (i - 1)
                            )
                )


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            MV.new
                |> Task.andThen
                    (\persistent ->
                        MV.put intEnc persistent 0
                            |> Task.andThen (\_ -> churn persistent churnCount)
                            |> Task.andThen (\_ -> MV.take intDec persistent)
                    )
                |> Task.map (\final -> final == churnCount // 16)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarChurnNewDropStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
