module ArgsTest exposing (main)

{-| `env.args` is the full C argv, so it holds at least the program itself
(plans/eco-system-library.md Phase 3 step 3.6, D10), and `applicationPath` is
the absolute path of the running executable.
-}

-- CHECK: args >= 1: True
-- CHECK: argv0 non-empty: True
-- CHECK: applicationPath absolute: True
-- EXIT: 0

import Stream
import System


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine
                (String.join "\n"
                    [ "args >= 1: " ++ boolString (List.length env.args >= 1)
                    , "argv0 non-empty: " ++ boolString (List.head env.args |> Maybe.map (not << String.isEmpty) |> Maybe.withDefault False)
                    , "applicationPath absolute: " ++ boolString (env.applicationPath.root == "/" && env.applicationPath.filename /= "")
                    ]
                )
                env.stdout
        )
