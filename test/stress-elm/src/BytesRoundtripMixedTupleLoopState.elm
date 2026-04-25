module BytesRoundtripMixedTupleLoopState exposing (main)

{-| Loop state that mixes an unboxed primitive (`Int`) with a boxed heap
    value (`List String`) in the same tuple — exactly the shape of
    `Utils.Bytes.Decode.list`'s loop state `( Int, List a )`. The loop
    closure must therefore carry a mixed unboxed/boxed bitmap across
    iterations.

    Large iteration count forces minor GCs during the loop. Any bitmap
    mismatch corrupts either the counter or the accumulator — mismatches
    against `original` fail the roundtrip.
-}

-- CHECK: BytesRoundtripMixedTupleLoopState: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0xA5A5A5A5


genString : Seed -> ( String, Seed )
genString seed =
    let
        ( len, s1 ) =
            Gen.intIn 2 12 seed
    in
    Gen.asciiString len s1


gen : Int -> Seed -> ( List String, Seed )
gen size seed =
    Gen.listOf size genString seed


encodeString : String -> E.Encoder
encodeString s =
    let
        w =
            E.getStringWidth s
    in
    E.sequence [ E.unsignedInt16 BE w, E.string s ]


encoder : List String -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt32 BE (List.length xs)
        , E.sequence (List.map encodeString xs)
        ]


decodeString : D.Decoder String
decodeString =
    D.unsignedInt16 BE |> D.andThen D.string


{-| The loop state `( Int, List String )` alternates the Int slot
    (remaining) and the boxed List slot (acc) on every iteration.
-}
decoder : D.Decoder (List String)
decoder =
    D.unsignedInt32 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\state ->
                        let
                            remaining =
                                Tuple.first state

                            acc =
                                Tuple.second state
                        in
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeString
                                |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
            )


cycleStep : Int -> Seed -> ( Seed, Bool )
cycleStep size seed =
    let
            ( original, seed1 ) =
                gen size seed

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
            flags.numLoops // 20
    in
    StressHarness.loopWhileState flags
        loopCount
        initialSeed
        (\_ s -> Task.succeed (cycleStep flags.maxSize s))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "BytesRoundtripMixedTupleLoopState"
        , run = run
        }
