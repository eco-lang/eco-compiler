module Base64 exposing (bench)

{-| Base64 (RFC 4648; kostya/benchmarks): encode a generated `Bytes` buffer of `n` bytes to Base64
text, and decode the text back to `Bytes`. The bytes are read with a `Decode.loop` over
`unsignedInt8` (which eco fuses) and written with `Encode.sequence` of `unsignedInt8`s; in
between, 6-bit groups map to and from characters with `Bitwise` and a lookup `Array`.

Checked at every size: decoding the encoded text must give back every byte, and the text must
be `4 * ceil(n / 3)` characters. Every run also checks the RFC's test vectors, "" through
"foobar", and two that produce every character of the alphabet.

-}

import Array exposing (Array)
import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode as Decode exposing (Step(..))
import Bytes.Encode as Encode
import Dict exposing (Dict)


alphabet : Array Char
alphabet =
    Array.fromList (String.toList "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")


values : Dict Char Int
values =
    Dict.fromList (List.indexedMap (\i c -> ( c, i )) (Array.toList alphabet))


toList : Bytes -> List Int
toList bytes =
    let
        n =
            Bytes.width bytes
    in
    Decode.decode
        (Decode.loop ( n, [] )
            (\( left, acc ) ->
                if left <= 0 then
                    Decode.succeed (Done (List.reverse acc))

                else
                    Decode.map (\x -> Loop ( left - 1, x :: acc )) Decode.unsignedInt8
            )
        )
        bytes
        |> Maybe.withDefault []


char : Int -> Char
char v =
    Maybe.withDefault '=' (Array.get (Bitwise.and 63 v) alphabet)


encode : Bytes -> String
encode bytes =
    let
        -- the characters go onto `acc` in reverse, four at a time, last first
        go xs acc =
            case xs of
                a :: b :: c :: rest ->
                    let
                        w =
                            a * 65536 + b * 256 + c
                    in
                    go rest (char w :: char (w // 64) :: char (w // 4096) :: char (w // 262144) :: acc)

                [ a, b ] ->
                    let
                        w =
                            a * 65536 + b * 256
                    in
                    '=' :: char (w // 64) :: char (w // 4096) :: char (w // 262144) :: acc

                [ a ] ->
                    let
                        w =
                            a * 65536
                    in
                    '=' :: '=' :: char (w // 4096) :: char (w // 262144) :: acc

                [] ->
                    acc
    in
    String.fromList (List.reverse (go (toList bytes) []))


decode : String -> Bytes
decode text =
    let
        value c =
            Maybe.withDefault 0 (Dict.get c values)

        go cs acc =
            case cs of
                a :: b :: '=' :: '=' :: _ ->
                    let
                        w =
                            value a * 262144 + value b * 4096
                    in
                    w // 65536 :: acc

                a :: b :: c :: '=' :: _ ->
                    let
                        w =
                            value a * 262144 + value b * 4096 + value c * 64
                    in
                    modBy 256 (w // 256) :: w // 65536 :: acc

                a :: b :: c :: d :: rest ->
                    let
                        w =
                            value a * 262144 + value b * 4096 + value c * 64 + value d
                    in
                    go rest (modBy 256 w :: modBy 256 (w // 256) :: w // 65536 :: acc)

                _ ->
                    acc
    in
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 (List.reverse (go (String.toList text) []))))


ascii : String -> Bytes
ascii s =
    Encode.encode (Encode.string s)


fromList : List Int -> Bytes
fromList xs =
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 xs))


{-| The RFC 4648 test vectors, plus two that use every character: `+/8=`, and 48 bytes whose
encoding is the whole alphabet in order (the RFC's vectors never produce `+` or `/`, so a
swapped alphabet would pass them).
-}
vectors : Bool
vectors =
    List.all (\( plain, coded ) -> encode (ascii plain) == coded && toList (decode coded) == toList (ascii plain))
        [ ( "", "" ), ( "f", "Zg==" ), ( "fo", "Zm8=" ), ( "foo", "Zm9v" ), ( "foob", "Zm9vYg==" ), ( "fooba", "Zm9vYmE=" ), ( "foobar", "Zm9vYmFy" ) ]
        && List.all (\( raw, coded ) -> encode (fromList raw) == coded && toList (decode coded) == raw)
            [ ( [ 0xFB, 0xFF ], "+/8=" )
            , ( [ 0x00, 0x10, 0x83, 0x10, 0x51, 0x87, 0x20, 0x92, 0x8B, 0x30, 0xD3, 0x8F, 0x41, 0x14, 0x93, 0x51, 0x55, 0x97, 0x61, 0x96, 0x9B, 0x71, 0xD7, 0x9F, 0x82, 0x18, 0xA3, 0x92, 0x59, 0xA7, 0xA2, 0x9A, 0xAB, 0xB2, 0xDB, 0xAF, 0xC3, 0x1C, 0xB3, 0xD3, 0x5D, 0xB7, 0xE3, 0x9E, 0xBB, 0xF3, 0xDF, 0xBF ]
              , "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
              )
            ]


bench : Int -> Bool
bench n =
    let
        original =
            List.map (\i -> modBy 256 (i * 7919 + i // 256)) (List.range 0 (n - 1))

        text =
            encode (Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 original)))
    in
    vectors && String.length text == 4 * ((n + 2) // 3) && toList (decode text) == original
