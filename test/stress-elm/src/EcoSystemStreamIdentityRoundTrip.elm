module EcoSystemStreamIdentityRoundTrip exposing (main)

{-| Stress variant of eco-system/StreamIdentityRoundTripTest
(plans/eco-system-library.md Phase 3 step 3.6, §3.3.3 gate 3).

Each cycle pushes `10 * maxSize` heap-allocated records (strings and lists
inside) through an identity transformation with small, unequal capacities: a
spawned writer writes them and closes, the reader collects them with
`readUntilClosed`. Values sit in the stream table (scanned by the registry's
root scanner) while the writer and reader park and resume, so every GC that
runs meanwhile must evacuate them in place.
-}

-- CHECK: EcoSystemStreamIdentityRoundTrip: True

import Process
import Stream
import StressHarness exposing (StressFlags)
import Task exposing (Task)


type alias Item =
    { n : Int, s : String, l : List Int }


item : Int -> Int -> Item
item cycleIndex k =
    { n = k + cycleIndex, s = "item-" ++ String.fromInt k, l = [ k, k * 2, k * 3 ] }


writeAll : List Item -> Stream.Writable Item -> Task Stream.Error ()
writeAll items w =
    case items of
        [] ->
            Stream.closeWritable w

        x :: rest ->
            Stream.write x w |> Task.andThen (writeAll rest)


cycle : Int -> Int -> Task Never Bool
cycle size i =
    let
        items =
            List.map (item i) (List.range 1 size)
    in
    Stream.identityTransformationWithOptions { readCapacity = 7, writeCapacity = 3 }
        |> Task.andThen
            (\t ->
                Process.spawn (writeAll items (Stream.writable t) |> Task.onError (\_ -> Task.succeed ()))
                    |> Task.andThen
                        (\_ -> Stream.readUntilClosed (\v acc -> Ok (v :: acc)) [] (Stream.readable t))
            )
        |> Task.map (\got -> List.reverse got == items)
        |> Task.onError (\_ -> Task.succeed False)


run : StressFlags -> Task Never Bool
run flags =
    StressHarness.loopWhile flags (max 1 flags.numLoops) (cycle (10 * max 1 flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "EcoSystemStreamIdentityRoundTrip"
        , run = run
        }
