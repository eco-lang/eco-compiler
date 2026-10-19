module EnvVarsTest exposing (main)

{-| `System.environmentVariables` reads the process environment
(plans/eco-system-library.md Phase 3 step 3.6).
-}

-- CHECK: has PATH: True
-- CHECK: PATH non-empty: True
-- EXIT: 0

import Dict
import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            System.environmentVariables
                |> Task.andThen
                    (\vars ->
                        Stream.logLine
                            ("has PATH: "
                                ++ boolString (Dict.member "PATH" vars)
                                ++ "\nPATH non-empty: "
                                ++ boolString (Dict.get "PATH" vars |> Maybe.map (not << String.isEmpty) |> Maybe.withDefault False)
                            )
                            env.stdout
                    )
        )


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"
