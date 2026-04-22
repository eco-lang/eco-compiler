module BytesRoundtripListOfMaybeRecords exposing (main)

{-| Large version of the Maybe-in-list pattern: `BD.list (BD.maybe recDec)`
    with thousands of elements, so the embedded-constant `Nothing` and the
    heap-allocated `Just { ... }` both flow through the same
    partial-application slot across many minor GCs.

    Complements the small-input `DecodeListMaybeTest` in `elm-bytes/`:
    that one targets the immediate `eco_resolve_hptr` / pap-slot codegen
    path; this one keeps the same shapes alive long enough for the
    collector to scan them repeatedly.
-}

-- CHECK: roundtrip: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import Html exposing (text)


outerCount : Int
outerCount =
    5000


loopCount : Int
loopCount =
    3


initialSeed : Seed
initialSeed =
    0xBEEFCAFE


type alias Rec =
    { tag : Int, value : Int, label : String }


type alias Item =
    Maybe Rec


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( tag, s1 ) =
            Gen.uint8 seed

        ( v, s2 ) =
            Gen.int32 s1

        ( len, s3 ) =
            Gen.intIn 0 10 s2

        ( label, s4 ) =
            Gen.asciiString len s3
    in
    ( { tag = tag, value = v, label = label }, s4 )


genItem : Seed -> ( Item, Seed )
genItem seed =
    let
        ( bucket, s1 ) =
            Gen.intIn 0 2 seed
    in
    if bucket == 0 then
        ( Nothing, s1 )

    else
        let
            ( r, s2 ) =
                genRec s1
        in
        ( Just r, s2 )


gen : Seed -> ( List Item, Seed )
gen seed =
    Gen.listOf outerCount genItem seed


encodeRec : Rec -> E.Encoder
encodeRec r =
    let
        w =
            E.getStringWidth r.label
    in
    E.sequence
        [ E.unsignedInt8 r.tag
        , E.signedInt32 BE r.value
        , E.unsignedInt16 BE w
        , E.string r.label
        ]


encodeItem : Item -> E.Encoder
encodeItem m =
    case m of
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


type alias RecPrefix =
    { tag : Int, value : Int, len : Int }


decodeRec : D.Decoder Rec
decodeRec =
    D.map3 RecPrefix
        D.unsignedInt8
        (D.signedInt32 BE)
        (D.unsignedInt16 BE)
        |> D.andThen
            (\p ->
                D.string p.len
                    |> D.map (\label -> { tag = p.tag, value = p.value, label = label })
            )


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
