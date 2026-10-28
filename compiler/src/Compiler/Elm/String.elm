module Compiler.Elm.String exposing (Chunk(..), fromChunks, valueKey)

{-| A string or char literal can be recorded as a list of pieces, some copied
from the source text and some standing for an escape, and this module turns such
a list into the text of the literal.

That text is escaped, not decoded. A piece copied from the source is copied
unchanged, escapes and all, and the pieces that stand for escapes are written as
backslash escapes in the forms a JavaScript string literal uses, `\n` or
`\u00E9`. So the result is the body of a literal, not the value it denotes.

Each piece is a `Chunk`, and `fromChunks` joins a list of them in order.
`valueKey` goes the other way, from escaped text to a key for the value it
denotes.

@docs Chunk, fromChunks, valueKey

-}

import Hex
import Numeric.Integer as NI


{-| One piece of a string or char literal.

`Slice` carries an offset and a length into the source text, and stands for
that stretch of it, copied unchanged.

`Escape` carries the character written after a backslash, so `Escape 'n'` is
the two characters `\n`.

`CodePoint` carries a Unicode code point, written as `\uXXXX` with four
uppercase hex digits. A code point above `0xFFFF` is written as a UTF-16
surrogate pair, two such escapes; a code point of `0xFFFF` or below is one
escape.

-}
type Chunk
    = Slice Int Int
    | Escape Char
    | CodePoint Int


{-| Returns the escaped text of a literal made of `chunks`, in order, where
`src` is the source text that `Slice` offsets point into.
-}
fromChunks : String -> List Chunk -> String
fromChunks src chunks =
    String.concat (List.reverse (writeChunks src [] chunks))


{-| Returns `acc` with the text of each of `chunks` pushed onto its front, so
the result holds the pieces in reverse order.
-}
writeChunks : String -> List String -> List Chunk -> List String
writeChunks src acc chunks =
    case chunks of
        [] ->
            acc

        chunk :: otherChunks ->
            case chunk of
                Slice ptr len ->
                    writeChunks src (String.slice ptr (ptr + len) src :: acc) otherChunks

                Escape word ->
                    writeChunks src (String.fromChar word :: "\\" :: acc) otherChunks

                CodePoint code ->
                    if code <= 0xFFFF then
                        writeChunks src (writeCode code :: acc) otherChunks

                    else
                        let
                            ( hi, lo ) =
                                NI.divMod (code - 0x00010000) 0x0400

                            hiCode : String
                            hiCode =
                                writeCode (hi + 0xD800)

                            lowCode : String
                            lowCode =
                                writeCode (lo + 0xDC00)
                        in
                        writeChunks src (lowCode :: hiCode :: acc) otherChunks


{-| Returns `code` as a `\uXXXX` escape, in uppercase hex padded with zeros to
four digits.
-}
writeCode : Int -> String
writeCode code =
    "\\u" ++ String.padLeft 4 '0' (String.toUpper (Hex.toString code))


{-| Returns a key for the value an escaped literal text denotes, so that two
spellings of one value (`a` and `\u0061`, or a raw astral character and its
surrogate-pair escapes) get the same key. The key is the code points, in
decimal, joined by `,`; it is for comparison only.
-}
valueKey : String -> String
valueKey text =
    decodeUnits (String.toList text) []
        |> combineSurrogates []
        |> List.map String.fromInt
        |> String.join ","


{-| Returns the UTF-16 units, or whole code points for raw characters, of
escaped literal text, after the reversed units already in `acc`.
-}
decodeUnits : List Char -> List Int -> List Int
decodeUnits chars acc =
    case chars of
        [] ->
            List.reverse acc

        '\\' :: 'u' :: a :: b :: c :: d :: rest ->
            decodeUnits rest (hexValue [ a, b, c, d ] :: acc)

        '\\' :: 'n' :: rest ->
            decodeUnits rest (0x0A :: acc)

        '\\' :: 'r' :: rest ->
            decodeUnits rest (0x0D :: acc)

        '\\' :: 't' :: rest ->
            decodeUnits rest (0x09 :: acc)

        '\\' :: escaped :: rest ->
            decodeUnits rest (Char.toCode escaped :: acc)

        c :: rest ->
            decodeUnits rest (Char.toCode c :: acc)


{-| Returns the value of a list of hexadecimal digits.
-}
hexValue : List Char -> Int
hexValue =
    List.foldl
        (\ch acc ->
            let
                code : Int
                code =
                    Char.toCode ch
            in
            acc
                * 16
                + (if code <= 0x39 then
                    code - 0x30

                   else if code <= 0x46 then
                    code - 0x37

                   else
                    code - 0x57
                  )
        )
        0


{-| Joins each high surrogate followed by a low surrogate into one code point,
after the reversed code points already in `acc`.
-}
combineSurrogates : List Int -> List Int -> List Int
combineSurrogates acc units =
    case units of
        hi :: lo :: rest ->
            if hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF then
                combineSurrogates (((hi - 0xD800) * 0x0400 + (lo - 0xDC00) + 0x00010000) :: acc) rest

            else
                combineSurrogates (hi :: acc) (lo :: rest)

        [ u ] ->
            List.reverse (u :: acc)

        [] ->
            List.reverse acc
