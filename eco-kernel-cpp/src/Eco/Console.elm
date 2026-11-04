module Eco.Console exposing
    ( Handle(..), stdout, stderr
    , write, readLine, readAll, isTerminal
    , log
    )

{-| Console IO operations: write to handles, read from stdin.

All operations are atomic IO primitives backed by kernel implementations.


# Handles

@docs Handle, stdout, stderr


# Operations

@docs write, readLine, readAll, isTerminal


# Debugging

@docs log

-}

import Eco.IO.Error as IOErr exposing (IOError)
import Eco.Kernel.Console
import Task exposing (Task)


{-| A console handle identifying an output stream.
-}
type Handle
    = Handle Int


{-| Standard output handle.
-}
stdout : Handle
stdout =
    Handle 1


{-| Standard error handle.
-}
stderr : Handle
stderr =
    Handle 2


{-| Write a string to a console handle: stdout, stderr, or the stdin handle
of a child started by `Eco.Process.spawnProcess` with `CreatePipe` (until it
is closed with `Eco.File.close`). Any other handle fails with
`BadFileDescriptor`.
-}
write : Handle -> String -> Task IOError ()
write (Handle h) content =
    Eco.Kernel.Console.write h content
        |> Task.mapError IOErr.ofKernelTuple


{-| Read one line from stdin, without its line break. At the end of input it
gives what is left of the last line, possibly `""`.

The read does not block the program: timers, subscriptions and other tasks
go on while it waits for input.
-}
readLine : Task IOError String
readLine =
    Eco.Kernel.Console.readLine
        |> Task.mapError IOErr.ofKernelTuple


{-| Read all of stdin, to the end of input, as a string, exactly as it
arrives (blank lines and the final newline included). Like `readLine`, it does
not block the program while it waits.
-}
readAll : Task IOError String
readAll =
    Eco.Kernel.Console.readAll
        |> Task.mapError IOErr.ofKernelTuple


{-| Whether the stream the handle names is a terminal. Only the standard
streams (handles 0, 1 and 2) can answer `True`.
-}
isTerminal : Handle -> Task Never Bool
isTerminal (Handle h) =
    Eco.Kernel.Console.isTerminal h


{-| Debug-style trace function. Writes `tag` to stderr and returns `value`
unchanged. Mirrors `Debug.log` but is allowed under `--optimize` because
it is not a `Debug.*` function.
-}
log : String -> a -> a
log tag value =
    Eco.Kernel.Console.log tag value
