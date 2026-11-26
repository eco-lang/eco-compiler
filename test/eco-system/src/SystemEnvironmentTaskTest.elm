module SystemEnvironmentTaskTest exposing (main)

{-| `System.environment` gives the same environment as the flags, except `startTime`, which
is the time the task ran (plans/compiler-io-on-eco-system.md P1.1).
-}

-- CHECK: platform same: True
-- CHECK: arch same: True
-- CHECK: applicationPath same: True
-- CHECK: args same: True
-- CHECK: startTime not earlier: True
-- EXIT: 0

import Stream
import System
import Task
import Time


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\flags ->
            System.environment
                |> Task.andThen
                    (\env ->
                        Stream.logLine
                            (String.join "\n"
                                [ "platform same: " ++ boolString (env.platform == flags.platform)
                                , "arch same: " ++ boolString (env.cpuArchitecture == flags.cpuArchitecture)
                                , "applicationPath same: " ++ boolString (env.applicationPath == flags.applicationPath)
                                , "args same: " ++ boolString (env.args == flags.args)
                                , "startTime not earlier: " ++ boolString (Time.posixToMillis env.startTime >= Time.posixToMillis flags.startTime)
                                ]
                            )
                            flags.stdout
                    )
        )
