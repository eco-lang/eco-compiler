module BytesRoundtripListOfRecords exposing (main)

{-| Length-prefixed `BD.list` of multi-field records (mixed primitive and
    heap fields). Mirrors how `Utils.Bytes.Decode.list` is used in the
    compiler to deserialize `.ecoi` interface caches: every iteration
    allocates a record plus an inner String, so the nursery fills quickly
    and minor GCs fire in the middle of the decode loop.

    If a captured partial-application slot or the loop-state tuple
    `( Int, List Rec )` is scanned with the wrong unboxed bitmap, the
    roundtrip comparison will fail (silent corruption) or the process
    will segfault during Cheney scan.
-}

-- CHECK: BytesRoundtripListOfRecords: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import StressHarness exposing (StressFlags)
import Task


initialSeed : Seed
initialSeed =
    0xDEADBEEF


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    , name : String
    }


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( a, s1 ) =
            Gen.int32 seed

        ( b, s2 ) =
            Gen.uint16 s1

        ( c, s3 ) =
            Gen.uint8 s2

        ( len, s4 ) =
            Gen.intIn 0 10 s3

        ( name, s5 ) =
            Gen.asciiString len s4
    in
    ( { a = a, b = b, c = c, name = name }, s5 )


gen : Int -> Seed -> ( List Rec, Seed )
gen size seed =
    Gen.listOf size genRec seed


encodeRec : Rec -> E.Encoder
encodeRec r =
    let
        width =
            E.getStringWidth r.name
    in
    E.sequence
        [ E.signedInt32 BE r.a
        , E.unsignedInt16 BE r.b
        , E.unsignedInt8 r.c
        , E.unsignedInt16 BE width
        , E.string r.name
        ]


encoder : List Rec -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt32 BE (List.length xs)
        , E.sequence (List.map encodeRec xs)
        ]


type alias RecPrefix =
    { a : Int, b : Int, c : Int, len : Int }


decodeRec : D.Decoder Rec
decodeRec =
    D.map4 RecPrefix
        (D.signedInt32 BE)
        (D.unsignedInt16 BE)
        D.unsignedInt8
        (D.unsignedInt16 BE)
        |> D.andThen
            (\p ->
                D.string p.len
                    |> D.map (\name -> { a = p.a, b = p.b, c = p.c, name = name })
            )


decoder : D.Decoder (List Rec)
decoder =
    D.unsignedInt32 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeRec |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
        { label = "BytesRoundtripListOfRecords"
        , run = run
        }
