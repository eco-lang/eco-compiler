module Compiler.GenerateMlir.BytesFusion.LoopIR exposing
    ( Endianness(..), WidthExpr(..), EncoderProgram, Op(..)
    , DecoderProgram, DecoderOp(..), FixedRead(..)
    , ListOrder(..), LoopCount(..)
    )

{-| The small vocabulary in which a fused `elm/bytes` encoder or decoder is
described between recognising it and emitting it.

An `elm/bytes` encoder or decoder can be compiled to straight reads and writes
on a buffer, instead of being built as a value and walked at run time, when its
shape is known at compile time. This module is the description of that shape:
a list of operations, each one a read, a write, a loop, or a step that combines
earlier results. It holds only types, and does no recognition or emission
itself.

Two ideas run through every type here.

The _cursor_ is the current read or write position in the buffer. Every read or
write starts at the cursor and moves it on by the number of bytes it covers.
Operations carry a cursor name as a `String`, but nothing in this module gives
that name a meaning.

Values are not lowered here. A value to be written, a length, a function to
apply or a constant to produce is kept as a `Mono.MonoExpr`, to be compiled
when the operations are emitted.

An encoder is an `EncoderProgram`: allocate a buffer whose size is a
`WidthExpr`, write into it with a list of `Op`, and return it. A decoder is a
`DecoderProgram`: read and combine values with a list of `DecoderOp`, each
result named by a _placeholder_ (a `String` name that a later operation uses to
refer to that result), and finish with one result or with failure.


# Types

@docs Endianness, WidthExpr, EncoderProgram, Op
@docs DecoderProgram, DecoderOp, FixedRead
@docs ListOrder, LoopCount

-}

import Compiler.IR.Mono as Mono


{-| The byte order of a multi-byte read or write: `LE` puts the least
significant byte first, `BE` the most significant.
-}
type Endianness
    = LE
    | BE


{-| An expression for the size in bytes of the buffer an encoder writes,
computed partly at compile time and partly at run time.

`WConst` is a size known at compile time, and `WAdd` is the sum of two sizes.

`WStringUtf8Width` is the number of bytes the string its expression produces
occupies when encoded as UTF-8, which is not its length in characters.

`WBytesWidth` is the length of the bytes value its expression produces.

`WListLengthMul` is a count multiplied by a width in bytes known at compile
time. It sizes a loop that writes the same number of bytes for every item. Its
expression must produce the count as an integer.

`WOpaqueWidth` is the size, measured at run time, of an encoder value that was
not recognised and is written as a whole.

-}
type WidthExpr
    = WConst Int
    | WAdd WidthExpr WidthExpr
    | WStringUtf8Width Mono.MonoExpr
    | WBytesWidth Mono.MonoExpr
    | WListLengthMul Mono.MonoExpr Int
    | WOpaqueWidth Mono.MonoExpr


{-| A fused encoder: allocate a buffer of `width` bytes, place the cursor
`cursor` at its start, perform `writes` in order, and return the buffer.
-}
type alias EncoderProgram =
    { cursor : String
    , width : WidthExpr
    , writes : List Op
    }


{-| One write of a fused encoder. Every constructor except `WriteEachItem`
carries a cursor name as its first argument.

`WriteU8`, `WriteU16`, `WriteU32`, `WriteF32` and `WriteF64` write the value
their expression produces as an unsigned integer or a float of that many bits,
in the given byte order where there is more than one byte. They are named
unsigned, but nothing here prevents a signed value being written with them.

`WriteBytesCopy` copies the bytes value its expression produces, and
`WriteUtf8` writes the string its expression produces as UTF-8.

`WriteEachItem` writes every element of a list. `iterExpr` produces the list,
`bodyOps` are the writes for one element, `itemVar` is the name by which
the expressions in `bodyOps` refer to the current element, and `itemType` is
the element's type. `itemByteWidth` is
the number of bytes `bodyOps` write for one element, which must be the same for
every element.

`WriteOpaque` writes an encoder value that was not recognised, by handing it to
the run-time encoder whole. Its size must be counted by a `WOpaqueWidth`.

-}
type Op
    = WriteU8 String Mono.MonoExpr
    | WriteU16 String Endianness Mono.MonoExpr
    | WriteU32 String Endianness Mono.MonoExpr
    | WriteF32 String Endianness Mono.MonoExpr
    | WriteF64 String Endianness Mono.MonoExpr
    | WriteBytesCopy String Mono.MonoExpr
    | WriteUtf8 String Mono.MonoExpr
    | WriteEachItem
        { cursorName : String
        , itemVar : String
        , itemType : Mono.MonoType
        , bodyOps : List Op
        , iterExpr : Mono.MonoExpr
        , itemByteWidth : Int
        }
    | WriteOpaque String Mono.MonoExpr


