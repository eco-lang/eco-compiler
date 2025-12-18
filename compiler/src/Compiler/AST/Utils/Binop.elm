module Compiler.AST.Utils.Binop exposing
    ( Precedence, Associativity(..)
    , precedenceEncoder, precedenceDecoder
    , associativityEncoder, associativityDecoder
    )

{-| Types and utilities for binary operator metadata in the Elm compiler.

This module defines the precedence and associativity properties of binary operators,
along with serialization support for both JSON and binary formats. These properties
determine how expressions with multiple operators are parsed and evaluated.


# Types

@docs Precedence, Associativity


# JSON Serialization


# Binary Serialization

@docs precedenceEncoder, precedenceDecoder
@docs associativityEncoder, associativityDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- BINOP STUFF


{-| Operator precedence level, with higher numbers binding more tightly.
-}
type alias Precedence =
    Int


{-| Associativity determines how operators of the same precedence are grouped.
Left: `a + b + c` is `(a + b) + c`
Non: `a == b == c` is an error
Right: `a :: b :: c` is `a :: (b :: c)`
-}
type Associativity
    = Left
    | Non
    | Right



-- JSON ENCODERS and DECODERS
-- ENCODERS and DECODERS


{-| Encode precedence to binary format.
-}
precedenceEncoder : Precedence -> Bytes.Encode.Encoder
precedenceEncoder =
    BE.int


{-| Decode precedence from binary format.
-}
precedenceDecoder : Bytes.Decode.Decoder Precedence
precedenceDecoder =
    BD.int


{-| Encode associativity to binary format as an unsigned 8-bit integer.
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


{-| Decode associativity from binary format.
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
