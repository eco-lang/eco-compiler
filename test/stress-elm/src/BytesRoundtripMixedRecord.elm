module BytesRoundtripMixedRecord exposing (main)

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
    n // 4


initialSeed : Seed
initialSeed =
    0x12345678


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    , d : Float
    , e : String
    }


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( a, s1 ) =
            Gen.int8 seed

        ( b, s2 ) =
            Gen.uint16 s1

        ( c, s3 ) =
            Gen.int32 s2

        ( d, s4 ) =
            Gen.float32Safe s3

        ( len, s5 ) =
            Gen.intIn 0 12 s4

        ( e, s6 ) =
            Gen.asciiString len s5
    in
    ( { a = a, b = b, c = c, d = d, e = e }, s6 )


gen : Seed -> ( List Rec, Seed )
gen seed =
    Gen.listOf m genRec seed


encodeRec : Rec -> E.Encoder
encodeRec r =
    let
        width =
            E.getStringWidth r.e
    in
    E.sequence
        [ E.signedInt8 r.a
        , E.unsignedInt16 BE r.b
        , E.signedInt32 LE r.c
        , E.float32 BE r.d
        , E.unsignedInt16 BE width
        , E.string r.e
        ]


encoder : List Rec -> E.Encoder
encoder xs =
    E.sequence (List.map encodeRec xs)


type alias Prefix =
    { a : Int
    , b : Int
    , c : Int
    , d : Float
    , len : Int
    }


decodeRec : D.Decoder Rec
decodeRec =
    D.map5 Prefix
        D.signedInt8
        (D.unsignedInt16 BE)
        (D.signedInt32 LE)
        (D.float32 BE)
        (D.unsignedInt16 BE)
        |> D.andThen
            (\p ->
                D.string p.len
                    |> D.map (\e -> { a = p.a, b = p.b, c = p.c, d = p.d, e = e })
            )


decoder : D.Decoder (List Rec)
decoder =
    D.loop ( m, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeRec |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
