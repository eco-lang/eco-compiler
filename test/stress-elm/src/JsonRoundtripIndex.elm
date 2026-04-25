module JsonRoundtripIndex exposing (main)

-- CHECK: JsonRoundtripIndex: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( ( Int, String, Bool ), Seed )
genItem seed =
    let
        ( i, s1 ) =
            Gen.int32 seed

        ( len, s2 ) =
            Gen.intIn 0 8 s1

        ( str, s3 ) =
            Gen.asciiString len s2

        ( b, s4 ) =
            Gen.bool s3
    in
    ( ( i, str, b ), s4 )


gen : Int -> Seed -> ( List ( Int, String, Bool ), Seed )
gen size seed =
    Gen.listOf size genItem seed


encodeItem : ( Int, String, Bool ) -> E.Value
encodeItem ( i, s, b ) =
    E.list identity
        [ E.int i
        , E.string s
        , E.bool b
        ]


encoder : List ( Int, String, Bool ) -> String
encoder xs =
    E.encode 0 (E.list encodeItem xs)


decodeItem : D.Decoder ( Int, String, Bool )
decodeItem =
    D.map3 (\a b c -> ( a, b, c ))
        (D.index 0 D.int)
        (D.index 1 D.string)
        (D.index 2 D.bool)


decoder : D.Decoder (List ( Int, String, Bool ))
decoder =
    D.list decodeItem


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
            flags.numLoops // 8
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonRoundtripIndex"
        , run = run
        }
