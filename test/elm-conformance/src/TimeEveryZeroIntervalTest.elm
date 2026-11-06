module TimeEveryZeroIntervalTest exposing (main)

{-| `Time.every` with a zero, negative or infinite interval ticks at a bounded rate rather than as
fast as it can.

The program subscribes to `Time.every 0`, `Time.every -5` and `Time.every (1 / 0)` for 200 ms,
then unsubscribes and reports. Each must have ticked at most 400 times, twice what one tick per
millisecond would give, and the zero interval must have ticked at least once.

-}

-- CHECK: zero: "zero bounded: True"
-- CHECK: zero: "negative bounded: True"
-- CHECK: zero: "inf bounded: True"
-- CHECK: zero: "zero ticked: True"

import Platform
import Process
import Task
import Time


type Msg
    = Z Time.Posix
    | N Time.Posix
    | I Time.Posix
    | Stop


type alias Model =
    { z : Int
    , n : Int
    , i : Int
    , stopped : Bool
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { z = 0, n = 0, i = 0, stopped = False }
    , Task.perform (\_ -> Stop) (Process.sleep 200)
    )


bool : Bool -> String
bool v =
    if v then
        "True"

    else
        "False"


bound : Int
bound =
    400


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Z _ ->
            ( { model | z = model.z + 1 }, Cmd.none )

        N _ ->
            ( { model | n = model.n + 1 }, Cmd.none )

        I _ ->
            ( { model | i = model.i + 1 }, Cmd.none )

        Stop ->
            let
                _ =
                    Debug.log "zero" ("zero bounded: " ++ bool (model.z <= bound))

                _ =
                    Debug.log "zero" ("negative bounded: " ++ bool (model.n <= bound))

                _ =
                    Debug.log "zero" ("inf bounded: " ++ bool (model.i <= bound))

                _ =
                    Debug.log "zero" ("zero ticked: " ++ bool (model.z >= 1))
            in
            ( { model | stopped = True }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.stopped then
        Sub.none

    else
        Sub.batch
            [ Time.every 0 Z
            , Time.every -5 N
            , Time.every (1 / 0) I
            ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
