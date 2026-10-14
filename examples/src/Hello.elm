module Hello exposing (main)

{-| Hello world: print a greeting to stdout.

    eco make src/Hello.elm --output=hello && ./hello

-}

import Stream.Log
import System


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env -> System.endSimpleProgram (Stream.Log.line env.stdout "Hello World!"))
