module BytesRoundtripFloat32 exposing (main)

-- CHECK: BytesRoundtripFloat32: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


gen : Int -> Seed -> ( List Float, Seed )
gen size seed =
    Gen.listOf size Gen.float32Safe seed


encoder : List Float -> E.Encoder
encoder xs =
    E.sequence (List.map (E.float32 BE) xs)


decoder : Int -> D.Decoder (List Float)
decoder size =
    D.loop ( size, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.float32 BE |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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

        ok =
            case decoded of
                Just v ->
                    v == original

                Nothing ->
                    False
    in
    ( seed1, ok )


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
        { label = "BytesRoundtripFloat32"
        , run = run
        }
