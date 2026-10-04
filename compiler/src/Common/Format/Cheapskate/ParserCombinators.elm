module Common.Format.Cheapskate.ParserCombinators exposing
    ( Position(..)
    , ParseError(..), showParseError
    , ParserState(..)
    , Parser(..), parse
    , satisfy, char, anyChar, string, endOfInput
    , notInClass
    , takeWhile, takeWhile1, takeTill, takeText
    , skip, skipWhile
    , peekChar, notAfter
    , getPosition, setPosition, column
    , map, pure, apply, return, andThen
    , oneOf, option, many, manyTill
    , lookAhead, notFollowedBy
    , count
    , leftSequence, unless
    , scan, lazy
    , mzero, fail, guard
    )

{-| A small parser combinator library over `String`, modelled on Haskell's
attoparsec, in which the Cheapskate Markdown parser is written. It is separate
from the parser the compiler uses for Elm source.

A `Parser a` is a function from a `ParserState` to either a `ParseError` or the
new state paired with a result. The state holds the _subject_, which is the part
of the input not yet consumed, the `Position` of the subject's first character,
and the character most recently consumed. Positions start at line 1, column 1.
A newline moves to column 1 of the next line, and every other character, a tab
included, moves one column on.

A parser that fails leaves no trace. `oneOf` runs its second parser from the
state its first parser started in, however much input the first consumed before
failing, and `option` and `many` undo a failed attempt in the same way, so there
is no separate combinator for backtracking.

A `ParseError` records where the failure was reported and a short description
of the failure, usually of what was expected. When both parsers given to `oneOf`
fail, the error with the later position is kept, and at equal positions the two
descriptions are joined with " or ".

@docs Position
@docs ParseError, showParseError
@docs ParserState
@docs Parser, parse


# Basic Parsers

@docs satisfy, char, anyChar, string, endOfInput


# Character Classes

@docs notInClass


# Taking Input

@docs takeWhile, takeWhile1, takeTill, takeText


# Skipping Input

@docs skip, skipWhile


# Peeking and Position

@docs peekChar, notAfter
@docs getPosition, setPosition, column


# Combinators

@docs map, pure, apply, return, andThen
@docs oneOf, option, many, manyTill
@docs lookAhead, notFollowedBy
@docs count
@docs leftSequence, unless


# Advanced Parsers

@docs scan, lazy


# Control Flow

@docs mzero, fail, guard

-}

import Set exposing (Set)


{-| A place in the input: a line number, then a column number, both counting
from 1.

A newline moves to column 1 of the next line, and any other character, a tab
included, moves one column on. `setPosition` can relabel the current place, so
a position is not necessarily counted from the start of the text given to
`parse`.

-}
type Position
    = Position Int Int


{-| Orders two positions by line, and by column within the same line.
-}
comparePositions : Position -> Position -> Basics.Order
comparePositions (Position ln1 cn1) (Position ln2 cn2) =
    if ln1 > ln2 then
        GT

    else if ln1 == ln2 then
        compare cn1 cn2

    else
        LT


{-| A failed parse: the position at which the failure was reported, and a short
description of the failure, usually of what was expected there.

The description is fixed for each primitive, such as "end of input" or
"string", and does not name the character or string that was wanted. A failure
made with `fail` carries the message it was given instead.

-}
type ParseError
    = ParseError Position String


{-| Returns a one-line message giving the error's line, column and description.
-}
showParseError : ParseError -> String
showParseError (ParseError (Position ln cn) msg) =
    "ParseError (line " ++ String.fromInt ln ++ " column " ++ String.fromInt cn ++ ") " ++ msg


{-| The state of a parse in progress.

`subject` is the input not yet consumed, not the whole input. `position` is the
place of the first character of `subject`. `lastChar` is the character most
recently consumed, and `Nothing` before anything has been consumed; it is what
`notAfter` tests.

-}
type ParserState
    = ParserState
        { subject : String
        , position : Position
        , lastChar : Maybe Char
        }


