module StreamCodecGzipMultiMemberTest exposing (main)

{-| STREAM-03 (plans/kernel-lib-bug-fixes.md): `Stream.Transformation.gunzip` on two concatenated
gzip members (`gzip -c a; gzip -c b`, what `zcat` and Node's `zlib.gunzipSync` accept). Eco's
inflate stops at the first member's end and fails on the rest ("Junk found after end of compressed
data."). Decision D30: this is deliberate and documented (system-kernel-cpp/src/Stream/Transformation.elm,
matching WHATWG `DecompressionStream`), so the test PINS the rejection, and the bug is closed.

The input is `zlib.gzipSync('hello ')` (26 bytes) followed by `zlib.gzipSync('world')` (25 bytes),
written by node and fed three ways: as one chunk, split exactly at the member boundary, and in
1-byte chunks (the second member's `1f 8b` straddles a chunk boundary). The pinned lines were
recorded from the native build. The JS backend does NOT agree: node's DecompressionStream decodes
both members and prints `hello world` three times (run-js-e2e.js, 2026-11-04), hence SKIP-JS.

-}

-- CHECK: one chunk: err Failed: Junk found after end of compressed data.
-- CHECK: boundary split: err Failed: Junk found after end of compressed data.
-- CHECK: byte chunks: err Failed: Junk found after end of compressed data.
-- EXIT: 0
-- SKIP-JS: node's DecompressionStream accepts concatenated gzip members (prints hello world); native rejects them by design (D30)

import Bytes exposing (Bytes)
import Stream
import Stream.Transformation
import StreamCodecHelp exposing (base64ToBytes, bytesToString, concatBytes, readAll, splitBytes)
import StreamTestHelp
import System
import Task exposing (Task)


{-| node -e "z=require('zlib'); console.log(Buffer.concat([z.gzipSync('hello '), z.gzipSync('world')]).toString('base64'))"
-}
twoMembers : Bytes
twoMembers =
    base64ToBytes "H4sIAAAAAAAAA8tIzcnJVwAA9vmB7QYAAAAfiwgAAAAAAAADK88vykkBAEMRdzoFAAAA"


firstMemberLength : Int
firstMemberLength =
    26


gunzipChunks : List Bytes -> Task x String
gunzipChunks chunks =
    Stream.fromList chunks
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.Transformation.gunzip)
        |> Task.andThen readAll
        |> Task.map (\out -> bytesToString (concatBytes out))
        |> Task.onError (\err -> Task.succeed ("err " ++ Stream.errorToString err))


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ gunzipChunks [ twoMembers ] |> Task.map (\r -> "one chunk: " ++ r)
                , gunzipChunks (splitBytes firstMemberLength twoMembers) |> Task.map (\r -> "boundary split: " ++ r)
                , gunzipChunks (splitBytes 1 twoMembers) |> Task.map (\r -> "byte chunks: " ++ r)
                ]
        )
