module Compiler.Elm.String exposing
    ( Chunk(..)
    , fromChunks
    )

{-| String escape sequence handling for Elm source code.

Processes string chunks with escape sequences and unicode code points,
converting them into properly escaped JavaScript string literals.


# Types

@docs Chunk


# Operations

@docs fromChunks

-}

import Hex
import Numeric.Integer as NI



-- ====== FROM CHUNKS ======


{-| Represents a portion of a string literal: a slice of the original source,
an escape sequence, or a unicode code point.
-}
type Chunk
    = Slice Int Int
    | Escape Char
    | CodePoint Int


{-| Converts a list of string chunks into a properly escaped JavaScript string literal.
Handles unicode code points and escape sequences.
-}
fromChunks : String -> List Chunk -> String
fromChunks src chunks =
    -- Collect the pieces in order and join once with `String.concat`, rather
    -- than a left-to-right `mba ++ chunk` fold. The fold had two encoding-
    -- independent costs: after the first non-ASCII chunk every later append
    -- widened the (now UTF-16) accumulator, and because each append is below
    -- the 32 KiB flatten limit it memcpied the whole accumulator — O(n²) for a
    -- literal assembled a couple of characters at a time. `String.concat` has
    -- all-UTF-8 and rope arms, so it pays neither. (`writeChunks` accumulates
    -- reversed and is tail-recursive; the former `offset` was dead — only
    -- threaded, never read — so it is gone.)
    String.concat (List.reverse (writeChunks src [] chunks))


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


writeCode : Int -> String
writeCode code =
    "\\u" ++ String.padLeft 4 '0' (String.toUpper (Hex.toString code))