{-| Returns the state after consuming `str` from the front of the subject. The
position moves on by each character of `str`, and the last character of `str`
becomes the last character consumed; an empty `str` changes nothing.

`str` must be a prefix of the subject, and nothing checks that. The subject is
shortened with `String.dropLeft 1` once per `Char`, and `String.dropLeft` counts
UTF-16 code units, so in the JavaScript build a character outside the Basic
Multilingual Plane leaves half of itself in the subject.

-}
advance : ParserState -> String -> ParserState
advance parserState str =
    let
        go : Char -> ParserState -> ParserState
        go c (ParserState st) =
            let
                (Position line _) =
                    st.position
            in
            ParserState
                { subject = String.dropLeft 1 st.subject
                , position =
                    case c of
                        '\n' ->
                            Position (line + 1) 1

                        _ ->
                            Position line (column st.position + 1)
                , lastChar = Just c
                }
    in
    List.foldl go parserState (String.toList str)


{-| A parser producing a value of type `a`: a function from the state before
parsing to either a `ParseError` or the state after the input it consumed,
paired with the result.

The constructor is exposed, so a parser can be written directly as such a
function, though the primitives and combinators here are the usual way to build
one.

-}
type Parser a
    = Parser (ParserState -> Result ParseError ( ParserState, a ))


{-| Produces a parser that runs the given parser and applies `f` to its result.
-}
map : (a -> b) -> Parser a -> Parser b
map f (Parser g) =
    Parser
        (\st ->
            case g st of
                Ok ( st_, x ) ->
                    Ok ( st_, f x )

                Err e ->
                    Err e
        )


{-| Produces a parser that consumes nothing and returns `x`.
-}
pure : a -> Parser a
pure x =
    Parser (\st -> Ok ( st, x ))


{-| Produces a parser that runs the function parser (the second argument), then
the argument parser (the first), and applies the function to the argument.

The argument parser comes first so that applications can be piped:
`pure f |> apply pa |> apply pb` runs `pa` and then `pb`, and returns
`f a b`.

-}
apply : Parser a -> Parser (a -> b) -> Parser b
apply (Parser g) (Parser f) =
    Parser
        (\st ->
            case f st of
                Err e ->
                    Err e

                Ok ( st_, h ) ->
                    case g st_ of
                        Ok ( st__, x ) ->
                            Ok ( st__, h x )

                        Err e ->
                            Err e
        )


{-| Returns a parser that succeeds with `()`, consuming nothing, when `p` is
`True`, and is `s` when `p` is `False`.
-}
unless : Bool -> Parser () -> Parser ()
unless p s =
    if p then
        pure ()

    else
        s


{-| Produces a parser that runs `p1` and then `p2`, and returns the result of
`p1`. It is attoparsec's `<*`.
-}
leftSequence : Parser a -> Parser b -> Parser a
leftSequence p1 p2 =
    p1 |> andThen (\res -> p2 |> map (\_ -> res))


{-| A parser that always fails, consuming nothing, with the description
"(empty)".
-}
empty : Parser a
empty =
    Parser (\(ParserState st) -> Err (ParseError st.position "(empty)"))


{-| Produces a parser that succeeds with `()`, consuming nothing, when `bool` is
`True`, and fails when it is `False`.
-}
guard : Bool -> Parser ()
guard bool =
    if bool then
        pure ()

    else
        empty


{-| Produces a parser that runs the first parser and, if it fails, runs the
second from the state the first started in, whatever the first consumed before
failing.

When both fail, the error with the later position is returned. At equal
positions the two descriptions are joined with " or ".

-}
oneOf : Parser a -> Parser a -> Parser a
oneOf (Parser f) (Parser g) =
    Parser
        (\st ->
            case f st of
                Ok res ->
                    Ok res

                Err (ParseError pos msg) ->
                    case g st of
                        Ok res ->
                            Ok res

                        Err (ParseError pos_ msg_) ->
                            Err
                                (case comparePositions pos pos_ of
                                    LT ->
                                        ParseError pos_ msg_

                                    GT ->
                                        ParseError pos msg

                                    EQ ->
                                        ParseError pos (msg ++ " or " ++ msg_)
                                )
        )


{-| Produces a parser that consumes nothing and returns `x`. It is the same as
`pure`.
-}
return : a -> Parser a
return x =
    Parser (\st -> Ok ( st, x ))


{-| Produces a parser that runs the given parser, passes its result to `g`, and
then runs the parser `g` returns from where the first one stopped.
-}
andThen : (a -> Parser b) -> Parser a -> Parser b
andThen g (Parser p) =
    Parser
        (\st ->
            case p st of
                Err e ->
                    Err e

                Ok ( st_, x ) ->
                    let
                        (Parser evalParser) =
                            g x
                    in
                    evalParser st_
        )


