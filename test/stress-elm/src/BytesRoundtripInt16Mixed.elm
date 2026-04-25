module BytesRoundtripInt16Mixed exposing (main)

-- CHECK: BytesRoundtripInt16Mixed: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( ( Bool, Int ), Seed )
genItem seed =
    let
        ( isBE, s1 ) =
            Gen.bool seed

        ( v, s2 ) =
            Gen.int16 s1
    in
    ( ( isBE, v ), s2 )


gen : Int -> Seed -> ( List ( Bool, Int ), Seed )
gen size seed =
    Gen.listOf size genItem seed


encoder : List ( Bool, Int ) -> E.Encoder
encoder xs =
    E.sequence
        (List.map
            (\( isBE, v ) ->
                E.sequence
                    [ E.unsignedInt8
                        (if isBE then
                            0

                         else
                            1
                        )
                    , if isBE then
                        E.signedInt16 BE v

                      else
                        E.signedInt16 LE v
                    ]
            )
            xs
        )


decodeOne : D.Decoder ( Bool, Int )
decodeOne =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                if tag == 0 then
                    D.signedInt16 BE |> D.map (\v -> ( True, v ))

                else if tag == 1 then
                    D.signedInt16 LE |> D.map (\v -> ( False, v ))

                else
                    D.fail
            )


decoder : Int -> D.Decoder (List ( Bool, Int ))
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
            flags.numLoops // 4
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "BytesRoundtripInt16Mixed"
        , run = run
        }
