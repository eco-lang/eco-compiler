module Compiler.AST.Utils.Binop exposing
    ( Precedence, Associativity(..)
    , jsonPrecedenceEncoder, jsonPrecedenceDecoder
    , jsonAssociativityEncoder, jsonAssociativityDecoder
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

@docs jsonPrecedenceEncoder, jsonPrecedenceDecoder
@docs jsonAssociativityEncoder, jsonAssociativityDecoder


# Binary Serialization

@docs precedenceEncoder, precedenceDecoder
@docs associativityEncoder, associativityDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Json.Decode as Decode
import Json.Encode as Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- BINOP STUFF


type alias Precedence =
    Int


type Associativity
    = Left
    | Non
    | Right



-- JSON ENCODERS and DECODERS


jsonPrecedenceEncoder : Precedence -> Encode.Value
jsonPrecedenceEncoder =
    Encode.int


jsonPrecedenceDecoder : Decode.Decoder Precedence
jsonPrecedenceDecoder =
    Decode.int


jsonAssociativityEncoder : Associativity -> Encode.Value
jsonAssociativityEncoder associativity =
    case associativity of
        Left ->
            Encode.string "Left"

        Non ->
            Encode.string "Non"

        Right ->
            Encode.string "Right"


jsonAssociativityDecoder : Decode.Decoder Associativity
jsonAssociativityDecoder =
    Decode.string
        |> Decode.andThen
            (\str ->
                case str of
                    "Left" ->
                        Decode.succeed Left

                    "Non" ->
                        Decode.succeed Non

                    "Right" ->
                        Decode.succeed Right

                    _ ->
                        Decode.fail ("Unknown Associativity: " ++ str)
            )



-- ENCODERS and DECODERS


precedenceEncoder : Precedence -> Bytes.Encode.Encoder
precedenceEncoder =
    BE.int


precedenceDecoder : Bytes.Decode.Decoder Precedence
precedenceDecoder =
    BD.int


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
