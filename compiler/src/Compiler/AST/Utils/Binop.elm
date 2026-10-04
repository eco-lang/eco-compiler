module Compiler.AST.Utils.Binop exposing
    ( Precedence, Associativity(..)
    , precedenceEncoder, precedenceDecoder
    , associativityEncoder, associativityDecoder
    )

{-| An expression such as `a + b * c - d` is a chain of operators, and which
operands each operator takes depends on two properties of the operators, their
precedence and their associativity. This module is the one definition of those
two properties, together with their binary codecs.

An `infix` declaration gives an operator both properties, and a module's
interface records them for each operator it exports. When a chain is resolved
into nested applications, an operator of higher precedence takes its operands
first. Associativity matters only between operators of equal precedence: it
says whether a chain of them groups from the left, groups from the right, or is
not allowed at all.

The binary codecs write these properties in the compiler's binary format,
which `Utils.Bytes.Encode` describes.


# Types

@docs Precedence, Associativity


# Binary Serialization

@docs precedenceEncoder, precedenceDecoder
@docs associativityEncoder, associativityDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| The binding strength of an operator: of two operators, the one with the
higher precedence takes its operands first.

This is a name for `Int`, not a new type, and the compiler accepts any `Int`
here. An `infix` declaration in source can only give a single digit, 0 to 9.

-}
type alias Precedence =
    Int


{-| How a chain of operators of equal precedence is grouped.

For an operator `?`, `Left` groups the chain from the left, so that
`a ? b ? c` means `(a ? b) ? c`, and `Right` groups it from the right, so that
it means `a ? (b ? c)`.

`Non` means the operator does not chain: if `?` is `Non`, `a ? b ? c` is
reported as an error when operator chains are resolved during canonicalization.
So is `a ? b ! c` when `?` and `!` have equal precedence and one is `Left` and
the other `Right`.

-}
type Associativity
    = Left
    | Non
    | Right


{-| Encodes a precedence as `Utils.Bytes.Encode.int` encodes any `Int`.
-}
precedenceEncoder : Precedence -> Bytes.Encode.Encoder
precedenceEncoder =
    BE.int


{-| A decoder for a precedence written by `precedenceEncoder`.
-}
precedenceDecoder : Bytes.Decode.Decoder Precedence
precedenceDecoder =
    BD.int


{-| Encodes an associativity as a single byte: 0 for `Left`, 1 for `Non` and
2 for `Right`.
-}
associativityEncoder : Associativity -> Bytes.Encode.Encoder
associativityEncoder associativity =
    Bytes.Encode.unsignedInt8
        (case associativity of
            Left ->
                0

            Non ->
                1

            Right ->
                2
        )


{-| A decoder for an associativity written by `associativityEncoder`. Any byte
other than 0, 1 or 2 makes it fail.
-}
associativityDecoder : Bytes.Decode.Decoder Associativity
associativityDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Left

                    1 ->
                        Bytes.Decode.succeed Non

                    2 ->
                        Bytes.Decode.succeed Right

                    _ ->
                        Bytes.Decode.fail
            )
