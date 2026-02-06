module Compiler.Json.Decode exposing
    ( Decoder
    , fromByteString
    , Error(..), Problem(..), DecodeExpectation(..), ParseError(..), StringProblem(..)
    , string, customString, int
    , list, nonEmptyList, pair
    , field, dict, pairs, KeyDecoder(..)
    , map, pure, apply, andThen, oneOf
    , failure, mapError
    )

{-| JSON decoding utilities for the Elm compiler.

This module provides a custom JSON decoder implementation with its own parser,
designed to decode compiler-specific data structures. It includes specialized
decoders for associative-list-backed dictionaries, EverySet, NonEmptyList, and
OneOrMore types, along with detailed error reporting for parse and decode failures.


# Decoder Type

@docs Decoder


# Running Decoders

@docs fromByteString


# Error Types

@docs Error, Problem, DecodeExpectation, ParseError, StringProblem


# Primitive Decoders

@docs string, customString, int


# Collection Decoders

@docs list, nonEmptyList, pair


# Object Decoders

@docs field, dict, pairs, KeyDecoder


# Compiler Type Decoders


# Combinators

@docs map, pure, apply, andThen, oneOf


# Error Handling

@docs failure, mapError

-}

import Compiler.Data.NonEmptyList as NE
import Compiler.Json.String as Json
import Compiler.Parse.Keyword as K
import Compiler.AST.Snippet as Snippet
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== CORE HELPERS ======
-- ====== RUNNERS ======


{-| Parse and decode a JSON string into a value.
Returns either a parse error or a decode error if unsuccessful.
-}
fromByteString : Decoder x a -> String -> Result (Error x) a
fromByteString (Decoder decode) src =
    case P.fromByteString pFile BadEnd src of
        Ok ast ->
            decode ast
                |> Result.mapError (DecodeProblem src)

        Err problem ->
            Err (ParseProblem src problem)



-- ====== DECODERS ======


{-| A JSON decoder that can produce values of type `a` or fail with custom errors of type `x`.
-}
type Decoder x a
    = Decoder (AST -> Result (Problem x) a)



-- ====== ERRORS ======


{-| Top-level error type for JSON decoding, containing either a decode problem or a parse error.
-}
type Error x
    = DecodeProblem String (Problem x)
    | ParseProblem String ParseError



-- ====== DECODE PROBLEMS ======


{-| Represents a decoding problem with context about where it occurred.
-}
type Problem x
    = Field String (Problem x)
    | Index Int (Problem x)
    | OneOf (Problem x) (List (Problem x))
    | Failure A.Region x
    | Expecting A.Region DecodeExpectation


{-| Describes what type of JSON value was expected during decoding.
-}
type DecodeExpectation
    = TObject
    | TArray
    | TString
    | TInt
    | TObjectWith String
    | TArrayPair Int



-- ====== INSTANCES ======


{-| Transform the value produced by a decoder.
-}
map : (a -> b) -> Decoder x a -> Decoder x b
map func (Decoder decodeA) =
    Decoder (Result.map func << decodeA)


{-| Create a decoder that always succeeds with the given value.
-}
pure : a -> Decoder x a
pure a =
    Decoder (\_ -> Ok a)


{-| Apply a decoder of a function to a decoder of an argument.
Useful for building up decoders in applicative style.
-}
apply : Decoder x a -> Decoder x (a -> b) -> Decoder x b
apply (Decoder decodeArg) (Decoder decodeFunc) =
    Decoder <|
        \ast ->
            decodeArg ast
                |> Result.andThen
                    (\a ->
                        Result.map (\b -> a |> b)
                            (decodeFunc ast)
                    )


{-| Chain decoders together, using the result of one decoder to determine the next decoder.
-}
andThen : (a -> Decoder x b) -> Decoder x a -> Decoder x b
andThen callback (Decoder decodeA) =
    Decoder <|
        \ast ->
            decodeA ast
                |> Result.andThen
                    (\a ->
                        case callback a of
                            Decoder decodeB ->
                                decodeB ast
                    )



-- ====== STRINGS ======


{-| Decode a JSON string value.
-}
string : Decoder x String
string =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                String snippet ->
                    Ok (Json.fromSnippet snippet)

                _ ->
                    Err (Expecting region TString)


{-| Decode a JSON string value and parse it using a custom parser.
Takes a parser and an error constructor for bad end-of-input.
-}
customString : P.Parser x a -> (Row -> Col -> x) -> Decoder x a
customString parser toBadEnd =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                String snippet ->
                    P.fromSnippet parser toBadEnd snippet
                        |> Result.mapError (Failure region)

                _ ->
                    Err (Expecting region TString)



