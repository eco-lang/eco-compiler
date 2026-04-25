module BytesRoundtripListOfListsOfStrings exposing (main)

{-| Doubly-nested length-prefixed list: `BD.list (BD.list BD.string)`.
    Every leaf is a heap-allocated String, every inner list is a
    heap-allocated Cons chain, and the outer list captures a growing
    `List (List String)` in its loop state. This is the deepest nesting
    that `.ecoi` interface decoders produce.
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


innerLenMax : Int
innerLenMax =
    10


loopCount : Int
loopCount =
    n // 100


initialSeed : Seed
initialSeed =
    0xCAFEBABE


genString : Seed -> ( String, Seed )
genString seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 12 seed
    in
    Gen.asciiString len s1


genInner : Seed -> ( List String, Seed )
genInner seed =
    let
        ( len, s1 ) =
            Gen.intIn 0 innerLenMax seed
    in
    Gen.listOf len genString s1


gen : Seed -> ( List (List String), Seed )
gen seed =
    Gen.listOf m genInner seed


encodeString : String -> E.Encoder
encodeString s =
    let
        w =
            E.getStringWidth s
    in
    E.sequence [ E.unsignedInt16 BE w, E.string s ]


encodeInner : List String -> E.Encoder
encodeInner xs =
    E.sequence
        [ E.unsignedInt16 BE (List.length xs)
        , E.sequence (List.map encodeString xs)
        ]


encoder : List (List String) -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt16 BE (List.length xs)
        , E.sequence (List.map encodeInner xs)
        ]


decodeString : D.Decoder String
decodeString =
    D.unsignedInt16 BE |> D.andThen D.string


decodeInner : D.Decoder (List String)
decodeInner =
    D.unsignedInt16 BE
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


decoder : D.Decoder (List (List String))
decoder =
    D.unsignedInt16 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeInner |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
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
