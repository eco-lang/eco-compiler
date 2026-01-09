module Compiler.Parse.Primitives exposing
    ( Parser(..), PStep(..), State(..), StateData
    , pure, map, andThen, oneOf, oneOfWithFallback, loop
    , Row, Col, getPosition, addLocation, addEnd
    , withIndent, withBacksetIndent
    , inContext, specialize
    , fromByteString, fromSnippet, Snippet(..), snippetEncoder, snippetDecoder
    , word1, word2, unsafeIndex, isWord, getCharWidth
    , Step(..)
    )

{-| Core parser primitives and combinators for the Elm compiler.

This module provides the foundational parsing infrastructure used throughout the
compiler's parser. It implements a custom parser type with position tracking,
indentation-sensitive parsing, and efficient error reporting.


# Parser Type

@docs Parser, PStep, State, StateData


# Parser Combinators

@docs pure, map, andThen, oneOf, oneOfWithFallback, loop


# Position Tracking

@docs Row, Col, getPosition, addLocation, addEnd


# Indentation

@docs withIndent, withBacksetIndent


# Error Context

@docs inContext, specialize


# Running Parsers

@docs fromByteString, fromSnippet, Snippet, snippetEncoder, snippetDecoder


# Character Utilities

@docs word1, word2, unsafeIndex, isWord, getCharWidth


# Loop Control

@docs Step

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Reporting.Annotation as A
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)



-- ====== PARSER ======


{-| The core parser type that transforms a State into a parse result.

Parsers consume input and produce either success (with a value) or failure
(with an error). The `x` type parameter represents the error type, and `a`
represents the success value type.

-}
type Parser x a
    = Parser (State -> PStep x a)


{-| Parser step result type with four variants for different parse outcomes.

  - `Cok`: Consumed input, parse OK (success after consuming input)
  - `Eok`: Empty OK (success without consuming input)
  - `Cerr`: Consumed input, error (failure after consuming input)
  - `Eerr`: Empty error (failure without consuming input)

The distinction between consumed/empty is crucial for backtracking behavior.

-}
type PStep x a
    = Cok a State
    | Eok a State
    | Cerr Row Col (Row -> Col -> x)
    | Eerr Row Col (Row -> Col -> x)


{-| The internal parser state data including source, position, and location.

  - `src`: The source string being parsed
  - `pos`: Current byte position in the source
  - `end`: End position (length of source or snippet)
  - `indent`: Current indentation level for layout-sensitive parsing
  - `row`: Current row (line) number (1-indexed)
  - `col`: Current column number (1-indexed)

-}
type alias StateData =
    { src : String
    , pos : Int
    , end : Int
    , indent : Int
    , row : Row
    , col : Col
    }


{-| Parser state wrapper type.
-}
type State
    = -- PERF try taking some out to avoid allocation
      State StateData


{-| Row (line) number type alias for position tracking (1-indexed).
-}
type alias Row =
    Int


{-| Column number type alias for position tracking (1-indexed).
-}
type alias Col =
    Int



-- ====== FUNCTOR ======


{-| Transform the result of a parser by applying a function to the success value.

This is the functor map operation for parsers. It does not affect error values
or consume any additional input.

-}
map : (a -> b) -> Parser x a -> Parser x b
map f (Parser parser) =
    Parser
        (\state ->
            case parser state of
                Cok a s ->
                    Cok (f a) s

                Eok a s ->
                    Eok (f a) s

                Cerr r c t ->
                    Cerr r c t

                Eerr r c t ->
                    Eerr r c t
        )



-- ====== ONE OF ======


{-| Try a list of parsers in order, succeeding with the first one that succeeds.

If all parsers fail without consuming input (Eerr), returns an error created by
the provided error constructor at the current position. If any parser consumes
input, that result is returned immediately (no backtracking after consumption).

-}
oneOf : (Row -> Col -> x) -> List (Parser x a) -> Parser x a
oneOf toError parsers =
    Parser
        (\state ->
            oneOfHelp state toError parsers
        )


oneOfHelp : State -> (Row -> Col -> x) -> List (Parser x a) -> PStep x a
oneOfHelp state toError parsers =
    case parsers of
        (Parser parser) :: remainingParsers ->
            case parser state of
                Eerr _ _ _ ->
                    oneOfHelp state toError remainingParsers

                result ->
                    result

        [] ->
            let
                (State s) =
                    state
            in
            Eerr s.row s.col toError



