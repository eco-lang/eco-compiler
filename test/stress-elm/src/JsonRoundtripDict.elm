module JsonRoundtripDict exposing (main)

-- CHECK: JsonRoundtripDict: True

import Dict exposing (Dict)
import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


keyAt : Int -> String
keyAt i =
    "k" ++ String.fromInt i


genEntry : Int -> Seed -> ( ( String, Int ), Seed )
genEntry i seed =
    let
        ( v, s1 ) =
            Gen.int32 seed
    in
    ( ( keyAt i, v ), s1 )


genEntries : Int -> Seed -> ( List ( String, Int ), Seed )
genEntries size seed =
    let
        go i s acc =
            if i <= 0 then
                ( List.reverse acc, s )

            else
                let
                    ( pair, s2 ) =
                        genEntry (size - i) s
                in
                go (i - 1) s2 (pair :: acc)
    in
    go size seed []


gen : Int -> Seed -> ( Dict String Int, Seed )
gen size seed =
    let
        ( pairs, s1 ) =
            genEntries size seed
    in
    ( Dict.fromList pairs, s1 )


encoder : Dict String Int -> String
encoder d =
    E.encode 0 (E.dict identity E.int d)


decoder : D.Decoder (Dict String Int)
decoder =
    D.dict D.int


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
        { label = "JsonRoundtripDict"
        , run = run
        }