-- ====== INT ======


{-| Decode a JSON integer value.
-}
int : Decoder x Int
int =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Int n ->
                    Ok n

                _ ->
                    Err (Expecting region TInt)



-- ====== LISTS ======


{-| Decode a JSON array into a list.
-}
list : Decoder x a -> Decoder x (List a)
list decoder =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Array asts ->
                    listHelp decoder 0 asts []

                _ ->
                    Err (Expecting region TArray)


listHelp : Decoder x a -> Int -> List AST -> List a -> Result (Problem x) (List a)
listHelp ((Decoder decodeA) as decoder) i asts revs =
    case asts of
        [] ->
            Ok (List.reverse revs)

        ast :: asts_ ->
            case decodeA ast of
                Ok value ->
                    listHelp decoder (i + 1) asts_ (value :: revs)

                Err prob ->
                    Err (Index i prob)



-- ====== NON-EMPTY LISTS ======


{-| Decode a JSON array into a non-empty list.
Fails with the provided error value if the array is empty.
-}
nonEmptyList : Decoder x a -> x -> Decoder x (NE.Nonempty a)
nonEmptyList decoder x =
    Decoder <|
        \((A.At region _) as ast) ->
            let
                (Decoder values) =
                    list decoder
            in
            case values ast of
                Ok (v :: vs) ->
                    Ok (NE.Nonempty v vs)

                Ok [] ->
                    Err (Failure region x)

                Err err ->
                    Err err



-- ====== PAIR ======


{-| Decode a JSON array with exactly two elements into a tuple.
Fails if the array does not contain exactly two elements.
-}
pair : Decoder x a -> Decoder x b -> Decoder x ( a, b )
pair (Decoder decodeA) (Decoder decodeB) =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Array vs ->
                    case vs of
                        [ astA, astB ] ->
                            decodeA astA
                                |> Result.andThen
                                    (\a ->
                                        Result.map (Tuple.pair a) (decodeB astB)
                                    )

                        _ ->
                            Err (Expecting region (TArrayPair (List.length vs)))

                _ ->
                    Err (Expecting region TArray)



-- ====== OBJECTS ======


{-| A decoder for JSON object keys.
Contains a parser to extract the key from a string snippet and an error constructor.
-}
type KeyDecoder x a
    = KeyDecoder (P.Parser x a) (Row -> Col -> x)


{-| Decode a JSON object into a dictionary.
Takes a function to convert keys to comparable values, a key decoder, and a value decoder.
-}
dict : (k -> comparable) -> KeyDecoder x k -> Decoder x a -> Decoder x (Dict comparable k a)
dict toComparable keyDecoder valueDecoder =
    map (Dict.fromList toComparable) (pairs keyDecoder valueDecoder)


{-| Decode a JSON object into a list of key-value pairs.
-}
pairs : KeyDecoder x k -> Decoder x a -> Decoder x (List ( k, a ))
pairs keyDecoder valueDecoder =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Object kvs ->
                    pairsHelp keyDecoder valueDecoder kvs []

                _ ->
                    Err (Expecting region TObject)


pairsHelp : KeyDecoder x k -> Decoder x a -> List ( Snippet.Snippet, AST ) -> List ( k, a ) -> Result (Problem x) (List ( k, a ))
pairsHelp ((KeyDecoder keyParser toBadEnd) as keyDecoder) ((Decoder decodeA) as valueDecoder) kvs revs =
    case kvs of
        [] ->
            Ok (List.reverse revs)

        ( snippet, ast ) :: kvs_ ->
            case P.fromSnippet keyParser toBadEnd snippet of
                Err x ->
                    Err (Failure (snippetToRegion snippet) x)

                Ok key ->
                    case decodeA ast of
                        Ok value ->
                            pairsHelp keyDecoder valueDecoder kvs_ (( key, value ) :: revs)

                        Err prob ->
                            let
                                (Snippet.Snippet { fptr, offset, length }) =
                                    snippet
                            in
                            Err (Field (String.slice offset (offset + length) fptr) prob)


snippetToRegion : Snippet.Snippet -> A.Region
snippetToRegion (Snippet.Snippet { length, offRow, offCol }) =
    A.Region (A.Position offRow offCol) (A.Position offRow (offCol + length))



-- ====== FIELDS ======


{-| Decode a specific field from a JSON object.
Fails if the object does not have the specified field.
-}
field : String -> Decoder x a -> Decoder x a
field key (Decoder decodeA) =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Object kvs ->
                    case findField key kvs of
                        Just value ->
                            Result.mapError (Field key)
                                (decodeA value)

                        Nothing ->
                            Err (Expecting region (TObjectWith key))

                _ ->
                    Err (Expecting region TObject)


