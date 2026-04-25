module JsonRoundtripString exposing (main)

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


genItem : Seed -> ( String, Seed )
genItem seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 20 seed
    in
    Gen.unicodeString len s1


gen : Seed -> ( List String, Seed )
gen seed =
    Gen.listOf m genItem seed


encoder : List String -> String
encoder xs =
    E.encode 0 (E.list E.string xs)


decoder : D.Decoder (List String)
decoder =
    D.list D.string


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
