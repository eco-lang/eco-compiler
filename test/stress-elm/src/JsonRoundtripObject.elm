module JsonRoundtripObject exposing (main)

-- CHECK: JsonRoundtripObject: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


type alias Rec =
    { id : Int
    , name : String
    , active : Bool
    , score : Float
    }


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( id, s1 ) =
            Gen.int32 seed

        ( len, s2 ) =
            Gen.intIn 0 10 s1

        ( name, s3 ) =
            Gen.asciiString len s2

        ( active, s4 ) =
            Gen.bool s3

        ( score, s5 ) =
            Gen.float s4
    in
    ( { id = id, name = name, active = active, score = score }, s5 )


gen : Int -> Seed -> ( List Rec, Seed )
gen size seed =
    Gen.listOf size genRec seed


encodeRec : Rec -> E.Value
encodeRec r =
    E.object
        [ ( "id", E.int r.id )
        , ( "name", E.string r.name )
        , ( "active", E.bool r.active )
        , ( "score", E.float r.score )
        ]


encoder : List Rec -> String
encoder xs =
    E.encode 0 (E.list encodeRec xs)


decodeRec : D.Decoder Rec
decodeRec =
    D.map4 Rec
        (D.field "id" D.int)
        (D.field "name" D.string)
        (D.field "active" D.bool)
        (D.field "score" D.float)


decoder : D.Decoder (List Rec)
decoder =
    D.list decodeRec


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
        { label = "JsonRoundtripObject"
        , run = run
        }
