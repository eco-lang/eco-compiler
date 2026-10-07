module Stream.Log exposing (bytes, string, line)

{-| The functions in this module let you send data to streams on a best effort basis. If
something goes wrong, the error is silently ignored.

We don't normally encourage ignoring errors in this way, but for the explicit purpose of logging
it's not always clear how you would handle an error. If you cannot log an error message to the
terminal, do you try again? Try again on another stream? What if that also fails?

Only use these functions if there is no sane way to handle the event in which sending data to a
stream fails!


# Operations

@docs bytes, string, line

-}

import Bytes exposing (Bytes)
import Stream
import Task exposing (Task)


{-| Send `Bytes` to a writable byte stream. The `Task` succeeds once the write has finished or
failed; any error is ignored.
-}
bytes : Stream.Writable Bytes -> Bytes -> Task x ()
bytes stream data =
    Debug.todo "Implement System API"


{-| Send a `String`, encoded as UTF-8, to a writable byte stream. Any potential error is ignored.
-}
string : Stream.Writable Bytes -> String -> Task x ()
string stream data =
    Debug.todo "Implement System API"


{-| Send a `String`, encoded as UTF-8, to a writable byte stream, followed by a newline character.
Any potential error is ignored.

    Stream.Log.line env.stdout "Hello, world!"

-}
line : Stream.Writable Bytes -> String -> Task x ()
line stream data =
    Debug.todo "Implement System API"
