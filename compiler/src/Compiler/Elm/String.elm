module Compiler.Elm.String exposing
    ( Chunk(..)
    , fromChunks
    )

{-| A string or char literal can be recorded as a list of pieces, some copied
from the source text and some standing for an escape, and this module turns such
a list into the text of the literal.

That text is escaped, not decoded. A piece copied from the source is copied
unchanged, escapes and all, and the pieces that stand for escapes are written as
backslash escapes in the forms a JavaScript string literal uses, `\n` or
`\u00E9`. So the result is the body of a literal, not the value it denotes.

Each piece is a `Chunk`, and `fromChunks` joins a list of them in order.

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
surrogate pair, two such escapes. The test is `code < 0xFFFF`, so `0xFFFF`
itself also takes that path and comes out as `\uD7FF\uDFFF`, which is not a
valid pair.

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
                    if code < 0xFFFF then
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
