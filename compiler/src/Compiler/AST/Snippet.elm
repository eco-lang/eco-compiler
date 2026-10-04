module Compiler.AST.Snippet exposing
    ( Snippet(..), Row, Col
    , encoder, decoder
    )

{-| Some pieces of a source text are found during one pass and read again later,
either by slicing them out or by running a parser over them. This module is how
such a piece is carried until then.

A _snippet_ names the piece by where it lies rather than by copying it. It
holds the whole text the piece belongs to, where in that text the piece starts
and how long it is, and the row and column at which it starts. The row and
column are what let a parser run over the piece report positions in the whole
file rather than positions within the piece.

Because a snippet holds the whole text, encoding one writes the whole text too:
every serialised snippet carries a full copy of the source it was taken from.

@docs Snippet, Row, Col
@docs encoder, decoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| A line number in a source text, counted from 1 as the parser counts lines.

This is a name for `Int`, not a new type, and the compiler checks nothing about
the values given where a `Row` is expected.

-}
type alias Row =
    Int


{-| A column number within a line of source text, counted from 1 as the parser
counts columns.

This is a name for `Int`, not a new type, and the compiler checks nothing about
the values given where a `Col` is expected.

-}
type alias Col =
    Int


{-| A piece of a source text, given by its position in the whole text.

`fptr` is the whole text, not a pointer and not only the piece. `offset` and
`length` are counted in the units `String.slice` uses on `fptr`, not in bytes,
so the piece is `String.slice offset (offset + length) fptr`. `offRow` and
`offCol` are the row and column, in the whole text, of the piece's first
character.

The constructor is exposed, and nothing checks that the fields agree with one
another: that the piece lies within `fptr`, or that `offRow` and `offCol` are
where `offset` falls.

-}
type Snippet
    = Snippet
        { fptr : String
        , offset : Int
        , length : Int
        , offRow : Row
        , offCol : Col
        }


{-| Encodes a snippet for `decoder` to read back. All of `fptr` is written, not
only the piece the snippet names.
-}
encoder : Snippet -> Bytes.Encode.Encoder
encoder (Snippet { fptr, offset, length, offRow, offCol }) =
    Bytes.Encode.sequence
        [ BE.string fptr
        , BE.int offset
        , BE.int length
        , BE.int offRow
        , BE.int offCol
        ]


{-| A decoder for a snippet written by `encoder`.
-}
decoder : Bytes.Decode.Decoder Snippet
decoder =
    Bytes.Decode.map5
        (\fptr offset length offRow offCol ->
            Snippet
                { fptr = fptr
                , offset = offset
                , length = length
                , offRow = offRow
                , offCol = offCol
                }
        )
        BD.string
        BD.int
        BD.int
        BD.int
        BD.int
