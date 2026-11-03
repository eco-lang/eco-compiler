module Compiler.Lexer.Identifier exposing
    ( isReservedWord
    , chompUpper, chompLower, chompInnerChars
    , getUpperWidth, getInnerWidth, getInnerWidthHelp
    )

{-| This module decides, a character at a time, what counts as a name in Elm
source. `Compiler.Parse.Variable` builds the parsers that read names on top of
it; the scanners here are also used wherever another token must know where a
name would end.

An _identifier_ is a first character followed by any number of _inner
characters_. The first character is a lower-case letter for the name of a
value, and an upper-case letter for the name of a type, a constructor or one
part of a module name. An inner character is a letter, an ASCII digit or `_`.

A lower-case identifier may not be a _reserved word_: `if`, `then`, `else`,
`case`, `of`, `let`, `in`, `type`, `module`, `where`, `import`, `exposing`, `as`
or `port`.

The character tests give a character's _width_: how many units of the position
it takes as part of an identifier, or 0 when it cannot be one. Positions and
columns are as `Compiler.Lexer.Primitives` describes them. An ASCII character
is tested directly, and has a width of 1 when it is allowed in that place. Any
other character is classified by its Unicode code point, as upstream Elm does
with GHC's `Data.Char`: the first character of an upper-case identifier must be
an upper-case or title-case letter (categories Lu, Lt), of a lower-case
identifier a lower-case letter (Ll), and an inner character any letter (Lu, Ll,
Lt, Lm, Lo). So `Été` and `naïve` are names, a CJK letter (Lo) may continue a
name but not start one, and a non-ASCII digit is not an inner character. The
tables are in `Compiler.Lexer.Unicode`, since elm/core's `Char.isUpper`,
`Char.isLower` and `Char.isAlpha` accept only ASCII.
`Compiler.Lexer.Primitives.codePointAt` joins a surrogate pair, so a character
above U+FFFF has a width of 2 on either host, and a lone surrogate is not an
identifier character. Nothing at or past the end of the input is read, and
whatever its width, an identifier character advances the column by one.


# Reserved Words

@docs isReservedWord


# Scanning Identifiers

@docs chompUpper, chompLower, chompInnerChars


# Character Widths

@docs getUpperWidth, getInnerWidth, getInnerWidthHelp

-}

import Compiler.Lexer.Primitives as P exposing (Col)
import Compiler.Lexer.Unicode as Unicode
import Data.Set as EverySet exposing (EverySet)



-- ====== RESERVED WORDS ======


{-| Returns whether `name` is one of the reserved words, which
`Compiler.Parse.Variable.lower` refuses as an identifier.
-}
isReservedWord : String -> Bool
isReservedWord name =
    EverySet.member identity name reservedWords


{-| The reserved words: the lower-case identifiers that
`Compiler.Parse.Variable.lower` refuses.
-}
reservedWords : EverySet String String
reservedWords =
    EverySet.fromList identity
        [ "if"
        , "then"
        , "else"
        , "case"
        , "of"
        , "let"
        , "in"
        , "type"
        , "module"
        , "where"
        , "import"
        , "exposing"
        , "as"
        , "port"
        ]



-- ====== UPPER CHARS ======


{-| Returns the position and column just after the upper-case identifier that
starts at `pos`, or `pos` and `col` themselves when none starts there.
-}
chompUpper : String -> Int -> Int -> Col -> ( Int, Col )
chompUpper src pos end col =
    let
        width : Int
        width =
            getUpperWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


{-| Returns the width of the first character of an upper-case identifier at
`pos`: 1 for `A` to `Z` or another upper-case or title-case letter in the Basic
Multilingual Plane, 2 for one above U+FFFF, and 0 when there is none, including
at or past `end`.
-}
getUpperWidth : String -> Int -> Int -> Int
getUpperWidth src pos end =
    if pos < end then
        getUpperWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width `getUpperWidth` gives, where `pos < end` and `word` is the
character at `pos` in `src`.
-}
getUpperWidthHelp : String -> Int -> Int -> Char -> Int
getUpperWidthHelp src pos end word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x41 {- A -} && code <= 0x5A {- Z -} then
        1

    else if code < 0x80 then
        0

    else
        nonAsciiWidth Unicode.isUpper src pos end code



-- ====== LOWER CHARS ======


{-| Returns the position and column just after the lower-case identifier that
starts at `pos`, or `pos` and `col` themselves when none starts there. It does
not check for reserved words.
-}
chompLower : String -> Int -> Int -> Col -> ( Int, Col )
chompLower src pos end col =
    let
        width : Int
        width =
            getLowerWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


{-| Returns the width of the first character of a lower-case identifier at
`pos`: 1 for `a` to `z` or another lower-case letter in the Basic Multilingual
Plane, 2 for one above U+FFFF, and 0 when there is none, including at or past
`end`.
-}
getLowerWidth : String -> Int -> Int -> Int
getLowerWidth src pos end =
    if pos < end then
        getLowerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width `getLowerWidth` gives, where `pos < end` and `word` is the
character at `pos` in `src`.
-}
getLowerWidthHelp : String -> Int -> Int -> Char -> Int
getLowerWidthHelp src pos end word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x61 {- a -} && code <= 0x7A {- z -} then
        1

    else if code < 0x80 then
        0

    else
        nonAsciiWidth Unicode.isLower src pos end code



-- ====== INNER CHARS ======


{-| Returns the position and column just after the run of inner characters that
starts at `pos`, which is `pos` and `col` themselves when the run is empty.
-}
chompInnerChars : String -> Int -> Int -> Col -> ( Int, Col )
chompInnerChars src pos end col =
    let
        width : Int
        width =
            getInnerWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


{-| Returns the width of the inner character at `pos`: 1 for an ASCII letter, an
ASCII digit, `_` or another letter in the Basic Multilingual Plane, 2 for a
letter above U+FFFF, and 0 when there is none, including at or past `end`.
-}
getInnerWidth : String -> Int -> Int -> Int
getInnerWidth src pos end =
    if pos < end then
        getInnerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width `getInnerWidth` gives, where `pos < end` and `word` must
be the character at `pos` in `src`. Nothing at or past `end` is read.
-}
getInnerWidthHelp : String -> Int -> Int -> Char -> Int
getInnerWidthHelp src pos end word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x61 {- a -} && code <= 0x7A {- z -} then
        1

    else if code >= 0x41 {- A -} && code <= 0x5A {- Z -} then
        1

    else if code >= 0x30 {- 0 -} && code <= 0x39 {- 9 -} then
        1

    else if code == 0x5F {- _ -} then
        1

    else if code < 0x80 then
        0

    else
        nonAsciiWidth Unicode.isAlpha src pos end code



-- ====== NON-ASCII CHARACTERS ======


{-| Returns the width of the non-ASCII character at `pos`, whose `Char` as
`P.unsafeIndex` returned it has code `code`, when `isClass` accepts its code
point, and 0 when it does not.
-}
nonAsciiWidth : (Int -> Bool) -> String -> Int -> Int -> Int -> Int
nonAsciiWidth isClass src pos end code =
    let
        ( cp, width ) =
            P.codePointAt src pos end code
    in
    if isClass cp then
        width

    else
        0
