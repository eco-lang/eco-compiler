module Compiler.Parse.Symbol exposing
    ( operator, binopCharSet
    , BadOperator(..)
    , badOperatorEncoder, badOperatorDecoder
    )

{-| An Elm operator is named with symbol characters, but a few runs of those
characters are the language's own syntax, and this module is where the two are
told apart. It holds the parser for an operator, the set of characters an
operator is made of, and the reasons a run is refused.

An _operator_ here is the longest run of characters from `binopCharSet` at the
current position. The run is read whole before it is looked at, so it is never
split: `|>` is one operator, not `|` followed by `>`. A run is refused only when
the whole of it is one of the five pieces of syntax that `BadOperator` lists. A
longer run that contains one, such as `|.` or `->>`, is an ordinary operator.

Whether a failure counts as consuming input is the parser's own choice, with
the meaning `Compiler.Parse.Primitives` gives it. A missing operator and a
refused `.` are failures with nothing consumed, so a `oneOf` around `operator`
may still try its next alternative. The other four refusals are reported as
consumed, which ends the choice.


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



-- ====== OPERATOR ======


{-| A run of operator characters that `operator` refuses because, standing
alone, it is part of Elm's own syntax rather than an operator.

`BadDot` is `.`, `BadPipe` is `|`, `BadArrow` is `->`, `BadEquals` is `=`, and
`BadHasType` is `:`.

-}
type BadOperator
    = BadDot
    | BadPipe
    | BadArrow
    | BadEquals
    | BadHasType


{-| Produces a parser for one operator, whose result is the operator's
characters.

The parser reads the longest run of characters from `binopCharSet` at the
current position, stopping at the end of its input. An empty run fails with
nothing consumed, using `toExpectation`. A run that is exactly `.` also fails
with nothing consumed, using `toError BadDot`. A run that is exactly `|`, `->`,
`=` or `:` fails as consumed, using `toError` with the matching `BadOperator`.
Every failure is placed at the row and column where the parser started. Any
other run, including `-`, `..` and `::`, succeeds as consumed, with the column
advanced by one for each character.

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


{-| Returns the index just past the run of operator characters that starts at
`pos` in `src`, never going beyond `end`. It returns `pos` itself when no run
starts there.
-}
chompOps : String -> Int -> Int -> Int
chompOps src pos end =
    if pos < end && isBinopCharHelp (P.unsafeIndex src pos) then
        chompOps src (pos + 1) end

    else
        pos


{-| Returns whether `char` is one of the characters in `binopCharSet`.
-}
isBinopCharHelp : Char -> Bool
isBinopCharHelp char =
    let
        code : Int
        code =
            Char.toCode char
    in
    EverySet.member identity code binopCharSet


{-| The characters an operator is made of, held as character codes, which is
the form membership is tested in.
-}
binopCharSet : EverySet Int Int
binopCharSet =
    EverySet.fromList identity (List.map Char.toCode (String.toList "+-/*=.<>:&|^?%!"))



-- ====== ENCODERS and DECODERS ======


{-| Encodes a `BadOperator` as one unsigned byte, numbering the constructors
from 0 to 4 in the order the type declares them.
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


{-| A decoder for the byte that `badOperatorEncoder` writes. It fails on any
byte above 4.
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
