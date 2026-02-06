module Compiler.AST.Snippet exposing
    ( Snippet(..), Row, Col
    , encoder, decoder
    )

{-| Source code snippet type for preserving position information.

This module defines the `Snippet` type used to represent a substring of source
code with its original file position. It is used by the Source AST for comments
and other position-sensitive constructs.

@docs Snippet, Row, Col
@docs encoder, decoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| Row (line) number type alias for position tracking (1-indexed).
-}
type alias Row =
    Int


{-| Column number type alias for position tracking (1-indexed).
-}
type alias Col =
    Int


{-| A snippet of source code with its position in the original file.

This allows parsing a substring of a file while maintaining accurate row/column
positions relative to the original file. Useful for incremental parsing or
parsing embedded code fragments.

  - `fptr`: The source string (file pointer/content)
  - `offset`: Starting byte position in the source
  - `length`: Number of bytes in the snippet
  - `offRow`: Starting row number in the original file
  - `offCol`: Starting column number in the original file

-}
type Snippet
    = Snippet
        { fptr : String
        , offset : Int
        , length : Int
        , offRow : Row
        , offCol : Col
        }


{-| Encode a Snippet to bytes for serialization.

Encodes all fields (fptr, offset, length, offRow, offCol) in sequence for
storage or transmission.

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


{-| Decode a Snippet from bytes.

Decodes the fields in the same order as `encoder` (fptr, offset, length,
offRow, offCol) to reconstruct the Snippet.

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
