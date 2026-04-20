module BytesRoundtripInt16Mixed exposing (main)

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


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( ( Bool, Int ), Seed )
genItem seed =
    let
        ( isBE, s1 ) =
            Gen.bool seed

        ( v, s2 ) =
            Gen.int16 s1
    in
    ( ( isBE, v ), s2 )


gen : Seed -> ( List ( Bool, Int ), Seed )
gen seed =
    Gen.listOf m genItem seed


encoder : List ( Bool, Int ) -> E.Encoder
encoder xs =
    E.sequence
        (List.map
            (\( isBE, v ) ->
                E.sequence
                    [ E.unsignedInt8
                        (if isBE then
                            0

                         else
                            1
                        )
                    , if isBE then
                        E.signedInt16 BE v

                      else
                        E.signedInt16 LE v
                    ]
            )
            xs
        )


decodeOne : D.Decoder ( Bool, Int )
decodeOne =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                if tag == 0 then
                    D.signedInt16 BE |> D.map (\v -> ( True, v ))

                else if tag == 1 then
                    D.signedInt16 LE |> D.map (\v -> ( False, v ))

                else
                    D.fail
            )


decoder : D.Decoder (List ( Bool, Int ))
decoder =
    D.loop ( m, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                decodeOne |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
            loop initialSeed n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
