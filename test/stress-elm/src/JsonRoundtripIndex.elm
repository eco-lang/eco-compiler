module JsonRoundtripIndex exposing (main)

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
    n // 8


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( ( Int, String, Bool ), Seed )
genItem seed =
    let
        ( i, s1 ) =
            Gen.int32 seed

        ( len, s2 ) =
            Gen.intIn 0 8 s1

        ( str, s3 ) =
            Gen.asciiString len s2

        ( b, s4 ) =
            Gen.bool s3
    in
    ( ( i, str, b ), s4 )


gen : Seed -> ( List ( Int, String, Bool ), Seed )
gen seed =
    Gen.listOf m genItem seed


encodeItem : ( Int, String, Bool ) -> E.Value
encodeItem ( i, s, b ) =
    E.list identity
        [ E.int i
        , E.string s
        , E.bool b
        ]


encoder : List ( Int, String, Bool ) -> String
encoder xs =
    E.encode 0 (E.list encodeItem xs)


decodeItem : D.Decoder ( Int, String, Bool )
decodeItem =
    D.map3 (\a b c -> ( a, b, c ))
        (D.index 0 D.int)
        (D.index 1 D.string)
        (D.index 2 D.bool)


decoder : D.Decoder (List ( Int, String, Bool ))
decoder =
    D.list decodeItem


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
