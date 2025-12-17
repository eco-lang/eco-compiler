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



-- PARSER


type Parser x a
    = Parser (State -> PStep x a)


type PStep x a
    = Cok a State
    | Eok a State
    | Cerr Row Col (Row -> Col -> x)
    | Eerr Row Col (Row -> Col -> x)


type alias StateData =
    { src : String
    , pos : Int
    , end : Int
    , indent : Int
    , row : Row
    , col : Col
    }


type State
    = -- PERF try taking some out to avoid allocation
      State StateData


type alias Row =
    Int


type alias Col =
    Int



-- FUNCTOR


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



-- ONE OF


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



-- ONE OF WITH FALLBACK


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



-- MONAD


pure : a -> Parser x a
pure value =
    Parser (\state -> Eok value state)


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



-- FROM BYTESTRING


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



-- FROM SNIPPET


type Snippet
    = Snippet
        { fptr : String
        , offset : Int
        , length : Int
        , offRow : Row
        , offCol : Col
        }


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



-- POSITION


getPosition : Parser x A.Position
getPosition =
    Parser
        (\((State s) as state) ->
            Eok (A.Position s.row s.col) state
        )


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


addEnd : A.Position -> a -> Parser x (A.Located a)
addEnd start value =
    Parser
        (\((State s) as state) ->
            Eok (A.at start (A.Position s.row s.col) value) state
        )



-- INDENT


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



-- CONTEXT


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



-- SYMBOLS


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



-- LOW-LEVEL CHECKS


unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( char, _ ) ->
            char

        Nothing ->
            crash "Error on unsafeIndex!"


isWord : String -> Int -> Int -> Char -> Bool
isWord src pos end word =
    pos < end && unsafeIndex src pos == word


getCharWidth : Char -> Int
getCharWidth word =
    if Char.toCode word > 0xFFFF then
        2

    else
        1



-- ENCODERS and DECODERS


snippetEncoder : Snippet -> Bytes.Encode.Encoder
snippetEncoder (Snippet { fptr, offset, length, offRow, offCol }) =
    Bytes.Encode.sequence
        [ BE.string fptr
        , BE.int offset
        , BE.int length
        , BE.int offRow
        , BE.int offCol
        ]


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



-- LOOP


type Step state a
    = Loop state
    | Done a


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
