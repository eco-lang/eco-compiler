module JsonRoundtripOneOf exposing (main)

-- CHECK: JsonRoundtripOneOf: True

import Gen exposing (Seed)
import Json.Decode as D
import Json.Encode as E
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0x12345678


type Variant
    = VLeft Int
    | VRight String
    | VPair Int Int


genVariant : Seed -> ( Variant, Seed )
genVariant seed =
    let
        ( tag, s1 ) =
            Gen.intIn 0 2 seed
    in
    case tag of
        0 ->
            let
                ( v, s2 ) =
                    Gen.int32 s1
            in
            ( VLeft v, s2 )

        1 ->
            let
                ( len, s2 ) =
                    Gen.intIn 0 8 s1

                ( v, s3 ) =
                    Gen.asciiString len s2
            in
            ( VRight v, s3 )

        _ ->
            let
                ( a, s2 ) =
                    Gen.int32 s1

                ( b, s3 ) =
                    Gen.int32 s2
            in
            ( VPair a b, s3 )


gen : Int -> Seed -> ( List Variant, Seed )
gen size seed =
    Gen.listOf size genVariant seed


encodeVariant : Variant -> E.Value
encodeVariant v =
    case v of
        VLeft x ->
            E.object [ ( "left", E.int x ) ]

        VRight x ->
            E.object [ ( "right", E.string x ) ]

        VPair a b ->
            E.object [ ( "pair", E.list E.int [ a, b ] ) ]


encoder : List Variant -> String
encoder xs =
    E.encode 0 (E.list encodeVariant xs)


decodeVariant : D.Decoder Variant
decodeVariant =
    D.oneOf
        [ D.field "left" D.int |> D.map VLeft
        , D.field "right" D.string |> D.map VRight
        , D.field "pair"
            (D.map2 VPair
                (D.index 0 D.int)
                (D.index 1 D.int)
            )
        ]


decoder : D.Decoder (List Variant)
decoder =
    D.list decodeVariant


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
            flags.numLoops // 4
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "JsonRoundtripOneOf"
        , run = run
        }