-- ====== ONE OF WITH FALLBACK ======


{-| Try a list of parsers, returning a fallback value if all fail without consuming input.

Similar to `oneOf`, but instead of failing when all parsers fail, returns the
provided fallback value. This is useful for optional syntax constructs.

-}
oneOfWithFallback : List (Parser x a) -> a -> Parser x a
oneOfWithFallback parsers fallback =
    Parser (\state -> oowfHelp state parsers fallback)


oowfHelp : State -> List (Parser x a) -> a -> PStep x a
oowfHelp state parsers fallback =
    case parsers of
        [] ->
            Eok fallback state

        (Parser parser) :: remainingParsers ->
            case parser state of
                Eerr _ _ _ ->
                    oowfHelp state remainingParsers fallback

                result ->
                    result



-- ====== MONAD ======


{-| Create a parser that always succeeds with the given value without consuming input.

This is the monadic return/pure operation. It produces an Eok result.

-}
pure : a -> Parser x a
pure value =
    Parser (\state -> Eok value state)


{-| Sequence two parsers, using the result of the first to determine the second.

This is the monadic bind operation. The callback function receives the result
of the first parser and returns the second parser to run. Properly handles
consumption tracking: if the first parser consumed input (Cok), the second
parser's Eok is promoted to Cok.

-}
andThen : (a -> Parser x b) -> Parser x a -> Parser x b
andThen callback (Parser parserA) =
    Parser
        (\state ->
            case parserA state of
                Cok a s ->
                    case callback a of
                        Parser parserB ->
                            case parserB s of
                                Cok a_ s_ ->
                                    Cok a_ s_

                                Eok a_ s_ ->
                                    Cok a_ s_

                                result ->
                                    result

                Eok a s ->
                    case callback a of
                        Parser parserB ->
                            parserB s

                Cerr r c t ->
                    Cerr r c t

                Eerr r c t ->
                    Eerr r c t
        )



-- ====== FROM BYTESTRING ======


{-| Run a parser on a complete source string.

Returns `Ok` with the parsed value if successful and the entire input is consumed.
Returns `Err` if parsing fails or if there is unconsumed input remaining (using
the provided error constructor for the latter case).

-}
fromByteString : Parser x a -> (Row -> Col -> x) -> String -> Result x a
fromByteString (Parser parser) toBadEnd src =
    let
        initialState : State
        initialState =
            State { src = src, pos = 0, end = String.length src, indent = 0, row = 1, col = 1 }
    in
    case parser initialState of
        Cok a state ->
            toOk toBadEnd a state

        Eok a state ->
            toOk toBadEnd a state

        Cerr row col toError ->
            toErr row col toError

        Eerr row col toError ->
            toErr row col toError


toOk : (Row -> Col -> x) -> a -> State -> Result x a
toOk toBadEnd a (State s) =
    if s.pos == s.end then
        Ok a

    else
        Err (toBadEnd s.row s.col)


toErr : Row -> Col -> (Row -> Col -> x) -> Result x a
toErr row col toError =
    Err (toError row col)



-- ====== FROM SNIPPET ======


