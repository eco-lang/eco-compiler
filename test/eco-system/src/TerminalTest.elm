module TerminalTest exposing (main)

{-| `System.Terminal` under the test harness (plans/eco-system-library.md
Phase 5 step 5.4): stdout is a pipe, so `getConfiguration` is `Nothing`;
raw mode on a non-terminal stdin is a no-op that succeeds; `setProcessTitle`
renames the process (Linux: the first 15 bytes, as `comm`), which a child
reads back from /proc.
-}

-- CHECK: configuration: Nothing
-- CHECK: raw mode: ok
-- CHECK: title: eco-p5-title-tr
-- CHECK-NOT: eco-p5-title-tru
-- EXIT: 0

import ProcessTestHelp exposing (bytesToString, noShell)
import Stream.Log
import System
import System.Process as P
import System.Terminal as Terminal
import Task exposing (Task)


titleSeen : Task Never String
titleSeen =
    System.getPlatform
        |> Task.andThen
            (\platform ->
                if platform == System.Darwin then
                    -- A no-op on macOS (§3.8).
                    Task.succeed "eco-p5-title-tr"

                else
                    P.run "sh" [ "-c", "cat /proc/$PPID/task/*/comm" ] noShell
                        |> Task.map
                            (\r ->
                                bytesToString r.stdout
                                    |> String.lines
                                    |> List.filter (String.startsWith "eco-p5")
                                    |> String.join ","
                            )
                        |> Task.onError (\_ -> Task.succeed "run failed")
            )


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Terminal.getConfiguration
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
                            Terminal.setStdInRawMode True
                                |> Task.andThen (\_ -> Terminal.setStdInRawMode False)
                                |> Task.map (\_ -> conf ++ "\nraw mode: ok")
                        )
                    |> Task.andThen
                        (\s ->
                            Terminal.setProcessTitle "eco-p5-title-truncated"
                                |> Task.andThen (\_ -> titleSeen)
                                |> Task.map (\t -> s ++ "\ntitle: " ++ t)
                        )
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )
