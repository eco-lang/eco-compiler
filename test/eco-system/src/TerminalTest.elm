module TerminalTest exposing (main)

{-| `Terminal` under the test harness (plans/eco-system-library.md Phase 5
step 5.4): stdout is a pipe, so `configuration` is `Nothing`; raw mode on a
non-terminal stdin is a no-op that succeeds; `setTitle` writes the title
sequence only to a terminal, so nothing of it reaches the piped stdout
(plans/eco-system-api-refactor.md D10).
-}

-- CHECK: configuration: Nothing
-- CHECK: raw mode: ok
-- CHECK: title: ok
-- CHECK-NOT: ]2;eco-title
-- EXIT: 0

import Stream
import System
import Task exposing (Task)
import Terminal


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Terminal.configuration
                |> Task.map
                    (\c ->
                        case c of
                            Nothing ->
                                "configuration: Nothing"

                            Just _ ->
                                "configuration: Just"
                    )
                |> Task.andThen
                    (\conf ->
                        Terminal.setStdinRawMode True
                            |> Task.andThen (\_ -> Terminal.setStdinRawMode False)
                            |> Task.map (\_ -> conf ++ "\nraw mode: ok")
                    )
                |> Task.andThen
                    (\s ->
                        Terminal.setTitle "eco-title"
                            |> Task.map (\_ -> s ++ "\ntitle: ok")
                    )
                |> Task.andThen (\text -> Stream.logLine text env.stdout)
        )
