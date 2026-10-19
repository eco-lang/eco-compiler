module StreamTransformTypesTest exposing (main)

{-| `readable` / `writable` on a transformation whose input and output types
differ (plans/eco-system-library.md D14). `textEncoder` is a
`Transformation String Bytes`: Strings go in through `writable`, Bytes come
out of `readable`. This only type-checks with the corrected annotations
(`writable : Transformation input output -> Writable input`,
`readable : Transformation input output -> Readable output`); gren-lang/core's
annotations had the two parameters the wrong way round.
-}

-- CHECK: encoded: 68 C3 A9
-- EXIT: 0

import Bytes exposing (Bytes)
import Stream
import Stream.Transformation
import StreamCodecHelp exposing (hex)
import StreamTestHelp
import System
import Task exposing (Task)


encodeOne : Stream.Transformation String Bytes -> Task Stream.Error String
encodeOne t =
    let
        input : Stream.Writable String
        input =
            Stream.Transformation.writable t

        output : Stream.Readable Bytes
        output =
            Stream.Transformation.readable t
    in
    Stream.write "hé" input
        |> Task.andThen Stream.closeWritable
        |> Task.andThen (\_ -> Stream.read output)
        |> Task.map hex


main : Platform.Program System.Environment () ()
main =
    StreamTestHelp.program
        (\_ ->
            Stream.Transformation.textEncoder
                |> Task.andThen encodeOne
                |> Task.map (\r -> [ "encoded: " ++ r ])
        )
