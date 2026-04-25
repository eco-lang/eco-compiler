module JsonRoundtripOneOf exposing (main)

-- CHECK: roundtrip: True

import Gen exposing (Seed)
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


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


gen : Seed -> ( List Variant, Seed )
gen seed =
    Gen.listOf m genVariant seed


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


loop : Seed -> Int -> Bool -> Bool
loop seed count ok =
    if count <= 0 then
        ok

    else
        let
            ( original, seed1 ) =
                gen seed

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
        loop seed1 (count - 1) (ok && ok2)


main =
    let
        result =
            loop initialSeed loopCount True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
