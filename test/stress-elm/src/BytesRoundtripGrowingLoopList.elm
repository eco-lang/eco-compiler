module BytesRoundtripGrowingLoopList exposing (main)

{-| `BD.loop (n, []) step` where the accumulator keeps growing across
    iterations. Every iteration the loop-state tuple retains all previously
    decoded Strings, so the full accumulator must survive every mid-loop
    minor GC. If evacuation copies the Cons spine without updating the
    growing-list pointer in the loop closure, the roundtrip comparison
    will fail.
-}

-- CHECK: roundtrip: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import Html exposing (text)


listLen : Int
listLen =
    5000


loopCount : Int
loopCount =
    2


initialSeed : Seed
initialSeed =
    0xFEEDFACE


genString : Seed -> ( String, Seed )
genString seed =
    let
        ( len, s1 ) =
            Gen.intIn 1 8 seed
    in
    Gen.asciiString len s1


gen : Seed -> ( List String, Seed )
gen seed =
    Gen.listOf listLen genString seed


encodeString : String -> E.Encoder
encodeString s =
    let
        w =
            E.getStringWidth s
    in
    E.sequence [ E.unsignedInt16 BE w, E.string s ]


encoder : List String -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt32 BE (List.length xs)
        , E.sequence (List.map encodeString xs)
        ]


decodeString : D.Decoder String
decodeString =
    D.unsignedInt16 BE |> D.andThen D.string


decoder : D.Decoder (List String)
decoder =
    D.unsignedInt32 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeString |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
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