{-| Produces a parser that always fails at the current position, consuming
nothing, with `e` as the error's description.
-}
fail : String -> Parser a
fail e =
    Parser (\(ParserState st) -> Err (ParseError st.position e))


{-| A parser that always fails, consuming nothing, with the description
"(mzero)".
-}
mzero : Parser a
mzero =
    Parser (\(ParserState st) -> Err (ParseError st.position "(mzero)"))


{-| Runs a parser on `t`, starting at line 1, column 1, and returns its result
or its error.

The parser need not consume all of `t`; whatever it leaves is ignored. To
require the whole input, end the parser with `endOfInput`.

-}
parse : Parser a -> String -> Result ParseError a
parse (Parser evalParser) t =
    Result.map Tuple.second
        (evalParser
            (ParserState
                { subject = t
                , position = Position 1 1
                , lastChar = Nothing
                }
            )
        )


{-| Returns a failure at the position of the given state, with `msg` as its
description.
-}
failure : ParserState -> String -> Result ParseError ( ParserState, a )
failure (ParserState st) msg =
    Err (ParseError st.position msg)


{-| Returns a success that continues from `st` with the result `x`.
-}
success : ParserState -> a -> Result ParseError ( ParserState, a )
success st x =
    Ok ( st, x )


{-| Produces a parser that consumes and returns the next character if `f`
accepts it. It fails when `f` rejects the character and at the end of input.
-}
satisfy : (Char -> Bool) -> Parser Char
satisfy f =
    let
        g : ParserState -> Result ParseError ( ParserState, Char )
        g (ParserState st) =
            case String.uncons st.subject of
                Just ( c, _ ) ->
                    if f c then
                        success (advance (ParserState st) (String.fromChar c)) c

                    else
                        failure (ParserState st) "character meeting condition"

                _ ->
                    failure (ParserState st) "character meeting condition"
    in
    Parser g


{-| A parser that returns the next character without consuming it, or `Nothing`
at the end of input. It never fails.
-}
peekChar : Parser (Maybe Char)
peekChar =
    Parser
        (\(ParserState st) ->
            case String.uncons st.subject of
                Just ( c, _ ) ->
                    success (ParserState st) (Just c)

                Nothing ->
                    success (ParserState st) Nothing
        )


{-| A parser that returns the character most recently consumed, or `Nothing` if
nothing has been consumed yet. It consumes nothing and never fails.
-}
peekLastChar : Parser (Maybe Char)
peekLastChar =
    Parser (\(ParserState st) -> success (ParserState st) st.lastChar)


{-| Produces a parser that consumes nothing and succeeds unless the character
most recently consumed satisfies `f`, in which case it fails. At the start of
the input, before anything has been consumed, it succeeds.

Only consumed characters count. A character that was examined and then given
back, by `lookAhead`, `notFollowedBy`, `peekChar` or a failed alternative, is
not the last character consumed.

-}
notAfter : (Char -> Bool) -> Parser ()
notAfter f =
    peekLastChar
        |> andThen
            (\mbc ->
                case mbc of
                    Nothing ->
                        return ()

                    Just c ->
                        if f c then
                            mzero

                        else
                            return ()
            )


{-| Returns the set of characters named by a character class specification,
a simplified form of attoparsec's class syntax.

The specification is a string of characters, in which a character, `-` and a
second character, such as `a-z`, stand for every character from the first to
the second inclusive, and for none if the second comes before the first. A `-`
that does not form such a range stands for itself.

-}
charClass : String -> Set Char
charClass =
    let
        go : List Char -> List Char
        go str =
            case str of
                a :: '-' :: b :: xs ->
                    List.map Char.fromCode (List.range (Char.toCode a) (Char.toCode b)) ++ go xs

                x :: xs ->
                    x :: go xs

                _ ->
                    []
    in
    String.toList >> go >> Set.fromList


{-| Returns `True` when `c` is in the character class `s`, written in the syntax
`notInClass` describes. The class is built from `s` afresh on every call.
-}
inClass : String -> Char -> Bool
inClass s c =
    let
        s_ : Set Char
        s_ =
            charClass s
    in
    Set.member c s_


{-| Returns `True` when a character is not in the character class `s`.

A class is written as a string of its characters, in which a character, `-` and
a second character, such as `a-z`, stand for every character from the first to
the second inclusive, and for none if the second comes before the first. A `-`
that does not form such a range stands for itself.

-}
notInClass : String -> Char -> Bool
notInClass s =
    inClass s >> not


