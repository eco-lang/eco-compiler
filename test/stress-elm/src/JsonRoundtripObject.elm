module JsonRoundtripObject exposing (main)

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


type alias Rec =
    { id : Int
    , name : String
    , active : Bool
    , score : Float
    }


genRec : Seed -> ( Rec, Seed )
genRec seed =
    let
        ( id, s1 ) =
            Gen.int32 seed

        ( len, s2 ) =
            Gen.intIn 0 10 s1

        ( name, s3 ) =
            Gen.asciiString len s2

        ( active, s4 ) =
            Gen.bool s3

        ( score, s5 ) =
            Gen.float s4
    in
    ( { id = id, name = name, active = active, score = score }, s5 )


gen : Seed -> ( List Rec, Seed )
gen seed =
    Gen.listOf m genRec seed


encodeRec : Rec -> E.Value
encodeRec r =
    E.object
        [ ( "id", E.int r.id )
        , ( "name", E.string r.name )
        , ( "active", E.bool r.active )
        , ( "score", E.float r.score )
        ]


encoder : List Rec -> String
encoder xs =
    E.encode 0 (E.list encodeRec xs)


decodeRec : D.Decoder Rec
decodeRec =
    D.map4 Rec
        (D.field "id" D.int)
        (D.field "name" D.string)
        (D.field "active" D.bool)
        (D.field "score" D.float)


decoder : D.Decoder (List Rec)
decoder =
    D.list decodeRec


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
