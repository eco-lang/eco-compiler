module BytesRoundtripUIntMixed exposing (main)

-- CHECK: BytesRoundtripUIntMixed: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


type Item
    = U8 Int
    | U16 Int
    | U32 Int


genItem : Seed -> ( Item, Seed )
genItem seed =
    let
        ( tag, s1 ) =
            Gen.intIn 0 2 seed
    in
    case tag of
        0 ->
            let
                ( v, s2 ) =
                    Gen.uint8 s1
            in
            ( U8 v, s2 )

        1 ->
            let
                ( v, s2 ) =
                    Gen.uint16 s1
            in
            ( U16 v, s2 )

        _ ->
            let
                ( v, s2 ) =
                    Gen.uint32 s1
            in
            ( U32 v, s2 )


gen : Int -> Seed -> ( List Item, Seed )
gen size seed =
    Gen.listOf size genItem seed


encodeItem : Item -> E.Encoder
encodeItem item =
    case item of
        U8 v ->
            E.sequence [ E.unsignedInt8 0, E.unsignedInt8 v ]

        U16 v ->
            E.sequence [ E.unsignedInt8 1, E.unsignedInt16 BE v ]

        U32 v ->
            E.sequence [ E.unsignedInt8 2, E.unsignedInt32 BE v ]


encoder : List Item -> E.Encoder
encoder xs =
    E.sequence (List.map encodeItem xs)


decodeItem : D.Decoder Item
decodeItem =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                case tag of
                    0 ->
                        D.unsignedInt8 |> D.map U8

                    1 ->
                        D.unsignedInt16 BE |> D.map U16

                    2 ->
                        D.unsignedInt32 BE |> D.map U32

                    _ ->
                        D.fail
            )


decoder : Int -> D.Decoder (List Item)
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
            flags.numLoops // 4
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "BytesRoundtripUIntMixed"
        , run = run
        }
