module Compiler.Json.Decode exposing
    ( Decoder
    , fromByteString
    , Error(..), Problem(..), DecodeExpectation(..), ParseError(..), StringProblem(..)
    , string, customString, int, bool
    , list, nonEmptyList, pair
    , field, optionalField, pairs, KeyDecoder(..)
    , stdDict
    , map, pure, apply, andThen, oneOf
    , failure, mapError
    )

{-| The compiler reads JSON files of its own, such as `elm.json`, and when one
is wrong it has to say where in the file. This module parses and decodes JSON
keeping the position of every value, so that a failure can be shown against the
text it came from.

A `Decoder` here does not work on `Json.Decode.Value`. `fromByteString` first
parses the whole text, with this module's own parser, into a tree in which
every value records its _region_: the row and column where it starts and the
row and column just past its last character, both counted from 1. It then runs
the decoder over that tree. A failure at either step is an `Error` that carries
the whole text alongside the problem.

The parser reads less than JSON, and reads strings differently. Three facts
follow.

  - A string's value is its text as written between the quotes. Escape
    sequences are checked when parsing but never decoded, so the JSON `"a\"b"`
    decodes to the four characters `a\"b`. Object keys are compared in the same
    form, so a key the file writes with escapes does not match its decoded text.
  - The only numbers are non-negative integers. A minus sign, a fraction or an
    exponent is a parse error.
  - `null` parses, but no decoder here is for it: `string`, `customString`,
    `int`, `bool` and the array and object decoders all reject it.

`list` and `nonEmptyList` wrap a failing element's problem in an `Index`, and
`field`, `optionalField`, `pairs` and `stdDict` wrap a failing value's in a
`Field`. When an object has the same key twice, `field` and `optionalField`
take the first, `pairs` keeps both in file order, and `stdDict` keeps the last.

The second half of the file is the parser.


# Decoder Type

@docs Decoder


# Running Decoders

@docs fromByteString


# Error Types

@docs Error, Problem, DecodeExpectation, ParseError, StringProblem


# Primitive Decoders

@docs string, customString, int, bool


# Collection Decoders

@docs list, nonEmptyList, pair


# Object Decoders

@docs field, optionalField, pairs, KeyDecoder


# Dictionaries

@docs stdDict


# Combinators

@docs map, pure, apply, andThen, oneOf


# Error Handling

@docs failure, mapError

-}

import Compiler.AST.Snippet as Snippet
import Compiler.Data.NonEmptyList as NE
import Compiler.Json.String as Json
import Compiler.Parse.Keyword as K
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Reporting.Annotation as A
import Dict
import Utils.Crash exposing (crash)



-- ====== RUNNERS ======