{-| A snippet represents a slice of a source file with position information.

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


{-| Run a parser on a snippet of source code with position tracking.

Similar to `fromByteString`, but parses only a portion of a source string
(defined by offset and length) while maintaining correct position information
relative to the original source file.

-}
fromSnippet : Parser x a -> (Row -> Col -> x) -> Snippet -> Result x a
fromSnippet (Parser parser) toBadEnd (Snippet { fptr, offset, length, offRow, offCol }) =
    let
        initialState : State
        initialState =
            State { src = fptr, pos = offset, end = offset + length, indent = 0, row = offRow, col = offCol }
    in
    case parser initialState of
        Cok a state ->
            toOk toBadEnd a state

        Eok a state ->
            toOk toBadEnd a state

        Cerr row col toError ->
            toErr row col toError

        Eerr row col toError ->
            toErr row col toError



-- ====== POSITION ======


{-| Get the current parser position without consuming any input.

Returns a `Position` containing the current row and column numbers.

-}
getPosition : Parser x A.Position
getPosition =
    Parser
        (\((State s) as state) ->
            Eok (A.Position s.row s.col) state
        )


{-| Annotate a parser's result with its source location.

Captures the start position before parsing and the end position after parsing,
wrapping the result in a `Located` value with the complete region.

-}
addLocation : Parser x a -> Parser x (A.Located a)
addLocation (Parser parser) =
    Parser
        (\((State startS) as state) ->
            case parser state of
                Cok a ((State endS) as s) ->
                    Cok (A.At (A.Region (A.Position startS.row startS.col) (A.Position endS.row endS.col)) a) s

                Eok a ((State endS) as s) ->
                    Eok (A.At (A.Region (A.Position startS.row startS.col) (A.Position endS.row endS.col)) a) s

                Cerr r c t ->
                    Cerr r c t

                Eerr r c t ->
                    Eerr r c t
        )


{-| Create a located value from a start position, a value, and the current position.

Uses the provided start position and the current parser position as the end,
wrapping the value in a `Located` annotation. Does not consume any input.

-}
addEnd : A.Position -> a -> Parser x (A.Located a)
addEnd start value =
    Parser
        (\((State s) as state) ->
            Eok (A.at start (A.Position s.row s.col) value) state
        )



-- ====== INDENT ======


{-| Run a parser with the indentation level set to the current column.

Sets the indent level to the current column before running the parser, then
restores the previous indent level afterward. This is used for indentation-
sensitive syntax like `let` blocks where nested definitions must align.

-}
withIndent : Parser x a -> Parser x a
withIndent (Parser parser) =
    Parser
        (\(State st) ->
            case parser (State { st | indent = st.col }) of
                Cok a (State newS) ->
                    Cok a (State { newS | indent = st.indent })

                Eok a (State newS) ->
                    Eok a (State { newS | indent = st.indent })

                err ->
                    err
        )


{-| Run a parser with the indentation level set back by a specified offset.

Sets the indent level to the current column minus the backset amount, then
restores the previous indent level after parsing. Used for handling indentation
in cases like `case` expressions where branches may be indented relative to
a previous token.

-}
withBacksetIndent : Int -> Parser x a -> Parser x a
withBacksetIndent backset (Parser parser) =
    Parser
        (\(State st) ->
            case parser (State { st | indent = st.col - backset }) of
                Cok a (State newS) ->
                    Cok a (State { newS | indent = st.indent })

                Eok a (State newS) ->
                    Eok a (State { newS | indent = st.indent })

                err ->
                    err
        )



-- ====== CONTEXT ======


{-| Parse with contextual error information added to failures.

Runs a start parser to establish context, then runs the main parser. If the
main parser fails, the error is wrapped with context information from the start
position. This helps provide better error messages by showing where a syntactic
construct began.

-}
inContext : (x -> Row -> Col -> y) -> Parser y start -> Parser x a -> Parser y a
inContext addContext (Parser parserStart) (Parser parserA) =
    Parser
        (\((State st) as state) ->
            case parserStart state of
                Cok _ s ->
                    case parserA s of
                        Cok a s_ ->
                            Cok a s_

                        Eok a s_ ->
                            Cok a s_

                        Cerr r c tx ->
                            Cerr st.row st.col (addContext (tx r c))

                        Eerr r c tx ->
                            Cerr st.row st.col (addContext (tx r c))

                Eok _ s ->
                    case parserA s of
                        Cok a s_ ->
                            Cok a s_

                        Eok a s_ ->
                            Eok a s_

                        Cerr r c tx ->
                            Cerr st.row st.col (addContext (tx r c))

                        Eerr r c tx ->
                            Eerr st.row st.col (addContext (tx r c))

                Cerr r c t ->
                    Cerr r c t

                Eerr r c t ->
                    Eerr r c t
        )


{-| Transform parser errors by applying a context-adding function.

Similar to `inContext` but without a separate start parser. Captures the current
position and uses it to add context to any errors produced by the parser.

-}
specialize : (x -> Row -> Col -> y) -> Parser x a -> Parser y a
specialize addContext (Parser parser) =
    Parser
        (\((State st) as state) ->
            case parser state of
                Cok a s ->
                    Cok a s

                Eok a s ->
                    Eok a s

                Cerr r c tx ->
                    Cerr st.row st.col (addContext (tx r c))

                Eerr r c tx ->
                    Eerr st.row st.col (addContext (tx r c))
        )



-- ====== SYMBOLS ======


{-| Parse a single specific character.

Succeeds if the next character matches the expected character, consuming it.
Fails with an Eerr if the character doesn't match or if at end of input.

-}
word1 : Char -> (Row -> Col -> x) -> Parser x ()
word1 word toError =
    Parser
        (\(State st) ->
            if st.pos < st.end && unsafeIndex st.src st.pos == word then
                let
                    newState : State
                    newState =
                        State { st | pos = st.pos + 1, col = st.col + 1 }
                in
                Cok () newState

            else
                Eerr st.row st.col toError
        )


{-| Parse a sequence of two specific characters.

Succeeds if the next two characters match the expected sequence, consuming both.
Fails with an Eerr if either character doesn't match or if there aren't enough
characters remaining.

-}
word2 : Char -> Char -> (Row -> Col -> x) -> Parser x ()
word2 w1 w2 toError =
    Parser
        (\(State st) ->
            let
                pos1 : Int
                pos1 =
                    st.pos + 1
            in
            if pos1 < st.end && unsafeIndex st.src st.pos == w1 && unsafeIndex st.src pos1 == w2 then
                let
                    newState : State
                    newState =
                        State { st | pos = st.pos + 2, col = st.col + 2 }
                in
                Cok () newState

            else
                Eerr st.row st.col toError
        )



-- ====== LOW-LEVEL CHECKS ======


{-| Get a character at a specific index in a string without bounds checking.

This function is unsafe because it crashes if the index is out of bounds.
It should only be used when the index is known to be valid.

-}
unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( char, _ ) ->
            char

        Nothing ->
            crash "Error on unsafeIndex!"


{-| Check if the character at a given position matches an expected character.

Returns `True` if position is within bounds and the character matches,
`False` otherwise. This is a safe alternative to direct character comparison.

-}
isWord : String -> Int -> Int -> Char -> Bool
isWord src pos end word =
    pos < end && unsafeIndex src pos == word


{-| Get the width of a character in UTF-16 code units.

Returns 2 for characters outside the Basic Multilingual Plane (code point > 0xFFFF),
which require surrogate pairs in UTF-16, and 1 for all other characters.

-}
getCharWidth : Char -> Int
getCharWidth word =
    if Char.toCode word > 0xFFFF then
        2

    else
        1



-- ====== ENCODERS and DECODERS ======


{-| Encode a Snippet to bytes for serialization.

Encodes all fields (fptr, offset, length, offRow, offCol) in sequence for
storage or transmission.

-}
snippetEncoder : Snippet -> Bytes.Encode.Encoder
snippetEncoder (Snippet { fptr, offset, length, offRow, offCol }) =
    Bytes.Encode.sequence
        [ BE.string fptr
        , BE.int offset
        , BE.int length
        , BE.int offRow
        , BE.int offCol
        ]


{-| Decode a Snippet from bytes.

Decodes the fields in the same order as `snippetEncoder` (fptr, offset, length,
offRow, offCol) to reconstruct the Snippet.

-}
snippetDecoder : Bytes.Decode.Decoder Snippet
snippetDecoder =
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



-- ====== LOOP ======


{-| Control flow type for the `loop` combinator.

  - `Loop state`: Continue looping with updated state
  - `Done a`: Exit loop with final result

-}
type Step state a
    = Loop state
    | Done a


{-| Repeatedly apply a parser-producing function until it returns `Done`.

A general-purpose looping combinator for parsers. The callback receives the
current state and returns a parser that produces either `Loop` (to continue
with new state) or `Done` (to finish with a result). Properly tracks input
consumption across iterations.

-}
loop : (state -> Parser x (Step state a)) -> state -> Parser x a
loop callback loopState =
    Parser
        (\state ->
            loopHelp callback state loopState Eok Eerr
        )


loopHelp :
    (state -> Parser x (Step state a))
    -> State
    -> state
    -> (a -> State -> PStep x a)
    -> (Row -> Col -> (Row -> Col -> x) -> PStep x a)
    -> PStep x a
loopHelp callback state loopState eok eerr =
    case callback loopState of
        Parser parser ->
            case parser state of
                Cok (Loop newLoopState) newState ->
                    loopHelp callback newState newLoopState Cok Cerr

                Cok (Done a) newState ->
                    Cok a newState

                Eok (Loop newLoopState) newState ->
                    loopHelp callback newState newLoopState eok eerr

                Eok (Done a) newState ->
                    eok a newState

                Cerr r c t ->
                    Cerr r c t

                Eerr r c t ->
                    eerr r c t
