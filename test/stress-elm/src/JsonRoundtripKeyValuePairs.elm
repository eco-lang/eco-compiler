module JsonRoundtripKeyValuePairs exposing (main)

-- CHECK: JsonRoundtripKeyValuePairs: True

import Dict
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


gen : Int -> Seed -> ( List ( String, Int ), Seed )
gen size seed =
    let
        go i s acc =
            if i <= 0 then
                ( List.reverse acc, s )

            else
                let
                    ( v, s2 ) =
                        Gen.int32 s
                in
                go (i - 1) s2 (( keyAt (size - i), v ) :: acc)
    in
    go size seed []


encoder : List ( String, Int ) -> String
encoder pairs =
    -- Use Dict as the intermediate so JSON key ordering is deterministic.
    E.encode 0 (E.dict identity E.int (Dict.fromList pairs))


decoder : D.Decoder (List ( String, Int ))
decoder =
    D.keyValuePairs D.int


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
                        List.sort v == List.sort original

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
        { label = "JsonRoundtripKeyValuePairs"
        , run = run
        }
