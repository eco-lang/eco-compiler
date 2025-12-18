module Compiler.Parse.Symbol exposing
    ( operator, binopCharSet
    , BadOperator(..)
    , badOperatorEncoder, badOperatorDecoder
    )

{-| Parser for operators and symbolic tokens in Elm.

This module handles parsing of infix operators composed of symbolic characters.
It validates operators and provides error types for reserved symbolic sequences
that cannot be used as custom operators.


# Operator Parsing

@docs operator, binopCharSet


# Error Types

@docs BadOperator


# Serialization

@docs badOperatorEncoder, badOperatorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.Primitives as P exposing (Col, Parser, Row)
import Data.Set as EverySet exposing (EverySet)



-- OPERATOR


{-| Represents operators that are reserved and cannot be used as custom infix operators.
-}
type BadOperator
    = BadDot
    | BadPipe
    | BadArrow
    | BadEquals
    | BadHasType


{-| Parses an infix operator composed of symbolic characters.
Rejects reserved operators like '.', '|', '->', '=', and ':'.
-}
operator : (Row -> Col -> x) -> (BadOperator -> Row -> Col -> x) -> Parser x Name
operator toExpectation toError =
    P.Parser <|
        \(P.State st) ->
            let
                newPos : Int
                newPos =
                    chompOps st.src st.pos st.end
            in
            if st.pos == newPos then
                P.Eerr st.row st.col toExpectation

            else
                case String.slice st.pos newPos st.src of
                    "." ->
                        P.Eerr st.row st.col (toError BadDot)

                    "|" ->
                        P.Cerr st.row st.col (toError BadPipe)

                    "->" ->
                        P.Cerr st.row st.col (toError BadArrow)

                    "=" ->
                        P.Cerr st.row st.col (toError BadEquals)

                    ":" ->
                        P.Cerr st.row st.col (toError BadHasType)

                    op ->
                        let
                            newCol : Col
                            newCol =
                                st.col + (newPos - st.pos)

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, col = newCol }
                        in
                        P.Cok op newState


chompOps : String -> Int -> Int -> Int
chompOps src pos end =
    if pos < end && isBinopCharHelp (P.unsafeIndex src pos) then
        chompOps src (pos + 1) end

    else
        pos


isBinopCharHelp : Char -> Bool
isBinopCharHelp char =
    let
        code : Int
        code =
            Char.toCode char
    in
    EverySet.member identity code binopCharSet


{-| The set of characters that can appear in binary operators.
Includes: + - / \* = . < > : & | ^ ? % !
-}
binopCharSet : EverySet Int Int
binopCharSet =
    EverySet.fromList identity (List.map Char.toCode (String.toList "+-/*=.<>:&|^?%!"))



-- ENCODERS and DECODERS


{-| Encodes a BadOperator to bytes for serialization.
-}
badOperatorEncoder : BadOperator -> Bytes.Encode.Encoder
badOperatorEncoder badOperator =
    Bytes.Encode.unsignedInt8
        (case badOperator of
            BadDot ->
                0

            BadPipe ->
                1

            BadArrow ->
                2

            BadEquals ->
                3

            BadHasType ->
                4
        )


{-| Decodes a BadOperator from bytes for deserialization.
-}
badOperatorDecoder : Bytes.Decode.Decoder BadOperator
badOperatorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed BadDot

                    1 ->
                        Bytes.Decode.succeed BadPipe

                    2 ->
                        Bytes.Decode.succeed BadArrow

                    3 ->
                        Bytes.Decode.succeed BadEquals

                    4 ->
                        Bytes.Decode.succeed BadHasType

                    _ ->
                        Bytes.Decode.fail
            )