findField : String -> List ( Snippet.Snippet, AST ) -> Maybe AST
findField key pairs_ =
    case pairs_ of
        [] ->
            Nothing

        ( Snippet.Snippet { fptr, offset, length }, value ) :: remainingPairs ->
            if key == String.slice offset (offset + length) fptr then
                Just value

            else
                findField key remainingPairs



-- ====== ONE OF ======


{-| Try a list of decoders in order, using the first one that succeeds.
Crashes if given an empty list.
-}
oneOf : List (Decoder x a) -> Decoder x a
oneOf decoders =
    Decoder <|
        \ast ->
            case decoders of
                (Decoder decodeA) :: decoders_ ->
                    case decodeA ast of
                        Ok a ->
                            Ok a

                        Err e ->
                            oneOfHelp ast decoders_ [] e

                [] ->
                    crash "Ran into (Json.Decode.oneOf [])"


oneOfHelp : AST -> List (Decoder x a) -> List (Problem x) -> Problem x -> Result (Problem x) a
oneOfHelp ast decoders ps p =
    case decoders of
        (Decoder decodeA) :: decoders_ ->
            case decodeA ast of
                Ok a ->
                    Ok a

                Err p_ ->
                    oneOfHelp ast decoders_ (p :: ps) p_

        [] ->
            Err (oneOfError [] p ps)


oneOfError : List (Problem x) -> Problem x -> List (Problem x) -> Problem x
oneOfError problems prob ps =
    case ps of
        [] ->
            OneOf prob problems

        p :: ps_ ->
            oneOfError (prob :: problems) p ps_



-- ====== FAILURE ======


{-| Create a decoder that always fails with the given error value.
-}
failure : x -> Decoder x a
failure x =
    Decoder <|
        \(A.At region _) ->
            Err (Failure region x)



-- ====== ERRORS ======


{-| Transform the error type of a decoder by applying a function to any custom errors.
-}
mapError : (x -> y) -> Decoder x a -> Decoder y a
mapError func (Decoder decodeA) =
    Decoder (Result.mapError (mapErrorHelp func) << decodeA)


mapErrorHelp : (x -> y) -> Problem x -> Problem y
mapErrorHelp func problem =
    case problem of
        Field k p ->
            Field k (mapErrorHelp func p)

        Index i p ->
            Index i (mapErrorHelp func p)

        OneOf p ps ->
            OneOf (mapErrorHelp func p) (List.map (mapErrorHelp func) ps)

        Failure r x ->
            Failure r (func x)

        Expecting r e ->
            Expecting r e



-- ====== AST ======


type alias AST =
    A.Located AST_


type AST_
    = Array (List AST)
    | Object (List ( Snippet.Snippet, AST ))
    | String Snippet.Snippet
    | Int Int
    | TRUE
    | FALSE
    | NULL



-- ====== PARSE ======


type alias Parser a =
    P.Parser ParseError a


{-| Errors that can occur while parsing JSON.
-}
type ParseError
    = Start Row Col
    | ObjectField Row Col
    | ObjectColon Row Col
    | ObjectEnd Row Col
    | ArrayEnd Row Col
    | StringProblem StringProblem Row Col
    | NoLeadingZeros Row Col
    | NoFloats Row Col
    | BadEnd Row Col


{-| Specific problems that can occur while parsing JSON string literals.
-}
type StringProblem
    = BadStringEnd
    | BadStringControlChar
    | BadStringEscapeChar
    | BadStringEscapeHex



-- ====== PARSE AST ======


pFile : Parser AST
pFile =
    spaces
        |> P.andThen (\_ -> pValue)
        |> P.andThen
            (\value ->
                P.map (\_ -> value) spaces
            )


pValue : Parser AST
pValue =
    P.addLocation <|
        P.oneOf Start
            [ P.map String (pString Start)
            , pObject
            , pArray
            , pInt
            , P.map (\_ -> TRUE) (K.k4 't' 'r' 'u' 'e' Start)
            , P.map (\_ -> FALSE) (K.k5 'f' 'a' 'l' 's' 'e' Start)
            , P.map (\_ -> NULL) (K.k4 'n' 'u' 'l' 'l' Start)
            ]



-- ====== OBJECT ======


pObject : Parser AST_
pObject =
    P.word1 '{' Start
        |> P.andThen (\_ -> spaces)
        |> P.andThen
            (\_ ->
                P.oneOf ObjectField
                    [ pField
                        |> P.andThen
                            (\entry ->
                                spaces
                                    |> P.andThen (\_ -> P.loop pObjectHelp [ entry ])
                            )
                    , P.word1 '}' ObjectEnd
                        |> P.map (\_ -> Object [])
                    ]
            )


