module BytesRoundtripNestedBytes exposing (main)

-- CHECK: BytesRoundtripNestedBytes: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( List Int, Seed )
genItem seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 16 seed
    in
    Gen.listOf len Gen.uint8 s1


gen : Int -> Seed -> ( List (List Int), Seed )
gen size seed =
    Gen.listOf size genItem seed


encodeItem : List Int -> E.Encoder
encodeItem bs =
    let
        inner =
            E.encode (E.sequence (List.map E.unsignedInt8 bs))

        width =
            Bytes.width inner
    in
    E.sequence
        [ E.unsignedInt16 BE width
        , E.bytes inner
        ]


encoder : List (List Int) -> E.Encoder
encoder xs =
    E.sequence (List.map encodeItem xs)


decodeU8s : Int -> D.Decoder (List Int)
decodeU8s w =
    D.loop ( w, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.unsignedInt8 |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
        )


decodeItem : D.Decoder (List Int)
decodeItem =
    D.unsignedInt16 BE
        |> D.andThen
            (\w ->
                D.bytes w
                    |> D.andThen
                        (\b ->
                            case D.decode (decodeU8s w) b of
                                Just xs ->
                                    D.succeed xs

                                Nothing ->
                                    D.fail
                        )
            )


decoder : Int -> D.Decoder (List (List Int))
decoder size =
    D.loop ( size, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeItem |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
            flags.numLoops // 30
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "BytesRoundtripNestedBytes"
        , run = run
        }