{-| A parser that succeeds, consuming nothing, only when no input is left.
-}
endOfInput : Parser ()
endOfInput =
    Parser
        (\(ParserState st) ->
            if String.isEmpty st.subject then
                success (ParserState st) ()

            else
                failure (ParserState st) "end of input"
        )


{-| Produces a parser that consumes and returns `c` if it is the next
character, and fails otherwise.
-}
char : Char -> Parser Char
char c =
    satisfy ((==) c)


{-| A parser that consumes and returns the next character. It fails only at the
end of input.
-}
anyChar : Parser Char
anyChar =
    satisfy (\_ -> True)


{-| A parser that returns the current `Position` without consuming anything.
-}
getPosition : Parser Position
getPosition =
    Parser (\(ParserState st) -> success (ParserState st) st.position)


{-| Returns the column of a position.
-}
column : Position -> Int
column (Position _ cn) =
    cn


{-| Produces a parser that relabels the current place in the input as `pos`,
consuming nothing.

The input does not move. Only the numbering changes: lines and columns from
here on are counted onwards from `pos`. This lets a parser that is given part of
a line report the columns that part has in the whole line.

-}
setPosition : Position -> Parser ()
setPosition pos =
    Parser (\(ParserState st) -> success (ParserState { st | position = pos }) ())


{-| Produces a parser that consumes and returns the longest prefix of the
remaining input whose characters all satisfy `f`. It never fails, and returns
`""` when the next character does not satisfy `f`.
-}
takeWhile : (Char -> Bool) -> Parser String
takeWhile f =
    Parser
        (\(ParserState st) ->
            let
                t : String
                t =
                    stringTakeWhile f st.subject
            in
            success (advance (ParserState st) t) t
        )


{-| Produces a parser that consumes and returns everything before the first
character that satisfies `f`, or the rest of the input if none does. It never
fails.
-}
takeTill : (Char -> Bool) -> Parser String
takeTill f =
    takeWhile (not << f)


{-| Produces a parser that consumes and returns the longest prefix of the
remaining input whose characters all satisfy `f`, and fails, consuming nothing,
when that prefix would be empty.
-}
takeWhile1 : (Char -> Bool) -> Parser String
takeWhile1 f =
    Parser
        (\(ParserState st) ->
            let
                t : String
                t =
                    stringTakeWhile f st.subject
            in
            if String.isEmpty t then
                failure (ParserState st) "characters satisfying condition"

            else
                success (advance (ParserState st) t) t
        )


{-| A parser that consumes and returns all the remaining input. It never fails.
-}
takeText : Parser String
takeText =
    Parser
        (\(ParserState st) ->
            let
                t : String
                t =
                    st.subject
            in
            success (advance (ParserState st) t) t
        )


{-| Produces a parser that consumes the next character if `f` accepts it. It
fails when `f` rejects the character and at the end of input.
-}
skip : (Char -> Bool) -> Parser ()
skip f =
    Parser
        (\(ParserState st) ->
            case String.uncons st.subject of
                Just ( c, _ ) ->
                    if f c then
                        success (advance (ParserState st) (String.fromChar c)) ()

                    else
                        failure (ParserState st) "character satisfying condition"

                _ ->
                    failure (ParserState st) "character satisfying condition"
        )


{-| Produces a parser that consumes the longest prefix of the remaining input
whose characters all satisfy `f`. It never fails.
-}
skipWhile : (Char -> Bool) -> Parser ()
skipWhile f =
    Parser
        (\(ParserState st) ->
            let
                t_ : String
                t_ =
                    stringTakeWhile f st.subject
            in
            success (advance (ParserState st) t_) ()
        )


{-| Produces a parser that consumes and returns `s` if the remaining input
starts with it, and fails otherwise.
-}
string : String -> Parser String
string s =
    Parser
        (\(ParserState st) ->
            if String.startsWith s st.subject then
                success (advance (ParserState st) s) s

            else
                failure (ParserState st) "string"
        )