pObjectHelp : List ( Snippet.Snippet, AST ) -> Parser (P.Step (List ( Snippet.Snippet, AST )) AST_)
pObjectHelp revEntries =
    P.oneOf ObjectEnd
        [ P.word1 ',' ObjectEnd
            |> P.andThen (\_ -> spaces)
            |> P.andThen (\_ -> pField)
            |> P.andThen
                (\entry ->
                    spaces
                        |> P.map (\_ -> P.Loop (entry :: revEntries))
                )
        , P.word1 '}' ObjectEnd
            |> P.map (\_ -> P.Done (Object (List.reverse revEntries)))
        ]


pField : Parser ( Snippet.Snippet, AST )
pField =
    pString ObjectField
        |> P.andThen
            (\key ->
                spaces
                    |> P.andThen (\_ -> P.word1 ':' ObjectColon)
                    |> P.andThen (\_ -> spaces)
                    |> P.andThen (\_ -> pValue)
                    |> P.map (\value -> ( key, value ))
            )



-- ====== ARRAY ======


pArray : Parser AST_
pArray =
    P.word1 '[' Start
        |> P.andThen (\_ -> spaces)
        |> P.andThen
            (\_ ->
                P.oneOf Start
                    [ pValue
                        |> P.andThen
                            (\entry ->
                                spaces
                                    |> P.andThen (\_ -> pArrayHelp [ entry ])
                            )
                    , P.word1 ']' ArrayEnd
                        |> P.map (\_ -> Array [])
                    ]
            )


pArrayHelp : List AST -> Parser AST_
pArrayHelp revEntries =
    P.oneOf ArrayEnd
        [ P.word1 ',' ArrayEnd
            |> P.andThen (\_ -> spaces)
            |> P.andThen (\_ -> pValue)
            |> P.andThen
                (\entry ->
                    spaces
                        |> P.andThen (\_ -> pArrayHelp (entry :: revEntries))
                )
        , P.word1 ']' ArrayEnd
            |> P.map (\_ -> Array (List.reverse revEntries))
        ]



-- ====== STRING ======


pString : (Row -> Col -> ParseError) -> Parser Snippet.Snippet
pString start =
    P.Parser <|
        \(P.State st) ->
            if st.pos < st.end && P.unsafeIndex st.src st.pos == '"' then
                let
                    pos1 : Int
                    pos1 =
                        st.pos + 1

                    col1 : Col
                    col1 =
                        st.col + 1

                    ( ( status, newPos ), ( newRow, newCol ) ) =
                        pStringHelp st.src pos1 st.end st.row col1
                in
                case status of
                    GoodString ->
                        let
                            off : Int
                            off =
                                -- FIXME pos1 - unsafeForeignPtrToPtr st.src
                                pos1

                            len : Int
                            len =
                                (newPos - pos1) - 1

                            snp : Snippet.Snippet
                            snp =
                                Snippet.Snippet
                                    { fptr = st.src
                                    , offset = off
                                    , length = len
                                    , offRow = st.row
                                    , offCol = col1
                                    }

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, row = newRow, col = newCol }
                        in
                        P.Cok snp newState

                    BadString problem ->
                        P.Cerr newRow newCol (StringProblem problem)

            else
                P.Eerr st.row st.col start


type StringStatus
    = GoodString
    | BadString StringProblem


pStringHelp : String -> Int -> Int -> Row -> Col -> ( ( StringStatus, Int ), ( Row, Col ) )
pStringHelp src pos end row col =
    if pos >= end then
        ( ( BadString BadStringEnd, pos ), ( row, col ) )

    else
        case P.unsafeIndex src pos of
            '"' ->
                ( ( GoodString, pos + 1 ), ( row, col + 1 ) )

            '\n' ->
                ( ( BadString BadStringEnd, pos ), ( row, col ) )

            '\\' ->
                let
                    pos1 : Int
                    pos1 =
                        pos + 1
                in
                if pos1 >= end then
                    ( ( BadString BadStringEnd, pos1 ), ( row + 1, col ) )

                else
                    case P.unsafeIndex src pos1 of
                        '"' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        '\\' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        '/' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        'b' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        {- f -}
                        'f' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        {- n -}
                        'n' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        {- r -}
                        'r' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        {- t -}
                        't' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        {- u -}
                        'u' ->
                            let
                                pos6 : Int
                                pos6 =
                                    pos + 6
                            in
                            if
                                (pos6 <= end)
                                    && isHex (P.unsafeIndex src (pos + 2))
                                    && isHex (P.unsafeIndex src (pos + 3))
                                    && isHex (P.unsafeIndex src (pos + 4))
                                    && isHex (P.unsafeIndex src (pos + 5))
                            then
                                pStringHelp src pos6 end row (col + 6)

                            else
                                ( ( BadString BadStringEscapeHex, pos ), ( row, col ) )

                        _ ->
                            ( ( BadString BadStringEscapeChar, pos ), ( row, col ) )

            word ->
                if Char.toCode word < 0x20 then
                    ( ( BadString BadStringControlChar, pos ), ( row, col ) )

                else
                    let
                        newPos : Int
                        newPos =
                            pos + P.getCharWidth word
                    in
                    pStringHelp src newPos end row (col + 1)