{-| A fused decoder: read from a cursor at the start of the input, performing
`body` in order, and produce `Just` the value named by the placeholder
`result`, unless an operation fails the decoder first.
-}
type alias DecoderProgram =
    { body : List DecoderOp
    , result : String
    }


{-| One step of a fused decoder. A decoder produces a `Maybe`: `Nothing` when
it fails, otherwise `Just` its result. Each read takes a cursor name as the
first argument. Where a constructor produces a value the last argument is the
placeholder that names that value.

`ReadU8` through `ReadF64` read a fixed number of bytes as an unsigned or
signed integer or a float of that many bits, in the given byte order where
there is more than one byte.

`ReadBytes` and `ReadUtf8` read a bytes value, or a UTF-8 string, of the length
in bytes that their expression produces. `ReadBytesVar` and `ReadUtf8Var` do
the same with the length taken from an earlier result, named by the
placeholder in the second argument.

`Apply1` to `Apply5` apply the function their expression produces to the
results named by the middle placeholders, in order, and name the result by the
last. They are how `map` to `map5` combine their decoders' results.

`PushValue` produces the value of its expression without reading anything,
which is what `succeed` does.

`LoopDecodeList` decodes a list of a given number of items (none when the count
is zero or negative), each one fixed-width read: the bytes for every item are
checked once before the loop, and the decoder fails if they are not all there.
Its arguments are the count, the cursor name, the item read, the order of the
resulting list and the result placeholder.

`LoopSentinelDecodeList` decodes items, each one fixed-width integer read,
until one equals the integer sentinel. Each read is bounds-checked, and running
out of input before the sentinel fails the decoder. The sentinel itself is
consumed but not put in the list. Its arguments are the sentinel, the cursor
name, the item read, the order of the resulting list and the result
placeholder.

`ReturnNothing` ends the decoder with `Nothing`.

-}
type DecoderOp
    = ReadU8 String String
    | ReadI8 String String
    | ReadU16 String Endianness String
    | ReadI16 String Endianness String
    | ReadU32 String Endianness String
    | ReadI32 String Endianness String
    | ReadF32 String Endianness String
    | ReadF64 String Endianness String
    | ReadBytes String Mono.MonoExpr String
    | ReadUtf8 String Mono.MonoExpr String
    | ReadBytesVar String String String
    | ReadUtf8Var String String String
    | Apply1 Mono.MonoExpr String String
    | Apply2 Mono.MonoExpr String String String
    | Apply3 Mono.MonoExpr String String String String
    | Apply4 Mono.MonoExpr String String String String String
    | Apply5 Mono.MonoExpr String String String String String String
    | PushValue Mono.MonoExpr String
    | LoopDecodeList LoopCount String FixedRead ListOrder String
    | LoopSentinelDecodeList Int String FixedRead ListOrder String
    | ReturnNothing


{-| The one read that decodes an item of a decoding loop: an unsigned (`RU`)
or signed (`RI`) integer, or a float (`RF`), of the number of bits its name
gives, in the given byte order where there is more than one byte.
-}
type FixedRead
    = RU8
    | RI8
    | RU16 Endianness
    | RI16 Endianness
    | RU32 Endianness
    | RI32 Endianness
    | RF32 Endianness
    | RF64 Endianness


{-| How many items a `LoopDecodeList` decodes: a literal count, the result of
an earlier operation named by its placeholder, or the value of an expression
(an `Int`), compiled where the loop is emitted.
-}
type LoopCount
    = CountLiteral Int
    | CountPlaceholder String
    | CountExpression Mono.MonoExpr


{-| The order of the list a decoding loop produces. `InReadOrder` has the items
in the order they were read, the result of `List.reverse acc` for a loop that
accumulates with `::`; `ReverseReadOrder` has the last item read first, the
accumulator `acc` itself.
-}
type ListOrder
    = InReadOrder
    | ReverseReadOrder
