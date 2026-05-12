module Eco.Console exposing
    ( Handle(..), stdout, stderr
    , write, readLine, readAll
    , log
    )

{-| Console IO operations: write to handles, read from stdin.

All operations are atomic IO primitives backed by kernel implementations.


# Handles

@docs Handle, stdout, stderr


# Operations

@docs write, readLine, readAll


# Debugging

@docs log

-}

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


{-| Write a string to a console handle (stdout or stderr).
-}
write : Handle -> String -> Task Never ()
write (Handle h) content =
    Eco.Kernel.Console.write h content


{-| Read one line from stdin.
-}
readLine : Task Never String
readLine =
    Eco.Kernel.Console.readLine


{-| Read all of stdin as a string.
-}
readAll : Task Never String
readAll =
    Eco.Kernel.Console.readAll


{-| Debug-style trace function. Writes `tag` to stderr and returns `value`
unchanged. Mirrors `Debug.log` but is allowed under `--optimize` because
it is not a `Debug.*` function.
-}
log : String -> a -> a
log tag value =
    Eco.Kernel.Console.log tag value
