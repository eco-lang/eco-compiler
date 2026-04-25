module BytesRoundtripNestedList exposing (main)

-- CHECK: BytesRoundtripNestedList: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


{-| Outer list of ~sqrt(m) entries; each inner list holds up to ~sqrt(m) u8 values. -}
outerLen : Int
outerLen =
    32


genInner : Seed -> ( List Int, Seed )
genInner seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 32 seed
    in
    Gen.listOf len Gen.uint8 s1


gen : Seed -> ( List (List Int), Seed )
gen seed =
    Gen.listOf outerLen genInner seed


encodeInner : List Int -> E.Encoder
encodeInner xs =
    E.sequence
        [ E.unsignedInt16 BE (List.length xs)
        , E.sequence (List.map E.unsignedInt8 xs)
        ]


encoder : List (List Int) -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt16 BE (List.length xs)
        , E.sequence (List.map encodeInner xs)
        ]


decodeInner : D.Decoder (List Int)
decodeInner =
    D.unsignedInt16 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.unsignedInt8 |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
            )


decoder : D.Decoder (List (List Int))
decoder =
    D.unsignedInt16 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeInner |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
            )


cycleStep : Int -> Seed -> ( Seed, Bool )
cycleStep size seed =
    let
            ( original, seed1 ) =
                gen seed

            encoded =
                E.encode (encoder original)

            decoded =
                D.decode decoder encoded

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
        { label = "BytesRoundtripNestedList"
        , run = run
        }
