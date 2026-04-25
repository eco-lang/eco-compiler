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

-- CHECK: roundtrip: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 20


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


gen : Seed -> ( List Rec, Seed )
gen seed =
    Gen.listOf m genRec seed


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


loop : Seed -> Int -> Bool -> Bool
loop seed count ok =
    if count <= 0 then
        ok

    else
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
        loop seed1 (count - 1) (ok && ok2)


main =
    let
        result =
            loop initialSeed loopCount True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
