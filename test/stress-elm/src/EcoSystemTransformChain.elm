module EcoSystemTransformChain exposing (main)

{-| Stress variant of the Phase 6 stream transformation tests
(plans/eco-system-library.md Phase 6 step 6.3, §3.3.3 gate 3): 1 MiB of text
per cycle through a chain of pipes

    fromList → custom (upper-case, counts chunks in its state) → textEncoder
        → gzipCompression → gzipDecompression → textDecoder → readUntilClosed

with small buffers everywhere, so most values park and every pump crosses
Elm (the custom action), zlib and the UTF-8 codecs. The text contains
multibyte characters so chunk boundaries split UTF-8 sequences after the
round trip. The result must equal the upper-cased input.
-}

-- CHECK: EcoSystemTransformChain: True

import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


chunkCount : Int
chunkCount =
    256


{-| 256 chunks of 4096 characters (1 MiB of mostly ASCII; each chunk carries
one 2-byte character, so the encoded size is slightly above 1 MiB).
-}
chunks : Int -> List String
chunks cycle =
    List.range 0 (chunkCount - 1)
        |> List.map
            (\i ->
                let
                    tag =
                        "chunk " ++ String.fromInt (i + cycle) ++ " é "
                in
                String.left 4096 (tag ++ String.repeat 4096 "abcdefghij")
            )


upper : Int -> String -> Stream.CustomTransformationAction Int String
upper n value =
    Stream.Send { state = n + 1, send = [ String.toUpper value ] }


roundTrip : List String -> Task Stream.Error String
roundTrip input =
    Stream.fromList input
        |> Task.andThen (Stream.awaitAndPipeThrough (Stream.customTransformationWithOptions upper { initialState = 0, readCapacity = 1, writeCapacity = 1 }))
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.textEncoder)
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.gzipCompression)
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.gzipDecompression)
        |> Task.andThen (Stream.awaitAndPipeThrough Stream.textDecoder)
        |> Task.andThen (Stream.readUntilClosed (\part acc -> Ok (part :: acc)) [])
        |> Task.map (List.reverse >> String.concat)


cycleOnce : Int -> Task Never Bool
cycleOnce i =
    let
        input =
            chunks i
    in
    roundTrip input
        |> Task.map (\out -> out == String.toUpper (String.concat input))
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) cycleOnce


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemTransformChain"
        , run = run
        }