{-| Produces a parser that consumes characters for as long as a scanner accepts
them, and returns the characters consumed.

The scanner `f` is given its state, starting at `s0`, and the next character.
It returns the next state to accept the character and go on, or `Nothing` to
stop before it. The parser also stops at the end of input, and never fails.

-}
scan : s -> (s -> Char -> Maybe s) -> Parser String
scan s0 f =
    let
        go : s -> String -> ParserState -> Result ParseError ( ParserState, String )
        go s cs (ParserState st) =
            case String.uncons st.subject of
                Nothing ->
                    finish (ParserState st) cs

                Just ( c, _ ) ->
                    case f s c of
                        Just s_ ->
                            go s_
                                (String.cons c cs)
                                (advance (ParserState st) (String.fromChar c))

                        Nothing ->
                            finish (ParserState st) cs

        finish : ParserState -> String -> Result ParseError ( ParserState, String )
        finish st cs =
            success st (String.reverse cs)
    in
    Parser (go s0 "")


{-| Produces a parser that runs `p` and returns its result, but leaves the input
where it was.

If `p` fails, this fails at the starting position with the description
"lookAhead", and `p`'s own error is discarded.

-}
lookAhead : Parser a -> Parser a
lookAhead (Parser p) =
    Parser
        (\st ->
            case p st of
                Ok ( _, x ) ->
                    success st x

                Err _ ->
                    failure st "lookAhead"
        )


{-| Produces a parser that consumes nothing and succeeds exactly when `p` fails
at the current place in the input. When `p` succeeds, this fails there with the
description "notFollowedBy".
-}
notFollowedBy : Parser a -> Parser ()
notFollowedBy (Parser p) =
    Parser
        (\st ->
            case p st of
                Ok _ ->
                    failure st "notFollowedBy"

                Err _ ->
                    success st ()
        )


{-| Produces a parser that runs `p` and, if it fails, returns `x` from where `p`
started.
-}
option : a -> Parser a -> Parser a
option x p =
    oneOf p (pure x)


{-| Produces a parser that runs `p` repeatedly until `end` succeeds, and returns
the results of `p` in order.

`end` is tried before each run of `p`, so the result is `[]` when `end` succeeds
at once. The input `end` matches is consumed and its result discarded. The
parser fails when, at some step, `end` and `p` both fail.

-}
manyTill : Parser a -> Parser b -> Parser (List a)
manyTill p end =
    let
        go : () -> Parser (List a)
        go () =
            oneOf (end |> andThen (\_ -> pure [])) (liftA2 (::) p (lazy go))
    in
    go ()


{-| Produces a parser that runs `p` `n` times in sequence and returns the `n`
results. When `n` is zero or less it consumes nothing and returns `[]`.
-}
count : Int -> Parser a -> Parser (List a)
count n p =
    sequence (List.repeat n p)


{-| Produces a parser that obtains its parser by calling `f` only when it runs.
A recursive parser needs this, since it cannot otherwise refer to itself while
it is being defined.
-}
lazy : (() -> Parser a) -> Parser a
lazy f =
    pure () |> andThen f


{-| Produces a parser that runs the given parser until it fails, and returns the
results in order.

It never fails. The failing attempt is undone, whatever it consumed, and its
error is discarded. A parser that succeeds and returns the state it was given
would succeed again in the same way, so given one, `many` never stops.

-}
many : Parser a -> Parser (List a)
many (Parser p) =
    let
        accumulate : List a -> ParserState -> Result ParseError ( ParserState, List a )
        accumulate acc state =
            case p state of
                Ok ( st_, res ) ->
                    accumulate (res :: acc) st_

                Err _ ->
                    Ok ( state, List.reverse acc )
    in
    Parser (accumulate [])


{-| Produces a parser that runs `pa` and then `pb`, and combines their results
with `f`.
-}
liftA2 : (a -> b -> c) -> Parser a -> Parser b -> Parser c
liftA2 f pa pb =
    pa
        |> map f
        |> andThen (\fApplied -> map fApplied pb)


{-| Produces a parser that runs `parsers` one after another and returns their
results in the same order.
-}
sequence : List (Parser a) -> Parser (List a)
sequence parsers =
    case parsers of
        [] ->
            pure []

        p :: ps ->
            liftA2 (::) p (sequence ps)


{-| Returns the longest prefix of `str` whose characters all satisfy `f`.

It walks the whole of `str`, not just the prefix, so its cost grows with the
length of `str`.

-}
stringTakeWhile : (Char -> Bool) -> String -> String
stringTakeWhile f str =
    String.toList str
        |> List.foldl
            (\c ( found, acc ) ->
                if found && f c then
                    ( True, String.cons c acc )

                else
                    ( False, acc )
            )
            ( True, "" )
        |> Tuple.second
        |> String.reverse
