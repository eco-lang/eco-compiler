module HarnessStdinTest exposing (main)

{-| Harness self-test (Phase 1 step 8c, deferred to Phase 3): `-- STDIN:` text
reaches the program's fd 0 through a pipe, with `\t`, `\\` and `\n` unescaped
and repeated lines concatenated; the program sees end-of-input after it.
-}

-- STDIN: one\ttwo\\
-- STDIN: \n
-- CHECK: stdin: [one<TAB>two\<NL>]
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Decode
import Stream
import Stream.Log
import System
import Task


decode : Bytes -> String
decode bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
        |> Maybe.withDefault "<invalid>"


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.readUntilClosed (\chunk acc -> Ok (acc ++ decode chunk)) "" env.stdin
                    |> Task.map (String.replace "\t" "<TAB>" >> String.replace "\n" "<NL>")
                    |> Task.onError (\err -> Task.succeed ("error: " ++ Stream.errorToString err))
                    |> Task.andThen (\text -> Stream.Log.line env.stdout ("stdin: [" ++ text ++ "]"))
                )
        )
