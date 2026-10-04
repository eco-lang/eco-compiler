module Eco.Console exposing
    ( Handle(..), stdout, stderr
    , write, readLine, readAll
    , log
    )

{-| A program running on stock Elm cannot write to the terminal or read standard
input itself, and this module does both for it by asking _eco-io_, the HTTP
server that `Eco.XHR` sends IO requests to.

Each operation here is sent to eco-io as an _op_, a string naming the
operation, as `Eco.XHR` describes: `write` sends `"Console.write"`, `readLine`
sends `"Console.readLine"` and `readAll` sends `"Console.readAll"`. The native
build compiles a twin of this module with the same exposed names and signatures
in its place.

Output goes to a _handle_, a number naming a stream to write to. `stdout` and
`stderr` are the two the module defines.

The three operations fail with an `IOError`, decoded from the failure tuple by
`Eco.IO.Error.ofKernelTuple`. A failure to reach eco-io at all is therefore an
`OtherIOError` with tag 0. A reply to `readLine` or `readAll` that succeeds but
carries no string `value` crashes the program instead.

`log` is the exception: it sends nothing and prints nothing in this build.


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


{-| A stream that `write` can send text to, named by a number.

The constructor is exposed, so any `Int` can be made into a `Handle`, and
nothing in this module checks that the number names a stream. Which numbers do
is decided by eco-io, not here.

-}
type Handle
    = Handle Int


{-| The handle of standard output.
-}
stdout : Handle
stdout =
    Handle 1


{-| The handle of standard error.
-}
stderr : Handle
stderr =
    Handle 2


{-| Writes `content` to the stream the handle names, exactly as given: no
newline is added.
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


{-| Reads the next line of standard input.

The result is a plain `String`, so there is no separate value for the end of
input; what comes back then is whatever eco-io sends.

-}
readLine : Task IOError String
readLine =
    Eco.XHR.stringTask "Console.readLine" Encode.null
        |> Task.mapError IOErr.ofKernelTuple


{-| Reads the rest of standard input as one string.
-}
readAll : Task IOError String
readAll =
    Eco.XHR.stringTask "Console.readAll" Encode.null
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns `value` unchanged and ignores the tag, the first argument.

It has the shape of `Debug.log`, but in this build it prints nothing. The
native build's twin of this module does print the tag.

-}
log : String -> a -> a
log _ value =
    value
