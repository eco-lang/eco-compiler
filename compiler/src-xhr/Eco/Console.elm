module Eco.Console exposing
    ( Handle(..), stdout, stderr
    , write, readLine, readAll
    , log
    )

{-| Console IO operations via XHR: write to handles, read from stdin.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.Console directly.


# Handles

@docs Handle, stdout, stderr


# Operations

@docs write, readLine, readAll


# Debugging

@docs log

-}

import Eco.IO.Error as IOErr exposing (IOError)
import Eco.XHR
import Json.Encode as Encode
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
write : Handle -> String -> Task IOError ()
write (Handle h) content =
    Eco.XHR.unitTask "Console.write"
        (Encode.object
            [ ( "handle", Encode.int h )
            , ( "content", Encode.string content )
            ]
        )
        |> Task.mapError IOErr.ofKernelTuple


{-| Read one line from stdin.
-}
readLine : Task IOError String
readLine =
    Eco.XHR.stringTask "Console.readLine" Encode.null
        |> Task.mapError IOErr.ofKernelTuple


{-| Read all of stdin as a string.
-}
readAll : Task IOError String
readAll =
    Eco.XHR.stringTask "Console.readAll" Encode.null
        |> Task.mapError IOErr.ofKernelTuple


{-| Debug-style trace function. XHR variant is a pure no-op (identity);
the kernel variants (JS and C++) write `tag` to stderr and return `value`.
Allowed under `--optimize` because it is not a `Debug.*` function.
-}
log : String -> a -> a
log _ value =
    value
