module StreamCodecTextTest exposing (main)

{-| `textDecoder` and `textEncoder` (plans/eco-system-library.md §3.5 UTF-8
rules, Phase 6 step 6.3). Each list of input chunks is piped through the
codec (`Transformation input output` is only well-typed through
`pipeThrough`) and every output chunk is shown, as hex UTF-16 code units or
bytes, separated by `|`.

Decoder: a leading BOM is stripped (only at the start); a multibyte sequence
split across chunks is carried; a chunk that decodes to nothing produces no
output (no empty chunk appears between `20AC 21` and `20AC`); invalid bytes
become U+FFFD; an incomplete sequence at close becomes U+FFFD.

Encoder: `""` produces no output; a surrogate pair split across chunks is
carried (the chunk holding only the high surrogate produces nothing); a high
surrogate left at close becomes EF BF BD.

-}

-- CHECK: decoder: 68 | 20AC 21 | 20AC | FEFF | FFFD 41 | FFFD
-- CHECK: decoder BOM split: 41
-- CHECK: encoder: 68 C3 A9 | F0 9F 98 80 78 | EF BF BD
-- CHECK: encoder empty: []
-- EXIT: 0

import Stream
import StreamCodecHelp exposing (bytesFromList, codes, hex, readAll)
import StreamTestHelp
import System
import Task exposing (Task)


decode : List (List Int) -> Task Stream.Error String
decode chunks =
    Stream.fromList (List.map bytesFromList chunks)
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.textDecoder)
        |> Task.andThen readAll
        |> Task.map (List.map codes >> String.join " | ")


encode : List String -> Task Stream.Error String
encode chunks =
    Stream.fromList chunks
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.textEncoder)
        |> Task.andThen readAll
        |> Task.map (List.map hex >> String.join " | ")


highSurrogate : String
highSurrogate =
    String.fromList [ Char.fromCode 0xD83D ]


lowSurrogate : String
lowSurrogate =
    String.fromList [ Char.fromCode 0xDE00 ]


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ decode
                    [ [ 0xEF, 0xBB, 0xBF, 0x68, 0xE2, 0x82 ]
                    , [ 0xAC, 0x21 ]
                    , [ 0xE2 ]
                    , [ 0x82, 0xAC ]
                    , [ 0xEF, 0xBB, 0xBF ]
                    , [ 0xFF, 0x41 ]
                    , [ 0xF0, 0x9F ]
                    ]
                    |> Task.map (\r -> "decoder: " ++ r)
                , decode [ [ 0xEF ], [ 0xBB ], [ 0xBF, 0x41 ] ]
                    |> Task.map (\r -> "decoder BOM split: " ++ r)
                , encode [ "", "hé", highSurrogate, lowSurrogate ++ "x", highSurrogate ]
                    |> Task.map (\r -> "encoder: " ++ r)
                , encode [ "", "" ]
                    |> Task.map (\r -> "encoder empty: [" ++ r ++ "]")
                ]
        )
