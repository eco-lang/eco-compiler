module FileTestHelp exposing (attempt, byteList, showInts, bytes, child, fail, file, fromBytes, program, rawError, stream, withTempDir)

{-| Shared helpers for the eco/system file tests (not a test: no `main`).

Every test runs one task in a fresh temporary directory (removed afterwards)
and prints one labelled line per observation to the program's real stdout
through `Stream.Log`, so the `-- CHECK:` patterns are matched against raw fd
output. Errors of the file and stream APIs are turned into Strings so the
two can be mixed in one task.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Stream
import Stream.Log
import System
import System.File as File
import System.File.Path as Path exposing (Path)
import Task exposing (Task)


{-| A simple program that runs `run env` and prints every line it returns, or
`error: <reason>` if it fails.
-}
program : (System.Environment -> Task String (List String)) -> System.SimpleProgram ()
program run =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (run env
                    |> Task.map (String.join "\n")
                    |> Task.onError (\err -> Task.succeed ("error: " ++ err))
                    |> Task.andThen (Stream.Log.line env.stdout)
                )
        )


{-| `<errorCode> @<filename of errorPath>`; the empty path prints as `@`.
-}
describe : File.Error -> String
describe err =
    File.errorCode err ++ " @" ++ Path.filenameWithExtension (File.errorPath err)


file : Task File.Error a -> Task String a
file =
    Task.mapError describe


stream : Task Stream.Error a -> Task String a
stream =
    Task.mapError Stream.errorToString


fail : String -> Task String a
fail =
    Task.fail


{-| `ok <shown result>` or `err <error>`.
-}
attempt : (a -> String) -> Task String a -> Task x String
attempt show task =
    task
        |> Task.map (\a -> "ok " ++ show a)
        |> Task.onError (\e -> Task.succeed ("err " ++ e))


{-| Run `body` with a fresh temporary directory, removed recursively afterwards
(also when `body` fails).
-}
withTempDir : (Path -> Task String (List String)) -> Task String (List String)
withTempDir body =
    file (File.makeTempDirectory "eco-file-test-")
        |> Task.andThen
            (\dir ->
                body dir
                    |> Task.onError
                        (\e ->
                            File.remove { recursive = True } dir
                                |> Task.onError (\_ -> Task.succeed dir)
                                |> Task.andThen (\_ -> Task.fail e)
                        )
                    |> Task.andThen
                        (\lines ->
                            file (File.remove { recursive = True } dir)
                                |> Task.map (\_ -> lines)
                        )
            )


child : Path -> String -> Path
child dir name =
    Path.appendPosixString name dir


bytes : String -> Bytes
bytes s =
    Bytes.Encode.encode (Bytes.Encode.string s)


fromBytes : Bytes -> String
fromBytes b =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width b)) b
        |> Maybe.withDefault "<invalid utf-8>"


byteList : Bytes -> List Int
byteList b =
    let
        step ( n, acc ) =
            if n <= 0 then
                Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

            else
                Bytes.Decode.map (\x -> Bytes.Decode.Loop ( n - 1, x :: acc )) Bytes.Decode.unsignedInt8
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( Bytes.width b, [] ) step) b
        |> Maybe.withDefault []


{-| Run a task that is expected to fail and show something about its error.
-}
rawError : (File.Error -> String) -> Task File.Error a -> Task x String
rawError show task =
    task
        |> Task.map (\_ -> "no error")
        |> Task.onError (\e -> Task.succeed (show e))


showInts : List Int -> String
showInts ns =
    "[" ++ String.join "," (List.map String.fromInt ns) ++ "]"
