module IoProbe exposing (main)

{-| Runs one of the compiler's own IO wrappers from `Utils.Main` on the command
line, so test/scripts/compiler-io.test.js can check its behaviour on a real
file system: `canonicalize <path>` prints `Utils.dirCanonicalizePath path`, and
`remove-dir <path>` runs `Utils.dirRemoveDirectoryRecursiveIfExists path` and
prints `removed`. A wrapper that crashes ends the program with its IO error.
-}

import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils


main : IO.Program
main =
    IO.run
        (Utils.envGetArgs
            |> Task.andThen run
            |> Task.andThen (\() -> Exit.exitSuccess)
        )


run : List String -> Task Never ()
run args =
    case args of
        [ "canonicalize", path ] ->
            Utils.dirCanonicalizePath path
                |> Task.andThen IO.printLn

        [ "remove-dir", path ] ->
            Utils.dirRemoveDirectoryRecursiveIfExists path
                |> Task.andThen (\() -> IO.printLn "removed")

        _ ->
            IO.printLn "usage: IoProbe (canonicalize | remove-dir) <path>"
                |> Task.andThen (\() -> Exit.exitFailure)
