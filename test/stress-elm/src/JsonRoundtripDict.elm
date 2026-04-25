module JsonRoundtripDict exposing (main)

-- CHECK: roundtrip: True

import Dict exposing (Dict)
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


genEntry : Int -> Seed -> ( ( String, Int ), Seed )
genEntry i seed =
    let
        ( v, s1 ) =
            Gen.int32 seed
    in
    ( ( keyAt i, v ), s1 )


genEntries : Seed -> ( List ( String, Int ), Seed )
genEntries seed =
    let
        go i s acc =
            if i <= 0 then
                ( List.reverse acc, s )

            else
                let
                    ( pair, s2 ) =
                        genEntry (m - i) s
                in
                go (i - 1) s2 (pair :: acc)
    in
    go m seed []


gen : Seed -> ( Dict String Int, Seed )
gen seed =
    let
        ( pairs, s1 ) =
            genEntries seed
    in
    ( Dict.fromList pairs, s1 )


encoder : Dict String Int -> String
encoder d =
    E.encode 0 (E.dict identity E.int d)


decoder : D.Decoder (Dict String Int)
decoder =
    D.dict D.int


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