{-| Parses `src` as JSON and runs the decoder on the value it holds.

`src` must hold exactly one value, with nothing but whitespace (spaces, tabs,
newlines and carriage returns) before or after it; anything else after the
value is a `BadEnd`. Either kind of failure carries `src`.

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


{-| A reading of a parsed JSON value as an `a`, which either gives the `a` or
fails with a `Problem` saying where and why.

`x` is the caller's own error type, for failures that are not about the kind of
value found: those of `failure`, of `nonEmptyList` on an empty array, and of the
parsers given to `customString` and in a `KeyDecoder`. `mapError` changes it.

A decoder is made from the decoders and combinators in this module and run by
`fromByteString`.

-}
type Decoder x a
    = Decoder (AST -> Result (Problem x) a)



-- ====== ERRORS ======


{-| Why `fromByteString` failed: the text could not be parsed, or it parsed and
the decoder rejected the value.

Both constructors carry, as their `String`, the whole text that was given to
`fromByteString`, so that the positions in the problem can be shown against it.
`DecodeProblem` carries why the decoder rejected the value, and `ParseProblem`
why the parser stopped.

-}
type Error x
    = DecodeProblem String (Problem x)
    | ParseProblem String ParseError



-- ====== DECODE PROBLEMS ======


{-| Why a decoder rejected a value, given as the path from that value down to
the place where it failed.

`Field` says the failure is inside the value of the named key. Through `field`
or `optionalField` the name is the key that was asked for; through `pairs` or
`stdDict` it is the key as the file writes it, escapes included.

`Index` says the failure is inside the array element at that position, counted
from 0. `pair` reports a failing element without an `Index`.

`OneOf` holds the problems of every decoder `oneOf` tried, the first decoder's
first and the rest after it in the order they were tried.

`Failure` is an error of the caller's type at the region of the value being
decoded. When a key decoder fails on a key, the region is the key's and no
`Field` wraps it.

`Expecting` is a value that is not what was wanted, at the given region, with
what was wanted there.

-}
type Problem x
    = Field String (Problem x)
    | Index Int (Problem x)
    | OneOf (Problem x) (List (Problem x))
    | Failure A.Region x
    | Expecting A.Region DecodeExpectation


{-| What a decoder wanted where it found something else.

`TObject`, `TArray`, `TString`, `TInt` and `TBool` each name the kind of value
that was wanted.

`TObjectWith` is an object holding the named key: `field` found an object, but
not the key in it.

`TArrayPair` is an array of exactly two elements: `pair` found an array, and the
`Int` is how many elements it had.

-}
type DecodeExpectation
    = TObject
    | TArray
    | TString
    | TInt
    | TBool
    | TObjectWith String
    | TArrayPair Int



-- ====== COMBINATORS ======


{-| Produces a decoder that applies `func` to whatever the given decoder
produces.
-}
map : (a -> b) -> Decoder x a -> Decoder x b
map func (Decoder decodeA) =
    Decoder (Result.map func << decodeA)


{-| Produces a decoder that succeeds with `a` on any value, without looking at
it.
-}
pure : a -> Decoder x a
pure a =
    Decoder (\_ -> Ok a)


{-| Produces a decoder that runs both decoders on the same value and applies the
function the second gives to the argument the first gives.

The argument comes first so that a decoder can be built as
`pure f |> apply decodeA |> apply decodeB`. The argument's decoder runs first,
so when both fail its problem is the one reported.

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


{-| Produces a decoder that runs the given decoder, passes what it gives to
`callback`, and runs the decoder `callback` returns on the same value.
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


{-| A decoder for a JSON string, giving its text as written between the quotes.
Escape sequences are kept as they are written, not decoded, as
`Compiler.Json.String.fromSnippet` says.
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


{-| Produces a decoder for a JSON string whose text is read by `parser`.

The parser runs over the text between the quotes as written, escapes not
decoded, and reports positions in the whole file. It must read all of that
text: if it stops early, the error is `toBadEnd` given the row and column where
it stopped. Either error becomes a `Failure` at the region of the whole string,
quotes included.

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


{-| A decoder for a JSON number, which in this module is always an integer
written with no sign, fraction or exponent, since that is all the parser reads.
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



-- ====== BOOL ======


{-| A decoder for `true` or `false`.
-}
bool : Decoder x Bool
bool =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                TRUE ->
                    Ok True

                FALSE ->
                    Ok False

                _ ->
                    Err (Expecting region TBool)



-- ====== LISTS ======


{-| Produces a decoder for a JSON array whose elements all decode with
`decoder`, giving their values in order. The first element that fails stops it,
and its problem is reported inside an `Index`.
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


{-| Returns the values of `asts` decoded in turn, after the values in `revs`,
which holds those of the earlier elements latest first. `i` is the position in
the whole array of the first of `asts`, so that a failure carries its `Index`.
-}
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


{-| Produces a decoder for a JSON array of at least one element, each decoded
with `decoder`. An empty array fails with `x` as a `Failure` at the array's
region; a failing element fails as in `list`.
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


{-| Produces a decoder for a JSON array of exactly two elements, the first
decoded with the first decoder and the second with the second.

An array of any other length fails with `TArrayPair` and its length. A failing
element's problem is reported as it is, with no `Index` around it.

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


{-| How `pairs` and `stdDict` read an object's keys: a parser run over each
key's text, and the error to give when it stops before the end of the key, as a
function of the row and column where it stopped.

The parser sees the key as written, escapes not decoded, and reports positions
in the whole file. Its error, or the one for stopping early, becomes a `Failure`
at the region of the key.

-}
type KeyDecoder x a
    = KeyDecoder (P.Parser x a) (Row -> Col -> x)


{-| Produces a decoder for a JSON object as a `Dict`, with keys read by
`keyDecoder` and values by `valueDecoder`. When two keys read as the same value,
the later one in the file wins. Failures are those of `pairs`.
-}
stdDict : KeyDecoder x comparable -> Decoder x a -> Decoder x (Dict.Dict comparable a)
stdDict keyDecoder valueDecoder =
    map Dict.fromList (pairs keyDecoder valueDecoder)


{-| Produces a decoder for a JSON object as its entries, in the order the file
gives them, duplicates kept, with keys read by `keyDecoder` and values by
`valueDecoder`.

The first entry that fails stops it. A key that fails is a `Failure` at the
key's region. A value that fails has its problem inside a `Field` named by the
key as the file writes it.

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


{-| Returns the entries of `kvs` decoded in turn, after those in `revs`, which
holds the earlier entries latest first.
-}
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


{-| Returns the region of a key from its snippet: from the key's first
character to `length` columns further on the same row.

`length` counts in `String.slice` units, in which a character above U+FFFF takes
two, so for a key holding such a character the region ends past the key.

-}
snippetToRegion : Snippet.Snippet -> A.Region
snippetToRegion (Snippet.Snippet { length, offRow, offCol }) =
    A.Region (A.Position offRow offCol) (A.Position offRow (offCol + length))



-- ====== FIELDS ======


{-| Produces a decoder for the value under `key` in a JSON object, decoded with
the given decoder.

`key` is compared with each key as the file writes it, so a key written with
escapes does not match its decoded text. If the key occurs more than once, the
first is used. An object without the key fails with `TObjectWith` at the
object's region, and a value that fails has its problem inside a `Field`.

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


{-| Produces a decoder like `field` that gives `fallback` when the object has no
`key`. The value must still be an object; anything else fails with `TObject`.
-}
optionalField : String -> Decoder x a -> a -> Decoder x a
optionalField key (Decoder decodeA) fallback =
    Decoder <|
        \(A.At region ast) ->
            case ast of
                Object kvs ->
                    case findField key kvs of
                        Just value ->
                            Result.mapError (Field key)
                                (decodeA value)

                        Nothing ->
                            Ok fallback

                _ ->
                    Err (Expecting region TObject)


{-| Returns the value of the first entry whose key, as the file writes it,
equals `key`.
-}
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


{-| Produces a decoder that tries `decoders` in order on the same value and
gives the result of the first that succeeds. When all fail, the problem is a
`OneOf` holding all of theirs.

Given an empty list, the decoder crashes, through `Utils.Crash`, when it is run.

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


{-| Returns the result of the first of `decoders` to succeed on `ast`, or, when
none does, the `OneOf` of every problem so far. `p` is the latest problem and
`ps` the earlier ones, latest first.
-}
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


{-| Returns a `OneOf` of `prob :: ps`, which are listed latest first, put back
into the order they occurred and followed by `problems`.
-}
oneOfError : List (Problem x) -> Problem x -> List (Problem x) -> Problem x
oneOfError problems prob ps =
    case ps of
        [] ->
            OneOf prob problems

        p :: ps_ ->
            oneOfError (prob :: problems) p ps_



-- ====== FAILURE ======


{-| Produces a decoder that fails on any value with `x` as a `Failure` at that
value's region.
-}
failure : x -> Decoder x a
failure x =
    Decoder <|
        \(A.At region _) ->
            Err (Failure region x)



-- ====== ERRORS ======


{-| Produces a decoder like the given one whose `Failure` errors are passed
through `func`. Everything else about a problem is kept.
-}
mapError : (x -> y) -> Decoder x a -> Decoder y a
mapError func (Decoder decodeA) =
    Decoder (Result.mapError (mapErrorHelp func) << decodeA)


{-| Returns `problem` with `func` applied to the error of every `Failure` in it.
-}
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


{-| A parsed JSON value at the region of the file it covers.
-}
type alias AST =
    A.Located AST_


{-| A parsed JSON value, whose members carry regions of their own.

An `Array` holds its elements and an `Object` its entries in the order the file
gives them, an object's duplicates kept. Each key, like the text of a `String`,
is a snippet naming where the text between the quotes lies in the file, as
`Compiler.AST.Snippet` describes; the text is kept as written, escapes not
decoded. `Int` holds the number read. `TRUE`, `FALSE` and `NULL` are the three
literal words.

-}
type AST_
    = Array (List AST)
    | Object (List ( Snippet.Snippet, AST ))
    | String Snippet.Snippet
    | Int Int
    | TRUE
    | FALSE
    | NULL



-- ====== PARSE ======


{-| A parser of this module's JSON, failing with a `ParseError`. This is a name
for `P.Parser ParseError a`, not a new type.
-}
type alias Parser a =
    P.Parser ParseError a


{-| Why the text could not be parsed, with the row and column where the failure
was reported, both counted from 1.

`Start` is reported where the top-level value could not be read: the text there
does not begin a string, object, array, unsigned integer, or `true`, `false` or
`null` as a whole word. A value that cannot be read inside an object or array
is handled like a mistake in the structure of an object or array, as described
below, and most of those also become `Start`.

`StringProblem` is a string, value or key, that is not well formed; the
`StringProblem` says how.

`NoLeadingZeros` is a number whose first digit is a `0` with another digit
after it, reported at that second digit.

`NoFloats` is a number with a `.`, `e` or `E` after its digits, reported at that
character. A `0` followed by `e` or `E` is not reported this way: the `0` is
read as a whole number, and the error is whatever the text after it causes.

`BadEnd` is text other than whitespace after the one value.

`ObjectField`, `ObjectColon`, `ObjectEnd` and `ArrayEnd` name a missing key,
colon, comma or closing bracket, but as the parser is written only `ObjectEnd`
is ever produced. A mistake in the structure of an object or array fails without
counting as having read anything, as `Compiler.Parse.Primitives` describes for
`andThen`, so it is passed outwards. The nearest object, the one it is in or one
around it, that has already read a comma and the entry after it turns it into
`ObjectEnd`, at the position where that object looked for its next `,` or `}`.
With no such object it becomes `Start`, at the first character of the top-level
value.

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


{-| What is wrong with a string that is not well formed.

`BadStringEnd` is a string with no closing quote before the end of its line or
of the text, reported where the line or the text ended. When the text ends just
after a backslash, the position given is the backslash's column on the row
below it.

`BadStringControlChar` is a character below U+0020 other than a newline, a tab
included, reported at that character.

`BadStringEscapeChar` is a backslash followed by a character that begins no JSON
escape, and `BadStringEscapeHex` is `\u` not followed by four hexadecimal
digits. Both are reported at the backslash.

-}
type StringProblem
    = BadStringEnd
    | BadStringControlChar
    | BadStringEscapeChar
    | BadStringEscapeHex



-- ====== PARSE AST ======


{-| A parser for a whole JSON text: one value, with optional whitespace before
and after it. It does not check that the text ends there.
-}
pFile : Parser AST
pFile =
    spaces
        |> P.andThen (\_ -> pValue)
        |> P.andThen
            (\value ->
                P.map (\_ -> value) spaces
            )


{-| A parser for one JSON value, at the region it covers.

When every kind of value fails without having read anything, it fails with
`Start` at the position where it began, and the alternatives' own errors are
discarded.

-}
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


{-| A parser for a JSON object, from its `{` to its `}`, with whitespace allowed
between the parts.
-}
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


{-| Produces the parser for one round of reading an object after its first
entry: a `,` and the next entry, which continues the loop, or the `}`, which
ends it with the entries in file order. `revEntries` holds the entries read so
far, latest first.
-}
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


{-| A parser for one object entry: a key, a `:` and a value, with whitespace
allowed before and after the `:` but not read after the value.
-}
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


{-| A parser for a JSON array, from its `[` to its `]`, with whitespace allowed
between the parts.
-}
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


{-| Produces a parser for the rest of an array after an element: any number of
`,` and an element, then the `]`. `revEntries` holds the elements read so far,
latest first.

It calls itself through `P.andThen` rather than using `P.loop`, so its own
rounds never turn a failure into one that has read input, unlike an object's.

-}
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


{-| Produces a parser for a JSON string that gives a snippet of the text
between the quotes, as written.

When the next character is not `"`, it fails with `start` without reading
anything; this lets the caller choose the error for a value and for a key. A
string that is not well formed fails, having read input, with a
`StringProblem` at the position `pStringHelp` gives.

-}
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


{-| Whether the text `pStringHelp` scanned was a well-formed string, or what was
wrong with it.
-}
type StringStatus
    = GoodString
    | BadString StringProblem


{-| Scans the text of a string from `pos`, just past its opening quote, at `row`
and `col`. Returns whether it is well formed, then the position, row and column
just past its closing quote; or, for one that is not, the problem and where it
was found.

The escapes accepted are `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t` and
`\u` with four hexadecimal digits. The column moves on by one for each
character, and by the length of an escape for an escape.

-}
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

                        'f' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        'n' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        'r' ->
                            pStringHelp src (pos + 2) end row (col + 2)

                        't' ->
                            pStringHelp src (pos + 2) end row (col + 2)

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


{-| Returns whether `word` is a hexadecimal digit, `0`-`9`, `a`-`f` or `A`-`F`.
-}
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


{-| A parser that skips JSON whitespace: spaces, tabs, newlines and carriage
returns. It succeeds having read nothing when there is none.
-}
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


{-| Returns the position, row and column just past the run of whitespace that
starts at `pos`. A newline starts a new row at column 1, and a carriage return
does not move the column.
-}
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


{-| A parser for a JSON number, which must be an integer with no sign, no
fraction and no exponent.

When the next character is not a digit, a `-` included, it fails with `Start`
without reading anything. The other failures, `NoLeadingZeros` and `NoFloats`,
are reported having read input, at the positions `ParseError` gives.

-}
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


{-| Whether the digits `chompInt` read ended where an integer may end, or at a
`.`, `e` or `E` that would make the number a fraction or an exponent.
-}
type IntStatus
    = GoodInt
    | BadIntEnd


{-| Reads digits from `pos` onto `n`, the value of the digits before them.
Returns the status, the value, and the position where the digits stop.
-}
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


{-| Returns whether `word` is one of the digits `0`-`9`.
-}
isDecimalDigit : Char -> Bool
isDecimalDigit word =
    let
        code : Int
        code =
            Char.toCode word
    in
    code <= 0x39 {- 9 -} && code >= {- 0 -} 0x30
