module TaskAndThenPapCapture exposing (main)

{-| A Task-based analogue of BytesRoundtripAndThenChain: a six-deep
andThen chain where every callback captures *all* previously bound
values before the next bind. Repeated 500 times, each run allocating
a fresh pap extension for each level.

Stresses eco_pap_extend closure growth across scheduler yields. Each
level yields via Process.sleep 0 so the scheduler must re-enter the
fiber with the growing capture chain live on its stack-frame list.
-}

-- CHECK: papCapture: 41000

import Platform
import Process
import Task exposing (Task)


type Msg
    = Done Int


type alias Model =
    {}


n : Int
n =
    1000


m : Int
m =
    1000


{-| Six-deep andThen chain where each callback captures every value
decoded so far before producing the next.
-}
sixLevel : Int -> Task Never Int
sixLevel base =
    Process.sleep 0
        |> Task.andThen
            (\_ ->
                let
                    a =
                        base + 1
                in
                Process.sleep 0
                    |> Task.andThen
                        (\_ ->
                            let
                                b =
                                    a + 2
                            in
                            Process.sleep 0
                                |> Task.andThen
                                    (\_ ->
                                        let
                                            c =
                                                b + 3
                                        in
                                        Process.sleep 0
                                            |> Task.andThen
                                                (\_ ->
                                                    let
                                                        d =
                                                            c + 4
                                                    in
                                                    Process.sleep 0
                                                        |> Task.andThen
                                                            (\_ ->
                                                                let
                                                                    e =
                                                                        d + 5
                                                                in
                                                                Process.sleep 0
                                                                    |> Task.map
                                                                        (\_ -> a + b + c + d + e + 6)
                                                            )
                                                )
                                    )
                        )
            )


runAll : Task Never Int
runAll =
    let
        go i acc =
            if i <= 0 then
                Task.succeed acc

            else
                sixLevel 0 |> Task.andThen (\v -> go (i - 1) (acc + v))
    in
    go m 0


init : () -> ( Model, Cmd Msg )
init _ =
    ( {}
    , runAll |> Task.perform Done
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Done v) model =
    let
        _ =
            Debug.log "papCapture" v
    in
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
