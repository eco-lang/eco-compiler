module EnvironmentStartTimeTest exposing (main)

{-| `Environment.startTime` (plans/eco-system-api-refactor.md D15): the time
the program started, read once at startup; it is after 2020 and not after the
time `init` reads with `Time.now`. The environment reaches `init` as the
program's flags (D13), in a full `Platform.worker` program.
-}

-- CHECK: after 2020: True
-- CHECK: not after now: True
-- EXIT: 0

import Stream
import System
import Task
import Time


type Msg
    = Now Time.Posix
    | Done


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.perform Now Time.now )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


update : Msg -> System.Environment -> ( System.Environment, Cmd Msg )
update msg env =
    case msg of
        Now now ->
            let
                start =
                    Time.posixToMillis env.startTime
            in
            ( env
            , Stream.logLine
                (String.join "\n"
                    [ "after 2020: " ++ boolString (start > 1577836800000)
                    , "not after now: " ++ boolString (start <= Time.posixToMillis now)
                    ]
                )
                env.stdout
                |> Task.perform (\_ -> Done)
            )

        Done ->
            ( env, Cmd.none )


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"
