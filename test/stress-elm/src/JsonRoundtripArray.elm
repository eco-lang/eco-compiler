module JsonRoundtripArray exposing (main)

-- CHECK: JsonRoundtripArray: True

import Array exposing (Array)
import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


gen : Int -> Seed -> ( Array Int, Seed )
gen size seed =
    let
        ( xs, s1 ) =
            Gen.listOf size Gen.int32 seed
    in
    ( Array.fromList xs, s1 )


encoder : Array Int -> String
encoder arr =
    E.encode 0 (E.array E.int arr)


decoder : D.Decoder (Array Int)
decoder =
    D.array D.int


cycleStep : Int -> Seed -> ( Seed, Bool )
cycleStep size seed =
    let
            ( original, seed1 ) =
                gen size seed

            encoded =
                encoder original

            decoded =
                D.decodeString decoder encoded

            ok2 =
                case decoded of
                    Ok v ->
                        v == original

                    Err _ ->
                        False
    in
    ( seed1, ok2 )


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonRoundtripArray"
        , run = run
        }
