module Compiler.Parse.Primitives exposing
    ( Parser(..), PStep(..), State(..), StateData
    , pure, map, andThen, oneOf, oneOfWithFallback, loop
    , Row, Col, getPosition, addLocation, addEnd
    , withIndent, withBacksetIndent
    , inContext, specialize
    , fromByteString, fromSnippet, Snippet
    , word1, word2, unsafeIndex, isWord, getCharWidth
    , Step(..)
    )

{-| This module is the parser library the compiler's own parsers are written
in: a parser type, the combinators that build larger parsers from smaller ones,
and the functions that run them. Its central idea is that a parser reports not
only whether it succeeded but also whether it consumed any input before it
finished, and that second fact decides when another alternative may still be
tried.

A _parser_ is a function from a `State` to a `PStep`. The state is the text
being parsed, where the parser has got to in it, and the current indent. The
position is kept in two forms. `pos` and `end` are indices into the text in the
units `String.slice` uses, which are not bytes: a character above U+FFFF takes
two of them, as `getCharWidth` says. `row` and `col` are a line and a column
number, and both start from 1. A region recorded by `addLocation` ends at the
position just after its last character.

A parser's outcome answers two questions: did it succeed, and had it consumed
input by the time it finished? `Cok` and `Cerr` report success and failure after
consuming input; `Eok` and `Eerr` report that nothing was consumed, called
_empty_. The report is the parser's own and nothing checks it against the
position. `oneOf` tries its next alternative only after an `Eerr`. Once an
alternative reports that it consumed input, its result stands, success or
failure, so a choice commits to that branch. `loop` and `inContext` keep this
record across the parsers they run in sequence: once anything has been
consumed, a later empty outcome is reported as consumed.
`andThen` does so for success only. When its first parser consumed and its
second gives `Eerr`, the result is still `Eerr`, so an enclosing `oneOf` moves
on to its next alternative from where it started.

A failure carries its error as a function of a row and a column, together with
the row and column to give it. `specialize` and `inContext` wrap a failure in
the error of an enclosing construct: the inner error is given the row and
column its failure carries, and the wrapping error is placed where the
construct started.

The _indent_ is the column a layout-sensitive construct is measured against. It
is 0 when parsing starts, and `withIndent` and `withBacksetIndent` set it for a
nested parser; the checks made against it are in `Compiler.Parse.Space`.

`fromByteString` and `fromSnippet` run a parser over a text, and treat a parse
that succeeds without reaching the end of its input as a failure, a _bad end_.
`word1` and `word2` are parsers for one or two fixed characters. `unsafeIndex`,
`isWord` and `getCharWidth` are for parsers written directly as functions on
the state instead of being built from the combinators.


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

@docs fromByteString, fromSnippet, Snippet


# Character Utilities

@docs word1, word2, unsafeIndex, isWord, getCharWidth


# Loop Control

@docs Step

-}

import Compiler.AST.Snippet as Snippet
import Compiler.Reporting.Annotation as A
import Utils.Crash exposing (crash)



-- ====== PARSER ======


{-| A parser that produces a value of type `a` or fails with an error of type
`x`.

Running one on a state gives a `PStep`, which says whether it succeeded and
whether it consumed input. The constructor is exposed, so a scanner can be
written directly as a function on the state.

-}
type Parser x a
    = Parser (State -> PStep x a)


{-| The outcome of running a parser once: success or failure, each either after
consuming input or with nothing consumed.

`Cok` and `Eok` carry the value and the state to continue from. `Cok` reports
that input was consumed and `Eok` that none was. A parser written directly on
the state chooses which to give, and nothing checks it; some give `Cok` having
consumed nothing.

`Cerr` and `Eerr` carry a row, a column and a function that builds the error
from a row and a column; the error is that function given that row and column.
`Cerr` reports that input was consumed before the failure, which stops `oneOf`
from trying another alternative. `Eerr` reports that none was, and leaves
`oneOf` free to try the next one. Neither carries a state, so a failure gives no
position to continue from.

-}
type PStep x a
    = Cok a State
    | Eok a State
    | Cerr Row Col (Row -> Col -> x)
    | Eerr Row Col (Row -> Col -> x)


