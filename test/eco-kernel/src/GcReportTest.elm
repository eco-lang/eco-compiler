module GcReportTest exposing (main)

{-| Drive `Eco.GC` (plans/frontend-heap-release.md §4): a minor collection
then a full release must both run (`collected = 1`), report their kind, and
the release must run a major (`majorsRun >= 1`).
A decode failure would surface as `kind = "error"`.
-}

-- CHECK: GcReportTest: True

import Eco.GC as GC
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


init : () -> ( Model, Cmd Msg )
init _ =
    let
        garbage =
            List.map (\i -> String.fromInt i) (List.range 1 20000)

        task =
            GC.minorGC
                |> Task.andThen
                    (\minor ->
                        GC.majorGC
                            |> Task.map
                                (\major ->
                                    minor.kind
                                        == "minor"
                                        && minor.collected
                                        == 1
                                        && major.kind
                                        == "major"
                                        && major.collected
                                        == 1
                                        && major.majorsRun
                                        >= 1
                                        && major.rssBefore
                                        >= 0
                                )
                    )
    in
    ( Nothing, Task.perform GotResult (Task.succeed (List.length garbage) |> Task.andThen (\_ -> task)) )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "GcReportTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
