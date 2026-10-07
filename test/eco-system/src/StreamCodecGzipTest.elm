module StreamCodecGzipTest exposing (main)

{-| The compression codecs (plans/eco-system-library.md Phase 6 step 6.3):

  - node's zlib output for 1 MiB of text (`StreamCodecFixture`, written by
    `system-kernel-cpp/scripts/gen-stream-codec-fixture.js`), fed in 1000-byte
    chunks, decompresses to the same text with all three decompressors;
  - the text written as one 1 MiB chunk round-trips through each compressor
    and its decompressor (the compressed output arrives in several chunks);
  - corrupt input and a truncated stream cancel both streams.

-}

-- CHECK: gzip fixture: True
-- CHECK: deflate fixture: True
-- CHECK: raw fixture: True
-- CHECK: gzip round trip: True
-- CHECK: deflate round trip: True
-- CHECK: raw round trip: True
-- CHECK: gzip compresses: True
-- CHECK: corrupt: err Cancelled: incorrect header check
-- CHECK: truncated: err Cancelled: Unexpected end of compressed data.
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode
import Stream
import StreamCodecFixture
import StreamCodecHelp exposing (base64ToBytes, bytesToString, concatBytes, readAll, splitBytes)
import StreamTestHelp
import System
import Task exposing (Task)


data : String
data =
    StreamCodecHelp.codecData StreamCodecFixture.dataSize


decompressFixture : Task Stream.Error (Stream.Transformation Bytes Bytes) -> String -> Task Stream.Error String
decompressFixture decompressor base64 =
    Stream.fromList (splitBytes 1000 (base64ToBytes base64))
        |> Task.andThen (Stream.awaitAndPipeThrough decompressor)
        |> Task.andThen readAll
        |> Task.map (\chunks -> bool (bytesToString (concatBytes chunks) == data))


roundTrip : Task Stream.Error (Stream.Transformation Bytes Bytes) -> Task Stream.Error (Stream.Transformation Bytes Bytes) -> Task Stream.Error String
roundTrip compressor decompressor =
    Stream.fromList [ Bytes.Encode.encode (Bytes.Encode.string data) ]
        |> Task.andThen (Stream.awaitAndPipeThrough compressor)
        |> Task.andThen (Stream.awaitAndPipeThrough decompressor)
        |> Task.andThen readAll
        |> Task.map (\chunks -> bool (List.length chunks > 1 && bytesToString (concatBytes chunks) == data))


compressedSize : Task Stream.Error Int
compressedSize =
    Stream.fromList [ Bytes.Encode.encode (Bytes.Encode.string data) ]
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.gzipCompression)
        |> Task.andThen readAll
        |> Task.map (\chunks -> List.sum (List.map Bytes.width chunks))


failure : List Bytes -> Task x String
failure input =
    Stream.fromList input
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.gzipDecompression)
        |> Task.andThen readAll
        |> StreamTestHelp.describe


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ decompressFixture Stream.gzipDecompression StreamCodecFixture.gzipBase64 |> Task.map (\r -> "gzip fixture: " ++ r)
                , decompressFixture Stream.deflateDecompression StreamCodecFixture.deflateBase64 |> Task.map (\r -> "deflate fixture: " ++ r)
                , decompressFixture Stream.deflateRawDecompression StreamCodecFixture.deflateRawBase64 |> Task.map (\r -> "raw fixture: " ++ r)
                , roundTrip Stream.gzipCompression Stream.gzipDecompression |> Task.map (\r -> "gzip round trip: " ++ r)
                , roundTrip Stream.deflateCompression Stream.deflateDecompression |> Task.map (\r -> "deflate round trip: " ++ r)
                , roundTrip Stream.deflateRawCompression Stream.deflateRawDecompression |> Task.map (\r -> "raw round trip: " ++ r)
                , compressedSize |> Task.map (\n -> "gzip compresses: " ++ bool (n > 0 && n < 100000))
                , failure [ Bytes.Encode.encode (Bytes.Encode.string "this is not gzip data") ] |> Task.map (\r -> "corrupt: " ++ r)
                , failure (List.take 1 (splitBytes 1000 (base64ToBytes StreamCodecFixture.gzipBase64))) |> Task.map (\r -> "truncated: " ++ r)
                ]
        )
