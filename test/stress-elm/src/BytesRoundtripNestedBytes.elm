module BytesRoundtripNestedBytes exposing (main)

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
    n // 30


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( List Int, Seed )
genItem seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 16 seed
    in
    Gen.listOf len Gen.uint8 s1


gen : Seed -> ( List (List Int), Seed )
gen seed =
    Gen.listOf m genItem seed


encodeItem : List Int -> E.Encoder
encodeItem bs =
    let
        inner =
            E.encode (E.sequence (List.map E.unsignedInt8 bs))

        width =
            Bytes.width inner
    in
    E.sequence
        [ E.unsignedInt16 BE width
        , E.bytes inner
        ]


encoder : List (List Int) -> E.Encoder
encoder xs =
    E.sequence (List.map encodeItem xs)


decodeU8s : Int -> D.Decoder (List Int)
decodeU8s w =
    D.loop ( w, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.unsignedInt8 |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
        )


decodeItem : D.Decoder (List Int)
decodeItem =
    D.unsignedInt16 BE
        |> D.andThen
            (\w ->
                D.bytes w
                    |> D.andThen
                        (\b ->
                            case D.decode (decodeU8s w) b of
                                Just xs ->
                                    D.succeed xs

                                Nothing ->
                                    D.fail
                        )
            )


decoder : D.Decoder (List (List Int))
decoder =
    D.loop ( m, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeItem |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