isHex : Char -> Bool
isHex word =
    let
        code : Int
        code =
            Char.toCode word
    in
    (0x30 {- 0 -} <= code)
        && (code <= 0x39 {- 9 -})
        || (0x61 {- a -} <= code)
        && (code <= 0x66 {- f -})
        || (0x41 {- A -} <= code)
        && (code <= 0x46 {- F -})



-- ====== SPACES ======


spaces : Parser ()
spaces =
    P.Parser <|
        \((P.State st) as state) ->
            let
                ( newPos, newRow, newCol ) =
                    eatSpaces st.src st.pos st.end st.row st.col
            in
            if st.pos == newPos then
                P.Eok () state

            else
                let
                    newState : P.State
                    newState =
                        P.State { st | pos = newPos, row = newRow, col = newCol }
                in
                P.Cok () newState


eatSpaces : String -> Int -> Int -> Row -> Col -> ( Int, Row, Col )
eatSpaces src pos end row col =
    if pos >= end then
        ( pos, row, col )

    else
        case P.unsafeIndex src pos of
            ' ' ->
                eatSpaces src (pos + 1) end row (col + 1)

            '\t' ->
                eatSpaces src (pos + 1) end row (col + 1)

            '\n' ->
                eatSpaces src (pos + 1) end (row + 1) 1

            {- \r -}
            '\u{000D}' ->
                eatSpaces src (pos + 1) end row col

            _ ->
                ( pos, row, col )



-- ====== INTS ======


pInt : Parser AST_
pInt =
    P.Parser <|
        \(P.State st) ->
            if st.pos >= st.end then
                P.Eerr st.row st.col Start

            else
                let
                    word : Char
                    word =
                        P.unsafeIndex st.src st.pos
                in
                if not (isDecimalDigit word) then
                    P.Eerr st.row st.col Start

                else if word == '0' then
                    let
                        pos1 : Int
                        pos1 =
                            st.pos + 1

                        newState : P.State
                        newState =
                            P.State { st | pos = pos1, col = st.col + 1 }
                    in
                    if pos1 < st.end then
                        let
                            word1 : Char
                            word1 =
                                P.unsafeIndex st.src pos1
                        in
                        if isDecimalDigit word1 then
                            P.Cerr st.row (st.col + 1) NoLeadingZeros

                        else if word1 == '.' then
                            P.Cerr st.row (st.col + 1) NoFloats

                        else
                            P.Cok (Int 0) newState

                    else
                        P.Cok (Int 0) newState

                else
                    let
                        ( status, n, newPos ) =
                            chompInt st.src (st.pos + 1) st.end (Char.toCode word - 0x30 {- 0 -})

                        len : Int
                        len =
                            newPos - st.pos
                    in
                    case status of
                        GoodInt ->
                            let
                                newState : P.State
                                newState =
                                    P.State { st | pos = newPos, col = st.col + len }
                            in
                            P.Cok (Int n) newState

                        BadIntEnd ->
                            P.Cerr st.row (st.col + len) NoFloats


type IntStatus
    = GoodInt
    | BadIntEnd


chompInt : String -> Int -> Int -> Int -> ( IntStatus, Int, Int )
chompInt src pos end n =
    if pos < end then
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if isDecimalDigit word then
            let
                m : Int
                m =
                    10 * n + (Char.toCode word - 0x30 {- 0 -})
            in
            chompInt src (pos + 1) end m

        else if word == '.' || word == 'e' || word == 'E' then
            ( BadIntEnd, n, pos )

        else
            ( GoodInt, n, pos )

    else
        ( GoodInt, n, pos )


isDecimalDigit : Char -> Bool
isDecimalDigit word =
    let
        code : Int
        code =
            Char.toCode word
    in
    code <= 0x39 {- 9 -} && code >= {- 0 -} 0x30
