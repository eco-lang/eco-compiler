module JsonRoundtripNullable exposing (main)

-- CHECK: JsonRoundtripNullable: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( Maybe Int, Seed )
genItem seed =
    let
        ( isNull, s1 ) =
            Gen.intIn 0 3 seed
    in
    if isNull == 0 then
        ( Nothing, s1 )

    else
        let
            ( v, s2 ) =
                Gen.int32 s1
        in
        ( Just v, s2 )


gen : Int -> Seed -> ( List (Maybe Int), Seed )
gen size seed =
    Gen.listOf size genItem seed


encodeItem : Maybe Int -> E.Value
encodeItem mv =
    case mv of
        Just v ->
            E.int v

        Nothing ->
            E.null


encoder : List (Maybe Int) -> String
encoder xs =
    E.encode 0 (E.list encodeItem xs)


decoder : D.Decoder (List (Maybe Int))
decoder =
    D.list (D.nullable D.int)


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
            flags.numLoops // 2
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonRoundtripNullable"
        , run = run
        }
