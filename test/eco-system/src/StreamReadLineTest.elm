module StreamReadLineTest exposing (main)

{-| `Stream.readLine` (plans/eco-system-api-refactor.md D18): lines from stdin
end at `\n`, an empty line is an empty string, and a last line without a
newline is returned before `Closed`. On a file stream, a line longer than the
64 KiB chunks arrives whole, without the `\r` of its CRLF ending, and a `read`
after `readLine` gets the bytes `readLine` read past its line first. (The
harness's `-- STDIN:` does not unescape `\r`, so CRLF is tested on the file.)
-}

-- STDIN: alpha\nbeta\n\ngamma
-- CHECK: stdin: [alpha] [beta] [] [gamma] Closed
-- CHECK: long: 200000 True
-- CHECK: after long: [tail]
-- CHECK: read after readLine: rest
-- CHECK: then: Closed
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Decode
import FileSystem
import FileTestHelp exposing (bytes, child, file, stream)
import Stream
import System
import Task exposing (Task)


{-| Every line until the stream ends, then how it ended.
-}
allLines : Stream.Readable Bytes -> List String -> Task x String
allLines input acc =
    Stream.readLine input
        |> Task.map Ok
        |> Task.onError (\err -> Task.succeed (Err err))
        |> Task.andThen
            (\result ->
                case result of
                    Ok line ->
                        allLines input (acc ++ [ "[" ++ line ++ "]" ])

                    Err err ->
                        Task.succeed (String.join " " (acc ++ [ endName err ]))
            )


endName : Stream.Error -> String
endName err =
    case err of
        Stream.Closed ->
            "Closed"

        Stream.Cancelled reason ->
            "Cancelled " ++ reason

        Stream.Locked ->
            "Locked"


decode : Bytes -> String
decode b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b
        |> Maybe.withDefault "<invalid>"


fileLines : Task String (List String)
fileLines =
    FileTestHelp.withTempDir
        (\dir ->
            let
                path =
                    child dir "lines.txt"

                long =
                    String.repeat 200000 "x"
            in
            file (FileSystem.writeFile (bytes (long ++ "\r\ntail\nrest")) path)
                |> Task.andThen (\_ -> file (FileSystem.readFileStream FileSystem.Beginning path))
                |> Task.andThen
                    (\input ->
                        stream (Stream.readLine input)
                            |> Task.andThen
                                (\first ->
                                    stream (Stream.readLine input)
                                        |> Task.andThen
                                            (\second ->
                                                stream (Stream.read input)
                                                    |> Task.andThen
                                                        (\rest ->
                                                            Stream.read input
                                                                |> Task.map (\_ -> "more data")
                                                                |> Task.onError (\err -> Task.succeed (endName err))
                                                                |> Task.map
                                                                    (\after ->
                                                                        [ "long: " ++ String.fromInt (String.length first) ++ " " ++ boolString (first == long)
                                                                        , "after long: [" ++ second ++ "]"
                                                                        , "read after readLine: " ++ decode rest
                                                                        , "then: " ++ after
                                                                        ]
                                                                    )
                                                        )
                                            )
                                )
                    )
        )


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : Platform.Program System.Environment () ()
main =
    FileTestHelp.program
        (\env ->
            allLines env.stdin []
                |> Task.andThen
                    (\stdinLines ->
                        fileLines
                            |> Task.map (\more -> ("stdin: " ++ stdinLines) :: more)
                    )
        )
