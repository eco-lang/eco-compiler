module DiagBytesString exposing (main)

-- CHECK: DiagBytesString: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
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
    Gen.asciiString len s1


gen : Int -> Seed -> ( List String, Seed )
gen size seed =
    Gen.listOf size genItem seed


encodeOne : String -> E.Encoder
encodeOne s =
    E.sequence
        [ E.unsignedInt16 BE (E.getStringWidth s)
        , E.string s
        ]


encoder : List String -> E.Encoder
encoder xs =
    E.sequence (List.map encodeOne xs)


decodeOne : D.Decoder String
decodeOne =
    D.unsignedInt16 BE |> D.andThen D.string


decoder : Int -> D.Decoder (List String)
decoder size =
    D.loop ( size, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeOne |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
        )


cycleStep : Int -> Seed -> ( Seed, Bool )
cycleStep size seed =
    let
            ( original, seed1 ) =
                gen size seed

            encoded =
                E.encode (encoder original)

            decoded =
                D.decode (decoder size) encoded

            ok2 =
                case decoded of
                    Just v ->
                        v == original

                    Nothing ->
                        False

    in
    ( seed1, ok2 )


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 200
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DiagBytesString"
        , run = run
        }
