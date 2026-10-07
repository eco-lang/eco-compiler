module Utf8StrictTest exposing (main)

{-| `readBytesAsString` decodes strictly (plans/eco-system-library.md §3.5,
B5): valid UTF-8 converts; overlong encodings, encoded surrogates, stray
continuation bytes and truncated sequences fail with `Cancelled`, and the
stream is cancelled (a later read gets `Closed`).
-}

-- CHECK: valid: héllo €𝄞
-- CHECK: overlong: err Cancelled: Failed to convert bytes to string
-- CHECK: surrogate: err Cancelled: Failed to convert bytes to string
-- CHECK: continuation: err Cancelled: Failed to convert bytes to string
-- CHECK: truncated: err Cancelled: Failed to convert bytes to string
-- CHECK: above max: err Cancelled: Failed to convert bytes to string
-- CHECK: after failure: err Closed
-- CHECK: empty: <>
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Stream
import StreamTestHelp
import System
import Task exposing (Task)


bytesOf : List Int -> Bytes
bytesOf ints =
    E.encode (E.sequence (List.map E.unsignedInt8 ints))


convert : Bytes -> Task Stream.Error String
convert bytes =
    Stream.identityTransformation
        |> Task.andThen
            (\t ->
                Stream.write bytes (Stream.writable t)
                    |> Task.andThen (\_ -> Stream.readBytesAsString (Stream.readable t))
            )


describeString : Task Stream.Error String -> Task x String
describeString task =
    task
        |> Task.onError (\err -> Task.succeed ("err " ++ Stream.errorToString err))


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ convert (E.encode (E.string "héllo €𝄞")) |> describeString |> Task.map ((++) "valid: ")
                , convert (bytesOf [ 0xC0, 0x80 ]) |> describeString |> Task.map ((++) "overlong: ")
                , convert (bytesOf [ 0xED, 0xA0, 0x80 ]) |> describeString |> Task.map ((++) "surrogate: ")
                , convert (bytesOf [ 0x61, 0x80 ]) |> describeString |> Task.map ((++) "continuation: ")
                , convert (bytesOf [ 0xE2, 0x82 ]) |> describeString |> Task.map ((++) "truncated: ")
                , convert (bytesOf [ 0xF4, 0x90, 0x80, 0x80 ]) |> describeString |> Task.map ((++) "above max: ")
                , Stream.identityTransformation
                    |> Task.andThen
                        (\t ->
                            Stream.write (bytesOf [ 0xFF ]) (Stream.writable t)
                                |> Task.andThen (\_ -> Stream.readBytesAsString (Stream.readable t))
                                |> Task.onError (\_ -> Task.succeed "")
                                |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.read (Stream.readable t)))
                        )
                    |> Task.map ((++) "after failure: ")
                , convert (bytesOf []) |> describeString |> Task.map (\s -> "empty: <" ++ s ++ ">")
                ]
        )
