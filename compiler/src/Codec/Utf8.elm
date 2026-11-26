module Codec.Utf8 exposing (encode, decode, decodeLossy)

{-| Converts between `String` and UTF-8 `Bytes`, for the files and HTTP bodies
the compiler reads and writes as text.

`decode` reads bytes that are not valid UTF-8 the way Node's
`Buffer.toString('utf8')` and the WHATWG decoder read them: each maximal
invalid subsequence becomes U+FFFD, and decoding goes on. Valid input, the
usual case, is decoded by `Bytes.Decode.string`, which on eco's native backend
gives an all-ASCII text as a view of the bytes, without copying them. On the
JavaScript backends `Bytes.Decode.string` does not check its input, so there
invalid input decodes as that function reads it.

@docs encode, decode, decodeLossy

-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode exposing (Step(..))
import Bytes.Encode as Encode


{-| The UTF-8 encoding of the text.
-}
encode : String -> Bytes
encode text =
    Encode.encode (Encode.string text)


{-| The text the UTF-8 bytes spell, with U+FFFD for each maximal invalid
subsequence.
-}
decode : Bytes -> String
decode bytes =
    case Decode.decode (Decode.string (Bytes.width bytes)) bytes of
        Just text ->
            text

        Nothing ->
            decodeLossy bytes



-- ====== LOSSY DECODING ======


{-| The bytes, in order.
-}
toList : Bytes -> List Int
toList bytes =
    let
        step : ( Int, List Int ) -> Decode.Decoder (Step ( Int, List Int ) (List Int))
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Done (List.reverse acc))

            else
                Decode.map (\b -> Loop ( n - 1, b :: acc )) Decode.unsignedInt8
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


{-| Decodes the bytes, replacing each maximal invalid subsequence with U+FFFD
(Unicode §3.9, "U+FFFD Substitution of Maximal Subparts"), whatever the backend.
`decode` uses it for input `Bytes.Decode.string` refuses; it is exposed so that
it can be tested on the JavaScript backend, where that never happens.
-}
decodeLossy : Bytes -> String
decodeLossy bytes =
    decodeHelp (toList bytes) []


{-| Decodes `input` onto the characters decoded so far, `acc`, most recent first.
-}
decodeHelp : List Int -> List Char -> String
decodeHelp input acc =
    case input of
        [] ->
            String.fromList (List.reverse acc)

        b :: rest ->
            if b < 0x80 then
                decodeHelp rest (Char.fromCode b :: acc)

            else
                case sequenceShape b of
                    Just ( count, lo, hi ) ->
                        continue count lo hi (lead b count) rest acc

                    Nothing ->
                        decodeHelp rest (replacement :: acc)


{-| Reads the `count` continuation bytes of a sequence whose code point so far
is `cp`. The first must be within `lo`..`hi` and the others within 0x80..0xBF.
At the first byte that does not fit, U+FFFD stands for the bytes read so far,
and decoding resumes at that byte.
-}
continue : Int -> Int -> Int -> Int -> List Int -> List Char -> String
continue count lo hi cp input acc =
    if count == 0 then
        decodeHelp input (Char.fromCode cp :: acc)

    else
        case input of
            b :: rest ->
                if b >= lo && b <= hi then
                    continue (count - 1) 0x80 0xBF (cp * 64 + (b - 0x80)) rest acc

                else
                    decodeHelp input (replacement :: acc)

            [] ->
                decodeHelp [] (replacement :: acc)


{-| For a lead byte, the number of continuation bytes, and the range the first of
them must lie in (which rules out overlong forms, surrogates and code points
above U+10FFFF); `Nothing` for a byte that cannot start a sequence.
-}
sequenceShape : Int -> Maybe ( Int, Int, Int )
sequenceShape b =
    if b >= 0xC2 && b <= 0xDF then
        Just ( 1, 0x80, 0xBF )

    else if b == 0xE0 then
        Just ( 2, 0xA0, 0xBF )

    else if b == 0xED then
        Just ( 2, 0x80, 0x9F )

    else if b >= 0xE1 && b <= 0xEF then
        Just ( 2, 0x80, 0xBF )

    else if b == 0xF0 then
        Just ( 3, 0x90, 0xBF )

    else if b >= 0xF1 && b <= 0xF3 then
        Just ( 3, 0x80, 0xBF )

    else if b == 0xF4 then
        Just ( 3, 0x80, 0x8F )

    else
        Nothing


{-| The code-point bits a lead byte carries, for a sequence with `count`
continuation bytes.
-}
lead : Int -> Int -> Int
lead b count =
    case count of
        1 ->
            b - 0xC0

        2 ->
            b - 0xE0

        _ ->
            b - 0xF0


{-| U+FFFD REPLACEMENT CHARACTER.
-}
replacement : Char
replacement =
    Char.fromCode 0xFFFD
