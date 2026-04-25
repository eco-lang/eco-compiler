module JsonRoundtripKeyValuePairs exposing (main)

-- CHECK: roundtrip: True

import Dict
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


keyAt : Int -> String
keyAt i =
    "k" ++ String.fromInt i


gen : Seed -> ( List ( String, Int ), Seed )
gen seed =
    let
        go i s acc =
            if i <= 0 then
                ( List.reverse acc, s )

            else
                let
                    ( v, s2 ) =
                        Gen.int32 s
                in
                go (i - 1) s2 (( keyAt (m - i), v ) :: acc)
    in
    go m seed []


encoder : List ( String, Int ) -> String
encoder pairs =
    -- Use Dict as the intermediate so JSON key ordering is deterministic.
    E.encode 0 (E.dict identity E.int (Dict.fromList pairs))


decoder : D.Decoder (List ( String, Int ))
decoder =
    D.keyValuePairs D.int


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
                        List.sort v == List.sort original

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
