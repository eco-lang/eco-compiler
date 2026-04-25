module JsonRoundtripInt exposing (main)

-- CHECK: JsonRoundtripInt: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


gen : Int -> Seed -> ( List Int, Seed )
gen size seed =
    Gen.listOf size Gen.int32 seed


encoder : List Int -> String
encoder xs =
    E.encode 0 (E.list E.int xs)


decoder : D.Decoder (List Int)
decoder =
    D.list D.int


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
        { label = "JsonRoundtripInt"
        , run = run
        }
