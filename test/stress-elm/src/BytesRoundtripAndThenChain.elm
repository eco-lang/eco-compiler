module BytesRoundtripAndThenChain exposing (main)

{-| A deep `andThen` chain that sequentially produces six fields and then
    assembles them into a record. Each `andThen` allocates a new
    partial-application closure (via `eco_pap_extend`) that captures every
    value decoded so far. Running the resulting decoder thousands of times
    inside a length-prefixed list forces the pap-extend path to reuse
    closure shapes heavily, so nursery pressure triggers GCs while a
    deep capture chain is live.
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
    0x1234ABCD


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    , d : Int
    , e : Int
    , f : Int
    }


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( a, s1 ) =
            Gen.uint8 seed

        ( b, s2 ) =
            Gen.uint16 s1

        ( c, s3 ) =
            Gen.int32 s2

        ( d, s4 ) =
            Gen.uint8 s3

        ( e, s5 ) =
            Gen.uint16 s4

        ( f, s6 ) =
            Gen.int32 s5
    in
    ( { a = a, b = b, c = c, d = d, e = e, f = f }, s6 )


gen : Seed -> ( List Rec, Seed )
gen seed =
    Gen.listOf m genRec seed


encodeRec : Rec -> E.Encoder
encodeRec r =
    E.sequence
        [ E.unsignedInt8 r.a
        , E.unsignedInt16 BE r.b
        , E.signedInt32 BE r.c
        , E.unsignedInt8 r.d
        , E.unsignedInt16 BE r.e
        , E.signedInt32 BE r.f
        ]


encoder : List Rec -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt32 BE (List.length xs)
        , E.sequence (List.map encodeRec xs)
        ]


{-| Six-deep `andThen` chain. Every step captures all previously decoded
    fields in its closure before decoding the next.
-}
decodeRec : D.Decoder Rec
decodeRec =
    D.unsignedInt8
        |> D.andThen
            (\a ->
                D.unsignedInt16 BE
                    |> D.andThen
                        (\b ->
                            D.signedInt32 BE
                                |> D.andThen
                                    (\c ->
                                        D.unsignedInt8
                                            |> D.andThen
                                                (\d ->
                                                    D.unsignedInt16 BE
                                                        |> D.andThen
                                                            (\e ->
                                                                D.signedInt32 BE
                                                                    |> D.map
                                                                        (\f ->
                                                                            { a = a, b = b, c = c, d = d, e = e, f = f }
                                                                        )
                                                            )
                                                )
                                    )
                        )
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
