module StreamCodecHelp exposing (base64ToBytes, bytesFromList, bytesToString, codecData, codes, concatBytes, hex, readAll, splitBytes)

{-| Shared helpers for the eco/system Phase 6 stream tests (not a test: no
`main`): building and showing Bytes, the 1 MiB codec test data, and reading a
stream to the end.
-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Stream
import Task exposing (Task)


{-| The 1 MiB text behind `StreamCodecFixture`: the lines `line <i mod 2000>\n`
for i = 0, 1, ..., cut at `size` characters (all ASCII, so bytes = characters).
-}
codecData : Int -> String
codecData size =
    let
        build i len acc =
            if len >= size then
                acc

            else
                let
                    line =
                        "line " ++ String.fromInt (modBy 2000 i) ++ "\n"
                in
                build (i + 1) (len + String.length line) (line :: acc)
    in
    build 0 0 []
        |> List.reverse
        |> String.concat
        |> String.left size


bytesFromList : List Int -> Bytes
bytesFromList values =
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 values))


concatBytes : List Bytes -> Bytes
concatBytes chunks =
    Encode.encode (Encode.sequence (List.map Encode.bytes chunks))


bytesToString : Bytes -> String
bytesToString bytes =
    Decode.decode (Decode.string (Bytes.width bytes)) bytes
        |> Maybe.withDefault "<invalid>"


{-| Split into pieces of at most `n` bytes.
-}
splitBytes : Int -> Bytes -> List Bytes
splitBytes n bytes =
    let
        step ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                let
                    k =
                        min n remaining
                in
                Decode.bytes k |> Decode.map (\piece -> Decode.Loop ( remaining - k, piece :: acc ))
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


{-| Upper-case hex of each byte, space separated.
-}
hex : Bytes -> String
hex bytes =
    let
        step ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.unsignedInt8 |> Decode.map (\b -> Decode.Loop ( remaining - 1, hexByte b :: acc ))
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []
        |> String.join " "


hexByte : Int -> String
hexByte b =
    String.fromList [ hexDigit (b // 16), hexDigit (modBy 16 b) ]


hexDigit : Int -> Char
hexDigit d =
    if d < 10 then
        Char.fromCode (48 + d)

    else
        Char.fromCode (55 + d)


{-| The UTF-16 code units of a String in hex, e.g. `"68 20AC"`.
-}
codes : String -> String
codes str =
    String.toList str
        |> List.map (\c -> codeHex (Char.toCode c))
        |> String.join " "


codeHex : Int -> String
codeHex n =
    if n < 16 then
        String.fromList [ hexDigit n ]

    else
        codeHex (n // 16) ++ String.fromList [ hexDigit (modBy 16 n) ]


{-| Decode standard base64 (padding optional).
-}
base64ToBytes : String -> Bytes
base64ToBytes str =
    let
        sextets =
            String.toList str |> List.filterMap sextet

        go values acc =
            case values of
                a :: b :: c :: d :: rest ->
                    let
                        n =
                            a * 262144 + b * 4096 + c * 64 + d
                    in
                    go rest (Encode.unsignedInt8 (modBy 256 n) :: Encode.unsignedInt8 (modBy 256 (n // 256)) :: Encode.unsignedInt8 (n // 65536) :: acc)

                [ a, b, c ] ->
                    let
                        n =
                            a * 262144 + b * 4096 + c * 64
                    in
                    Encode.unsignedInt8 (modBy 256 (n // 256)) :: Encode.unsignedInt8 (n // 65536) :: acc

                [ a, b ] ->
                    Encode.unsignedInt8 ((a * 262144 + b * 4096) // 65536) :: acc

                _ ->
                    acc
    in
    Encode.encode (Encode.sequence (List.reverse (go sextets [])))


sextet : Char -> Maybe Int
sextet c =
    let
        code =
            Char.toCode c
    in
    if code >= 65 && code <= 90 then
        Just (code - 65)

    else if code >= 97 && code <= 122 then
        Just (code - 71)

    else if code >= 48 && code <= 57 then
        Just (code + 4)

    else if c == '+' then
        Just 62

    else if c == '/' then
        Just 63

    else
        Nothing


{-| Read every value until the stream closes.
-}
readAll : Stream.Readable a -> Task Stream.Error (List a)
readAll stream =
    Stream.readUntilClosed (\value acc -> Ok (value :: acc)) [] stream
        |> Task.map List.reverse
