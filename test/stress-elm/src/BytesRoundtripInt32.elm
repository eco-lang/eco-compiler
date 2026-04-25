module BytesRoundtripInt32 exposing (main)

-- CHECK: BytesRoundtripInt32: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


gen : Int -> Seed -> ( List Int, Seed )
gen size seed =
    Gen.listOf size Gen.int32 seed


encoder : List Int -> E.Encoder
encoder xs =
    E.sequence (List.map (E.signedInt32 BE) xs)


decoder : Int -> D.Decoder (List Int)
decoder size =
    D.loop ( size, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.signedInt32 BE |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
            flags.numLoops // 2
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "BytesRoundtripInt32"
        , run = run
        }
