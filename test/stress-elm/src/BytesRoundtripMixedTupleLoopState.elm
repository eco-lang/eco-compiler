module BytesRoundtripMixedTupleLoopState exposing (main)

{-| Loop state that mixes an unboxed primitive (`Int`) with a boxed heap
    value (`List String`) in the same tuple — exactly the shape of
    `Utils.Bytes.Decode.list`'s loop state `( Int, List a )`. The loop
    closure must therefore carry a mixed unboxed/boxed bitmap across
    iterations.

    Large iteration count forces minor GCs during the loop. Any bitmap
    mismatch corrupts either the counter or the accumulator — mismatches
    against `original` fail the roundtrip.
-}

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
    n // 20


initialSeed : Seed
initialSeed =
    0xA5A5A5A5


genString : Seed -> ( String, Seed )
genString seed =
    let
        ( len, s1 ) =
            Gen.intIn 2 12 seed
    in
    Gen.asciiString len s1


gen : Seed -> ( List String, Seed )
gen seed =
    Gen.listOf m genString seed


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


{-| The loop state `( Int, List String )` alternates the Int slot
    (remaining) and the boxed List slot (acc) on every iteration.
-}
decoder : D.Decoder (List String)
decoder =
    D.unsignedInt32 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\state ->
                        let
                            remaining =
                                Tuple.first state

                            acc =
                                Tuple.second state
                        in
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeString
                                |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