{-| Where a parser has got to in its text.

`pos` and `end` are indices into `src` in the units `String.slice` uses, not
bytes. `end` is where the input stops, which for a snippet can be before the
end of `src`. `indent` is the column a layout-sensitive construct is measured
against. `row` and `col` count from 1.

-}
type alias StateData =
    { src : String
    , pos : Int
    , end : Int
    , indent : Int
    , row : Row
    , col : Col
    }


{-| The state a parser receives and passes on: the text, the position in it and
the current indent, as `StateData` describes.

The constructor is exposed, and nothing checks that the fields agree with one
another, for example that `pos` is no greater than `end`.

-}
type State
    = State StateData


{-| A line number, counted from 1.

This is a name for `Int`, not a new type, and the compiler checks nothing about
the values given where a `Row` is expected.

-}
type alias Row =
    Int


{-| A column number within a line, counted from 1.

This is a name for `Int`, not a new type, and the compiler checks nothing about
the values given where a `Col` is expected.

-}
type alias Col =
    Int



-- ====== FUNCTOR ======


{-| Produces a parser that runs `parser` and applies `f` to its value. Whether
input was consumed, and any failure, are unchanged.
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


{-| Produces a parser that tries `parsers` in order, each from the same
starting state, and gives the outcome of the first one that does not fail empty.

A parser whose outcome says it consumed input ends the choice, whether it
succeeded or failed. When every parser gives `Eerr`, or the list is empty, the
result is an `Eerr` built from `toError` at the starting position, and the
errors of the alternatives are discarded.

-}
oneOf : (Row -> Col -> x) -> List (Parser x a) -> Parser x a
oneOf toError parsers =
    Parser
        (\state ->
            oneOfHelp state toError parsers
        )


{-| Returns the outcome of the first of `parsers` that does not give `Eerr` when
run on `state`, or an `Eerr` built from `toError` at the position of `state`
when none is left.
-}
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


{-| Produces a parser that tries `parsers` as `oneOf` does, but succeeds with
`fallback`, consuming nothing, when every parser gives `Eerr`.

A parser whose outcome says it consumed input still ends the choice, so a
`Cerr` is returned as it is.

-}
oneOfWithFallback : List (Parser x a) -> a -> Parser x a
oneOfWithFallback parsers fallback =
    Parser (\state -> oowfHelp state parsers fallback)


{-| Returns the outcome of the first of `parsers` that does not give `Eerr` when
run on `state`, or `Eok fallback` at `state` when none is left.
-}
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


{-| Produces a parser that succeeds with `value` and consumes nothing.
-}
pure : a -> Parser x a
pure value =
    Parser (\state -> Eok value state)


{-| Produces a parser that runs the given parser, then runs the parser that
`callback` builds from its value, continuing from where the first stopped.

If the first parser consumed input, a success of the second is reported as
`Cok`. A failure of the second is passed on as it is, so `Eerr` after a
consuming first parser is still `Eerr`, and an enclosing `oneOf` will try its
next alternative.

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


{-| Runs a parser over the whole of `src`, starting at row 1, column 1 with an
indent of 0.

The result is `Ok` only if the parser succeeds and stops at the end of `src`.
A parser that succeeds earlier gives `toBadEnd` applied to the row and column
where it stopped. A failure gives its own error.

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


{-| Returns `Ok a` if the parser's final state is at the end of its input, and
otherwise `toBadEnd` applied to the row and column where it stopped.
-}
toOk : (Row -> Col -> x) -> a -> State -> Result x a
toOk toBadEnd a (State s) =
    if s.pos == s.end then
        Ok a

    else
        Err (toBadEnd s.row s.col)


{-| Returns the error of a failed parse: `toError` given `row` and `col`.
-}
toErr : Row -> Col -> (Row -> Col -> x) -> Result x a
toErr row col toError =
    Err (toError row col)



-- ====== FROM SNIPPET ======


{-| A piece of a source text given by its place in the whole text. This is
`Compiler.AST.Snippet.Snippet` under a name in this module, not a new type;
`Compiler.AST.Snippet` describes what it holds.
-}
type alias Snippet =
    Snippet.Snippet


{-| Runs a parser over the piece of text a snippet names, with an indent of 0.
It starts at the snippet's row and column, so positions are reported in the
whole text rather than in the piece.

As with `fromByteString`, the result is `Ok` only if the parser succeeds and
stops at the end of the piece; a parser that succeeds earlier gives
`toBadEnd` applied to the row and column where it stopped.

-}
fromSnippet : Parser x a -> (Row -> Col -> x) -> Snippet -> Result x a
fromSnippet (Parser parser) toBadEnd (Snippet.Snippet { fptr, offset, length, offRow, offCol }) =
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


{-| A parser that succeeds with the current row and column, consuming nothing.
-}
getPosition : Parser x A.Position
getPosition =
    Parser
        (\((State s) as state) ->
            Eok (A.Position s.row s.col) state
        )


{-| Produces a parser that runs the given parser and places its value at the
region it covered, from the position where it started to the position where it
stopped. Whether input was consumed, and any failure, are unchanged.
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


{-| Produces a parser that consumes nothing and succeeds with `value` placed at
the region from `start` to the current position.
-}
addEnd : A.Position -> a -> Parser x (A.Located a)
addEnd start value =
    Parser
        (\((State s) as state) ->
            Eok (A.at start (A.Position s.row s.col) value) state
        )



-- ====== INDENT ======


{-| Produces a parser that runs the given parser with the indent set to the
current column.

On success the indent is put back to what it was. A failure carries no state,
so there is nothing to put back.

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


{-| Produces a parser that runs the given parser with the indent set to the
current column minus `backset`.

On success the indent is put back to what it was. A failure carries no state,
so there is nothing to put back.

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


{-| Produces a parser for a construct that begins with the parser `start`,
whose value is discarded, followed by the given parser, whose value is the
result.

A failure of the second parser becomes the error `addContext` builds from the
inner error, given the row and column the failure carries, and is placed at
the position where `start` began. If `start` consumed input, the whole is
reported as consumed: an `Eok` becomes `Cok` and an `Eerr` becomes `Cerr`. A
failure of `start` itself is passed on unwrapped.

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


{-| Produces a parser that runs the given parser and turns its error into the
one `addContext` builds from it.

The inner error is given the row and column its failure carries, and the new
error is placed at the position where the parser started. Whether input was
consumed is unchanged.

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


{-| Produces a parser that consumes the character `word` if it is next, and
otherwise gives an `Eerr` built from `toError` at the current position.

It advances `pos` and `col` by one and leaves `row` alone, so `word` must be
neither a newline nor a character above U+FFFF.

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


{-| Produces a parser that consumes `w1` followed by `w2` if they are next, and
otherwise gives an `Eerr` built from `toError` at the current position.

It advances `pos` and `col` by two and leaves `row` alone, so neither character
may be a newline or a character above U+FFFF.

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


{-| Returns the character that starts at `index` in `str`, counting in the
units `String.slice` uses.

It crashes, through `Utils.Crash`, when `index` is at or past the end of
`str`. It checks nothing against a parser's `end`, so a caller reading a
snippet must check that bound itself, as `isWord` does.

-}
unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( char, _ ) ->
            char

        Nothing ->
            crash "Error on unsafeIndex!"


{-| Returns `True` when `pos` is before `end` and the character there is `word`.
-}
isWord : String -> Int -> Int -> Char -> Bool
isWord src pos end word =
    pos < end && unsafeIndex src pos == word


{-| Returns how many units of `pos` a character takes: 2 for a character above
U+FFFF and 1 for any other.
-}
getCharWidth : Char -> Int
getCharWidth word =
    if Char.toCode word > 0xFFFF then
        2

    else
        1



-- ====== LOOP ======


{-| What one round of `loop` decides: `Loop` carries the loop state for the
next round, and `Done` carries the result that ends the loop.
-}
type Step state a
    = Loop state
    | Done a


{-| Produces a parser that runs the parser `callback` builds from `loopState`,
and keeps running rounds on the state each `Loop` gives until a round gives
`Done` or fails.

Once any round has consumed input, the whole loop is reported as consumed: its
success is `Cok` and an empty failure of a later round becomes `Cerr`. Nothing
bounds the number of rounds, so a round that gives `Loop` without consuming must
move the loop state towards `Done`.

-}
loop : (state -> Parser x (Step state a)) -> state -> Parser x a
loop callback loopState =
    Parser
        (\state ->
            loopHelp callback state loopState Eok Eerr
        )


{-| Runs rounds of `loop` from `state` and `loopState`. `eok` and `eerr` build
the outcome of a round that ends the loop with nothing consumed in that round;
they are `Eok` and `Eerr` until a round consumes, and `Cok` and `Cerr` after.
-}
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
