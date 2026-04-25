module DiagBytesString exposing (main)

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
    n // 200


initialSeed : Seed
initialSeed =
    0x12345678


genItem : Seed -> ( String, Seed )
genItem seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 20 seed
    in
    Gen.asciiString len s1


gen : Seed -> ( List String, Seed )
gen seed =
    Gen.listOf m genItem seed


encodeOne : String -> E.Encoder
encodeOne s =
    E.sequence
        [ E.unsignedInt16 BE (E.getStringWidth s)
        , E.string s
        ]


encoder : List String -> E.Encoder
encoder xs =
    E.sequence (List.map encodeOne xs)


decodeOne : D.Decoder String
decodeOne =
    D.unsignedInt16 BE |> D.andThen D.string


decoder : D.Decoder (List String)
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

            _ =
                Debug.log "iter" count

            _ =
                Debug.log "original" original

            _ =
                Debug.log "decoded" decoded
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
