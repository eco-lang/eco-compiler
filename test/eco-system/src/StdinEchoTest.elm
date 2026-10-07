module StdinEchoTest exposing (main)

{-| Reads stdin (fd 0, an FdSource) until it closes and echoes it
(plans/eco-system-library.md Phase 3 step 3.6). Repeated STDIN directives are
concatenated, so stdin holds "abc\ndef\n".
-}

-- STDIN: abc\n
-- STDIN: def\n
-- CHECK: echo: abc|def|
-- CHECK: chunks > 0: True
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Decode
import Stream
import Stream.Log
import System
import Task


bytesToString : Bytes -> String
bytesToString bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
        |> Maybe.withDefault "<invalid>"


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Stream.readUntilClosed (\chunk acc -> Ok (chunk :: acc)) [] env.stdin
                    |> Task.map
                        (\chunks ->
                            let
                                text =
                                    chunks
                                        |> List.reverse
                                        |> List.map bytesToString
                                        |> String.concat
                            in
                            "echo: "
                                ++ String.replace "\n" "|" text
                                ++ "\nchunks > 0: "
                                ++ (if List.length chunks > 0 then
                                        "True"

                                    else
                                        "False"
                                   )
                        )
                    |> Task.onError (\err -> Task.succeed ("error: " ++ Stream.errorToString err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )
