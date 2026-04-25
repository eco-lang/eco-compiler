module BytesRoundtripPapReuse exposing (main)

{-| A single `map5`-built decoder is constructed once and then threaded
    through `BD.list` many times. Every list iteration re-enters the same
    five-step `eco_pap_extend` chain, so the underlying pap cells are
    repeatedly allocated, filled, and abandoned — a focused stress on the
    allocator's fast-path for reused closure shapes.

    Wraps the result in a `Maybe`-style tag to interleave a small number
    of `Nothing` (embedded-constant) values inside the same list, so the
    same decoder sees both boxed and constant outcomes per iteration.
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
    0xF00DBABE


type alias Rec =
    { a : Int, b : Int, c : Int, d : Int, e : Int }


type alias Item =
    Maybe Rec


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( a, s1 ) =
            Gen.uint8 seed

        ( b, s2 ) =
            Gen.uint8 s1

        ( c, s3 ) =
            Gen.uint16 s2

        ( d, s4 ) =
            Gen.uint16 s3

        ( e, s5 ) =
            Gen.int32 s4
    in
    ( { a = a, b = b, c = c, d = d, e = e }, s5 )


genItem : Seed -> ( Item, Seed )
genItem seed =
    let
        ( tag, s1 ) =
            Gen.intIn 0 3 seed
    in
    if tag == 0 then
        ( Nothing, s1 )

    else
        let
            ( r, s2 ) =
                genRec s1
        in
        ( Just r, s2 )


gen : Seed -> ( List Item, Seed )
gen seed =
    Gen.listOf m genItem seed


encodeRec : Rec -> E.Encoder
encodeRec r =
    E.sequence
        [ E.unsignedInt8 r.a
        , E.unsignedInt8 r.b
        , E.unsignedInt16 BE r.c
        , E.unsignedInt16 BE r.d
        , E.signedInt32 BE r.e
        ]


encodeItem : Item -> E.Encoder
encodeItem item =
    case item of
        Nothing ->
            E.unsignedInt8 0

        Just r ->
            E.sequence [ E.unsignedInt8 1, encodeRec r ]


encoder : List Item -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt32 BE (List.length xs)
        , E.sequence (List.map encodeItem xs)
        ]


{-| Built once at module scope — shared across every list iteration. -}
decodeRec : D.Decoder Rec
decodeRec =
    D.map5 Rec
        D.unsignedInt8
        D.unsignedInt8
        (D.unsignedInt16 BE)
        (D.unsignedInt16 BE)
        (D.signedInt32 BE)


decodeItem : D.Decoder Item
decodeItem =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                if tag == 0 then
                    D.succeed Nothing

                else
                    D.map Just decodeRec
            )


decoder : D.Decoder (List Item)
decoder =
    D.unsignedInt32 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeItem |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
