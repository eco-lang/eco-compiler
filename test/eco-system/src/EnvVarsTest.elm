module EnvVarsTest exposing (main)

{-| `System.getEnvironmentVariables` reads the process environment
(plans/eco-system-library.md Phase 3 step 3.6).
-}

-- CHECK: has PATH: True
-- CHECK: PATH non-empty: True
-- EXIT: 0

import Dict
import Stream.Log
import System
import Task


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (System.getEnvironmentVariables
                    |> Task.andThen
                        (\vars ->
                            Stream.Log.line env.stdout
                                ("has PATH: "
                                    ++ boolString (Dict.member "PATH" vars)
                                    ++ "\nPATH non-empty: "
                                    ++ boolString (Dict.get "PATH" vars |> Maybe.map (not << String.isEmpty) |> Maybe.withDefault False)
                                )
                        )
                )
        )


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"
