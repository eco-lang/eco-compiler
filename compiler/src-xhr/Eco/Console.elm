module Eco.Console exposing
    ( Handle(..), stdout, stderr
    , write, readLine, readAll
    )

{-| Console IO operations via XHR: write to handles, read from stdin.

This is the XHR-based bootstrap implementation. The kernel variant
(in eco-kernel-cpp) has identical type signatures but delegates to
Eco.Kernel.Console directly.


# Handles

@docs Handle, stdout, stderr


# Operations

@docs write, readLine, readAll

-}

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
write : Handle -> String -> Task Never ()
write (Handle h) content =
    Eco.XHR.unitTask "Console.write"
        (Encode.object
            [ ( "handle", Encode.int h )
            , ( "content", Encode.string content )
            ]
        )


{-| Read one line from stdin.
-}
readLine : Task Never String
readLine =
    Eco.XHR.stringTask "Console.readLine" Encode.null


{-| Read all of stdin as a string.
-}
readAll : Task Never String
readAll =
    Eco.XHR.stringTask "Console.readAll" Encode.null
