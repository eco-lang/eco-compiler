module BytesRoundtripTaggedUnion exposing (main)

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


type Variant
    = VA Int
    | VB Float
    | VC String
    | VD Bool


genVariant : Seed -> ( Variant, Seed )
genVariant seed =
    let
        ( tag, s1 ) =
            Gen.intIn 0 3 seed
    in
    case tag of
        0 ->
            let
                ( v, s2 ) =
                    Gen.int32 s1
            in
            ( VA v, s2 )

        1 ->
            let
                ( v, s2 ) =
                    Gen.float32Safe s1
            in
            ( VB v, s2 )

        2 ->
            let
                ( len, s2 ) =
                    Gen.intIn 0 10 s1

                ( v, s3 ) =
                    Gen.asciiString len s2
            in
            ( VC v, s3 )

        _ ->
            let
                ( v, s2 ) =
                    Gen.bool s1
            in
            ( VD v, s2 )


gen : Seed -> ( List Variant, Seed )
gen seed =
    Gen.listOf m genVariant seed


encodeVariant : Variant -> E.Encoder
encodeVariant v =
    case v of
        VA x ->
            E.sequence [ E.unsignedInt8 0, E.signedInt32 BE x ]

        VB x ->
            E.sequence [ E.unsignedInt8 1, E.float32 BE x ]

        VC x ->
            E.sequence
                [ E.unsignedInt8 2
                , E.unsignedInt16 BE (E.getStringWidth x)
                , E.string x
                ]

        VD x ->
            E.sequence
                [ E.unsignedInt8 3
                , E.unsignedInt8
                    (if x then
                        1

                     else
                        0
                    )
                ]


encoder : List Variant -> E.Encoder
encoder xs =
    E.sequence (List.map encodeVariant xs)


decodeVariant : D.Decoder Variant
decodeVariant =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                case tag of
                    0 ->
                        D.signedInt32 BE |> D.map VA

                    1 ->
                        D.float32 BE |> D.map VB

                    2 ->
                        D.unsignedInt16 BE
                            |> D.andThen (\w -> D.string w |> D.map VC)

                    3 ->
                        D.unsignedInt8 |> D.map (\b -> VD (b == 1))

                    _ ->
                        D.fail
            )


decoder : D.Decoder (List Variant)
decoder =
    D.loop ( m, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeVariant |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
