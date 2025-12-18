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

{-| A parser combinator library for building text parsers.

This module provides a monadic parser type and combinators for building
parsers from smaller pieces. The parser type supports backtracking,
position tracking, and error reporting. The API is inspired by Haskell's
Attoparsec library.

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


# Utilities

-}

import Set exposing (Set)


{-| A position in the input text, tracking line and column numbers.
-}
type Position
    = Position Int Int


{-| Compare two positions for ordering.
-}
comparePositions : Position -> Position -> Basics.Order
comparePositions (Position ln1 cn1) (Position ln2 cn2) =
    if ln1 > ln2 then
        GT

    else if ln1 == ln2 then
        compare cn1 cn2

    else
        LT



-- the String indicates what the parser was expecting


{-| A parse error with position information and expected content description.
-}
type ParseError
    = ParseError Position String


{-| Convert a parse error to a human-readable error message.
-}
showParseError : ParseError -> String
showParseError (ParseError (Position ln cn) msg) =
    "ParseError (line " ++ String.fromInt ln ++ " column " ++ String.fromInt cn ++ ") " ++ msg


{-| Internal parser state tracking the input string, current position, and last character read.
-}
type ParserState
    = ParserState
        { subject : String
        , position : Position
        , lastChar : Maybe Char
        }


{-| Advance the parser state by consuming a string from the input.
Updates position tracking based on newlines and character count.
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


{-| A parser that consumes input and produces a result or an error.
-}
type Parser a
    = Parser (ParserState -> Result ParseError ( ParserState, a ))



-- instance Functor Parser where


{-| Transform the result of a parser using a function.
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



-- instance Applicative Parser where


{-| Lift a value into the parser context without consuming input.
-}
pure : a -> Parser a
pure x =
    Parser (\st -> Ok ( st, x ))


{-| Apply a parser returning a function to a parser returning a value.
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


{-| Execute the parser only if the condition is false. Returns unit if condition is true.
-}
unless : Bool -> Parser () -> Parser ()
unless p s =
    if p then
        pure ()

    else
        s


{-| Sequence two parsers, keeping only the result of the first.
Equivalent to (<\*) in Haskell.
-}
leftSequence : Parser a -> Parser b -> Parser a
leftSequence p1 p2 =
    p1 |> andThen (\res -> p2 |> map (\_ -> res))



-- instance Alternative Parser where


{-| A parser that always fails.
-}
empty : Parser a
empty =
    Parser (\(ParserState st) -> Err (ParseError st.position "(empty)"))


{-| Succeed only if the boolean condition is true.
-}
guard : Bool -> Parser ()
guard bool =
    if bool then
        pure ()

    else
        empty


{-| Try the first parser, and if it fails, try the second parser.
Returns the result of whichever parser succeeds first.
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
                                -- return error for farthest match
                                (case comparePositions pos pos_ of
                                    LT ->
                                        ParseError pos_ msg_

                                    GT ->
                                        ParseError pos msg

                                    EQ ->
                                        ParseError pos (msg ++ " or " ++ msg_)
                                )
        )



-- instance Monad Parser where


{-| Lift a value into the parser context without consuming input.
Alias for pure.
-}
return : a -> Parser a
return x =
    Parser (\st -> Ok ( st, x ))


{-| Sequence two parsers, passing the result of the first to a function that produces the second.
Monadic bind operation.
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



-- instance MonadFail Parser where


{-| Create a parser that always fails with the given error message.
-}
fail : String -> Parser a
fail e =
    Parser (\(ParserState st) -> Err (ParseError st.position e))



-- instance MonadPlus Parser where


{-| A parser that always fails with a generic error.
-}
mzero : Parser a
mzero =
    Parser (\(ParserState st) -> Err (ParseError st.position "(mzero)"))


{-| Run a parser on an input string, returning either an error or the result.
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


{-| Create a failed parse result with the given error message at the current position.
-}
failure : ParserState -> String -> Result ParseError ( ParserState, a )
failure (ParserState st) msg =
    Err (ParseError st.position msg)


{-| Create a successful parse result with the given state and value.
-}
success : ParserState -> a -> Result ParseError ( ParserState, a )
success st x =
    Ok ( st, x )


{-| Parse a character that satisfies the given predicate.
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


{-| Look ahead at the next character without consuming it.
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


{-| Get the last character that was consumed by the parser.
-}
peekLastChar : Parser (Maybe Char)
peekLastChar =
    Parser (\(ParserState st) -> success (ParserState st) st.lastChar)


{-| Succeed only if the last consumed character does not satisfy the predicate.
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



-- low-grade version of attoparsec's:


{-| Parse a character class specification into a set of characters.
Supports range notation like "a-z" for character ranges.
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


{-| Check if a character is in the specified character class.
-}
inClass : String -> Char -> Bool
inClass s c =
    let
        s_ : Set Char
        s_ =
            charClass s
    in
    Set.member c s_


{-| Check if a character is NOT in the specified character class.
-}
notInClass : String -> Char -> Bool
notInClass s =
    inClass s >> not


{-| Succeed only at the end of input.
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


{-| Parse a specific character.
-}
char : Char -> Parser Char
char c =
    satisfy ((==) c)


{-| Parse any single character.
-}
anyChar : Parser Char
anyChar =
    satisfy (\_ -> True)


{-| Get the current position in the input.
-}
getPosition : Parser Position
getPosition =
    Parser (\(ParserState st) -> success (ParserState st) st.position)


{-| Extract the column number from a position.
-}
column : Position -> Int
column (Position _ cn) =
    cn



-- note: this does not actually change the position in the subject;
-- it only changes what column counts as column N.  It is intended
-- to be used in cases where we're parsing a partial line but need to
-- have accurate column information.


{-| Set the current position for column tracking.
Does not change the actual position in the input, only the column counter.
-}
setPosition : Position -> Parser ()
setPosition pos =
    Parser (\(ParserState st) -> success (ParserState { st | position = pos }) ())


{-| Parse zero or more characters satisfying the predicate.
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


{-| Parse characters until the predicate is satisfied.
-}
takeTill : (Char -> Bool) -> Parser String
takeTill f =
    takeWhile (not << f)


{-| Parse one or more characters satisfying the predicate.
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


{-| Parse all remaining input.
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


{-| Parse and discard a single character satisfying the predicate.
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


{-| Parse and discard zero or more characters satisfying the predicate.
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


{-| Parse an exact string.
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


{-| Parse using a stateful scanner function.
The scanner function takes the current state and next character, returning either
a new state (to continue) or Nothing (to stop).
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


{-| Parse without consuming input.
Runs the parser and returns its result, but restores the original parser state.
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


{-| Succeed only if the given parser fails.
Negative lookahead that consumes no input.
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



-- combinators (definitions borrowed from attoparsec)


{-| Try to parse, returning a default value if the parser fails.
-}
option : a -> Parser a -> Parser a
option x p =
    oneOf p (pure x)


{-| Parse occurrences of the first parser until the second parser succeeds.
-}
manyTill : Parser a -> Parser b -> Parser (List a)
manyTill p end =
    let
        go : () -> Parser (List a)
        go () =
            oneOf (end |> andThen (\_ -> pure [])) (liftA2 (::) p (lazy go))
    in
    go ()


{-| Parse exactly n occurrences.
-}
count : Int -> Parser a -> Parser (List a)
count n p =
    sequence (List.repeat n p)



-- ...


{-| Create a lazy parser for recursive definitions.
-}
lazy : (() -> Parser a) -> Parser a
lazy f =
    pure () |> andThen f


{-| Parse zero or more occurrences.
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


{-| Lift a binary function to work on parser results.
-}
liftA2 : (a -> b -> c) -> Parser a -> Parser b -> Parser c
liftA2 f pa pb =
    pa
        |> map f
        |> andThen (\fApplied -> map fApplied pb)


{-| Run a list of parsers in sequence and collect their results.
-}
sequence : List (Parser a) -> Parser (List a)
sequence parsers =
    case parsers of
        [] ->
            pure []

        p :: ps ->
            liftA2 (::) p (sequence ps)


{-| Take characters from a string while they satisfy the predicate.
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
