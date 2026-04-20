module JsonRoundtripInt exposing (main)

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


initialSeed : Seed
initialSeed =
    0x12345678


gen : Seed -> ( List Int, Seed )
gen seed =
    Gen.listOf m Gen.int32 seed


encoder : List Int -> String
encoder xs =
    E.encode 0 (E.list E.int xs)


decoder : D.Decoder (List Int)
decoder =
    D.list D.int


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
            loop initialSeed n True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
