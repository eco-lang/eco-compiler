module JsonRoundtripNullable exposing (main)

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
    n // 2


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( Maybe Int, Seed )
genItem seed =
    let
        ( isNull, s1 ) =
            Gen.intIn 0 3 seed
    in
    if isNull == 0 then
        ( Nothing, s1 )

    else
        let
            ( v, s2 ) =
                Gen.int32 s1
        in
        ( Just v, s2 )


gen : Seed -> ( List (Maybe Int), Seed )
gen seed =
    Gen.listOf m genItem seed


encodeItem : Maybe Int -> E.Value
encodeItem mv =
    case mv of
        Just v ->
            E.int v

        Nothing ->
            E.null


encoder : List (Maybe Int) -> String
encoder xs =
    E.encode 0 (E.list encodeItem xs)


decoder : D.Decoder (List (Maybe Int))
decoder =
    D.list (D.nullable D.int)


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
