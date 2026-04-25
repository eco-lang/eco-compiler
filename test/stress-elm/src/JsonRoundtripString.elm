module JsonRoundtripString exposing (main)

-- CHECK: JsonRoundtripString: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( String, Seed )
genItem seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 20 seed
    in
    Gen.unicodeString len s1


gen : Int -> Seed -> ( List String, Seed )
gen size seed =
    Gen.listOf size genItem seed


encoder : List String -> String
encoder xs =
    E.encode 0 (E.list E.string xs)


decoder : D.Decoder (List String)
decoder =
    D.list D.string


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
            flags.numLoops // 4
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonRoundtripString"
        , run = run
        }
