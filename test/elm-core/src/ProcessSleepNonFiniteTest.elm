module ProcessSleepNonFiniteTest exposing (main)

{-| TIME-08 (c) (plans/kernel-lib-bug-fixes.md): `Process.sleep` with a non-finite or huge delay.
On Elm/node `setTimeout` turns any delay outside [1, 2^31-1] (Infinity, NaN, 1e300) into 1 ms, with
a TimeoutOverflowWarning, so each of these sleeps ends long before a 2000 ms reference sleep
(decision D30: eco sanitises NaN, +-inf and huge sleeps to 1 ms, and keeps `sleep 0` a yield).

Natively the delay goes straight to TimerService::schedule, whose `duration_cast` of a non-finite
or huge double is undefined behaviour; on x86 it happens to yield "fire at once", so this test
passes today by luck. It is a regression guard for the clamp the fix adds. Expected output from
Elm on node.

-}

-- CHECK-DAG: sleep: "inf: woke first"
-- CHECK-DAG: sleep: "nan: woke first"
-- CHECK-DAG: sleep: "huge: woke first"
-- CHECK: sleep: "reference woke"

import Platform
import Process
import Task


type Msg
    = Woke String
    | Reference


type alias Model =
    { referenceDone : Bool }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { referenceDone = False }
    , Cmd.batch
        [ Task.perform (\_ -> Woke "inf") (Process.sleep (1 / 0))
        , Task.perform (\_ -> Woke "nan") (Process.sleep (0 / 0))
        , Task.perform (\_ -> Woke "huge") (Process.sleep 1.0e300)
        , Task.perform (\_ -> Reference) (Process.sleep 2000)
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Woke name ->
            let
                _ =
                    if model.referenceDone then
                        Debug.log "sleep" (name ++ ": woke after the reference")

                    else
                        Debug.log "sleep" (name ++ ": woke first")
            in
            ( model, Cmd.none )

        Reference ->
            let
                _ =
                    Debug.log "sleep" "reference woke"
            in
            ( { model | referenceDone = True }, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
