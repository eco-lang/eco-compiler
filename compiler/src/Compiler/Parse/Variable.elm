module Compiler.Parse.Variable exposing
    ( Upper(..)
    , lower, upper, moduleName, foreignUpper, foreignAlpha
    , isReservedWord
    , chompInnerChars
    , getInnerWidth, getInnerWidthHelp, getUpperWidth
    )

{-| This module decides what counts as a name in Elm source, and holds the
parsers that read one.

An _identifier_ is a first character followed by any number of _inner
characters_. The first character is a lower-case letter for the name of a
value, and an upper-case letter for the name of a type, a constructor or one
part of a module name. An inner character is a letter, a digit or `_`. A
_qualified_ name is preceded by its _home_, the name of a module, written as
upper-case identifiers each followed by a dot, as in `List.map` or
`Json.Decode.Decoder`. The parsers with `foreign` in their names read a name
that may be qualified.

A lower-case identifier may not be a _reserved word_: `if`, `then`, `else`,
`case`, `of`, `let`, `in`, `type`, `module`, `where`, `import`, `exposing`, `as`
or `port`. Only an unqualified name is checked against them.

Each parser is written directly as a function on the parser state, with
positions and columns as `Compiler.Parse.Primitives` describes them. Every
failure is reported with `Eerr`, as having consumed nothing, except a dot in a
module name that is not followed by an upper-case identifier, which is `Cerr`.

Most of the file is the character tests, which give a character's _width_: how
many units of the position it takes as part of an identifier, or 0 when it
cannot be one. An ASCII character is tested directly, and has a width of 1 when
it is allowed in that place. Any other character is tested as though the text
were UTF-8 bytes, which it is not. A character with a code from 0xC0 to 0xF7 is
taken together with the one, two or three characters after it, and the group is
decoded as the bytes of one UTF-8 character. The group has a width of 2, 3 or 4
when the decoded character is an ASCII letter of the case required, since
elm/core's `Char.isUpper`, `Char.isLower` and `Char.isAlpha` accept only ASCII
letters. Any other character has a width of 0. So a non-ASCII letter is accepted
only as part of a group that decodes to an ASCII letter, as in `Âb`, and such a
group can put characters that are not letters into a name: `xÃ$` is one
identifier. Whatever its width, an identifier character advances the column by
one. The characters after the first in a group are read without checking them
against the end of the input, and one past the end of the whole text is a crash
in `unsafeIndex`.


# Variable Types

@docs Upper


# Parsing Variables

@docs lower, upper, moduleName, foreignUpper, foreignAlpha


# Reserved Words

@docs isReservedWord


# Character Utilities

@docs chompInnerChars
@docs getInnerWidth, getInnerWidthHelp, getUpperWidth

-}

import Bitwise
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Data.Set as EverySet exposing (EverySet)



-- ====== LOCAL UPPER ======


{-| Produces a parser for an unqualified upper-case identifier. It stops before
a dot, so on `Maybe.Just` it reads `Maybe`. When no upper-case identifier starts
at its position, it fails with `Eerr` there.
-}
upper : (Row -> Col -> x) -> P.Parser x Name
upper toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    chompUpper st.src st.pos st.end st.col
            in
            if newPos == st.pos then
                P.Eerr st.row st.col toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src st.pos newPos
                in
                P.Cok name (P.State { st | pos = newPos, col = newCol })



-- ====== LOCAL LOWER ======


{-| Produces a parser for an unqualified lower-case identifier that is not a
reserved word. It fails with `Eerr` at its starting position when no lower-case
identifier starts there, and also when the identifier it reads is reserved.
-}
lower : (Row -> Col -> x) -> P.Parser x Name
lower toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    chompLower st.src st.pos st.end st.col
            in
            if newPos == st.pos then
                P.Eerr st.row st.col toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src st.pos newPos
                in
                if isReservedWord name then
                    P.Eerr st.row st.col toError

                else
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, col = newCol }
                    in
                    P.Cok name newState


{-| Returns whether `name` is one of the reserved words, which `lower` refuses
as an identifier.
-}
isReservedWord : Name.Name -> Bool
isReservedWord name =
    EverySet.member identity name reservedWords


{-| The reserved words: the lower-case identifiers that `lower` refuses.
-}
reservedWords : EverySet String Name
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



-- ====== MODULE NAME ======


{-| Produces a parser for a module name: one or more upper-case identifiers
joined by dots, such as `Html` or `Json.Decode`, read as one `Name` that keeps
its dots.

It fails with `Eerr` at its starting position when no upper-case identifier
starts there. A dot that is not followed by an upper-case identifier, as in
`Json.decode` or `Json.` followed by a space, is a failure with `Cerr` at the
column just after the dot.

-}
moduleName : (Row -> Col -> x) -> P.Parser x Name
moduleName toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( pos1, col1 ) =
                    chompUpper st.src st.pos st.end st.col
            in
            if st.pos == pos1 then
                P.Eerr st.row st.col toError

            else
                let
                    ( status, newPos, newCol ) =
                        moduleNameHelp st.src pos1 st.end col1
                in
                case status of
                    Good ->
                        let
                            name : Name
                            name =
                                Name.fromPtr st.src st.pos newPos

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, col = newCol }
                        in
                        P.Cok name newState

                    Bad ->
                        P.Cerr st.row newCol toError


{-| How the scan of the dotted parts of a module name ended. `Good` means it
stopped where there is no dot, either at a character that is not a dot or at
the end of the input. `Bad` means it found a dot with no upper-case identifier
after it.
-}
type ModuleNameStatus
    = Good
    | Bad


{-| Returns how the scan of the rest of a module name ends, starting from `pos`
just after an upper-case identifier, with the position and column where it
stopped: the end of the name for `Good`, or just after the dot for `Bad`.
-}
moduleNameHelp : String -> Int -> Int -> Col -> ( ModuleNameStatus, Int, Col )
moduleNameHelp src pos end col =
    if isDot src pos end then
        let
            pos1 : Int
            pos1 =
                pos + 1

            ( newPos, newCol ) =
                chompUpper src pos1 end (col + 1)
        in
        if pos1 == newPos then
            ( Bad, newPos, newCol )

        else
            moduleNameHelp src newPos end newCol

    else
        ( Good, pos, col )



-- ====== FOREIGN UPPER ======


{-| An upper-case name as written in source, with or without its home.

`Unqualified` carries the name alone. `Qualified` carries the home, without its
final dot, and then the name, so `Json.Decode.Decoder` is
`Qualified "Json.Decode" "Decoder"`.

-}
type Upper
    = Unqualified Name
    | Qualified Name Name


{-| Produces a parser for an upper-case name with or without its home, such as
`Just` or `Maybe.Just`.

A dot after an upper-case identifier is always read as part of the name, so
every part must be upper-case. Where a dot is not followed by an upper-case
identifier, as in `Maybe.withDefault`, the parser fails with `Eerr` at the
column just after that dot. It also fails with `Eerr` at its starting position
when no upper-case identifier starts there.

-}
foreignUpper : (Row -> Col -> x) -> P.Parser x Upper
foreignUpper toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( upperStart, upperEnd, newCol ) =
                    foreignUpperHelp st.src st.pos st.end st.col
            in
            if upperStart == upperEnd then
                P.Eerr st.row newCol toError

            else
                let
                    newState : P.State
                    newState =
                        P.State { st | pos = upperEnd, col = newCol }

                    name : Name
                    name =
                        Name.fromPtr st.src upperStart upperEnd

                    upperName : Upper
                    upperName =
                        if upperStart == st.pos then
                            Unqualified name

                        else
                            let
                                home : Name
                                home =
                                    Name.fromPtr st.src st.pos (upperStart + -1)
                            in
                            Qualified home name
                in
                P.Cok upperName newState


{-| Returns where the last part of a possibly qualified upper-case name starting
at `pos` begins and ends, and the column at its end; the home runs from `pos` to
the dot before that last part. When a part is missing, the begin and end are
equal, at the position where an upper-case identifier was expected.
-}
foreignUpperHelp : String -> Int -> Int -> Col -> ( Int, Int, Col )
foreignUpperHelp src pos end col =
    let
        ( newPos, newCol ) =
            chompUpper src pos end col
    in
    if pos == newPos then
        ( pos, pos, col )

    else if isDot src newPos end then
        foreignUpperHelp src (newPos + 1) end (newCol + 1)

    else
        ( pos, newPos, newCol )



-- ====== FOREIGN ALPHA ======


{-| Produces a parser for a reference to a value or constructor, with or
without its home, read as an expression: `Src.Var` for `x` or `Just`, and
`Src.VarQual` with the home for `List.map` or `Maybe.Just`. The variable type is
`LowVar` when the last part is lower-case and `CapVar` when it is upper-case.

Upper-case parts followed by a dot are read as the home, and the first
lower-case part ends the name, so on `List.map.x` it reads `List.map`. Only an
unqualified name is checked against the reserved words, and one that is
reserved fails with `Eerr` at the starting position. When no part starts at the
position, or none follows a dot, the parser fails with `Eerr` at the column
where a part was expected.

-}
foreignAlpha : (Row -> Col -> x) -> P.Parser x Src.Expr_
foreignAlpha toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( ( alphaStart, alphaEnd ), ( newCol, varType ) ) =
                    foreignAlphaHelp st.src st.pos st.end st.col
            in
            if alphaStart == alphaEnd then
                P.Eerr st.row newCol toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src alphaStart alphaEnd

                    newState : P.State
                    newState =
                        P.State { st | pos = alphaEnd, col = newCol }
                in
                if alphaStart == st.pos then
                    if isReservedWord name then
                        P.Eerr st.row st.col toError

                    else
                        P.Cok (Src.Var varType name) newState

                else
                    let
                        home : Name
                        home =
                            Name.fromPtr st.src st.pos (alphaStart + -1)
                    in
                    P.Cok (Src.VarQual varType home name) newState


{-| Returns where the last part of a possibly qualified name starting at `pos`
begins and ends, the column at its end, and whether that part is lower-case or
upper-case. When a part is missing, the begin and end are equal, at the
position where a part was expected, and the variable type is `CapVar`.
-}
foreignAlphaHelp : String -> Int -> Int -> Col -> ( ( Int, Int ), ( Col, Src.VarType ) )
foreignAlphaHelp src pos end col =
    let
        ( lowerPos, lowerCol ) =
            chompLower src pos end col
    in
    if pos < lowerPos then
        ( ( pos, lowerPos ), ( lowerCol, Src.LowVar ) )

    else
        let
            ( upperPos, upperCol ) =
                chompUpper src pos end col
        in
        if pos == upperPos then
            ( ( pos, pos ), ( col, Src.CapVar ) )

        else if isDot src upperPos end then
            foreignAlphaHelp src (upperPos + 1) end (upperCol + 1)

        else
            ( ( pos, upperPos ), ( upperCol, Src.CapVar ) )



---- CHAR CHOMPERS ----
-- ====== DOTS ======


{-| Returns whether `pos` is before `end` and the character there is a dot.
-}
isDot : String -> Int -> Int -> Bool
isDot src pos end =
    pos < end && P.unsafeIndex src pos == '.'



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
`pos`: 1 for `A` to `Z`, 2 to 4 for a group of characters accepted as the
module docstring describes, and 0 when there is none, including at or past
`end`.
-}
getUpperWidth : String -> Int -> Int -> Int
getUpperWidth src pos end =
    if pos < end then
        getUpperWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width `getUpperWidth` gives, where `word` is the character at
`pos` in `src`. The third argument, the end of the input, is ignored, so a
group is decoded from the characters after `pos` without checking them against
the end; past the end of `src`, `unsafeIndex` crashes.
-}
getUpperWidthHelp : String -> Int -> Int -> Char -> Int
getUpperWidthHelp src pos _ word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x41 {- A -} && code <= 0x5A {- Z -} then
        1

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isUpper (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isUpper (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isUpper (chr4 src pos word) then
            4

        else
            0

    else
        0



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
`pos`: 1 for `a` to `z`, 2 to 4 for an accepted group of characters, and 0 when
there is none, including at or past `end`.
-}
getLowerWidth : String -> Int -> Int -> Int
getLowerWidth src pos end =
    if pos < end then
        getLowerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width `getLowerWidth` gives, where `word` is the character at
`pos` in `src`. Like `getUpperWidthHelp`, it ignores its third argument and
reads a group without checking it against the end of the input.
-}
getLowerWidthHelp : String -> Int -> Int -> Char -> Int
getLowerWidthHelp src pos _ word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x61 {- a -} && code <= 0x7A {- z -} then
        1

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isLower (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isLower (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isLower (chr4 src pos word) then
            4

        else
            0

    else
        0



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


{-| Returns the width of the inner character at `pos`: 1 for an ASCII letter, a
digit or `_`, 2 to 4 for a group of characters accepted as the module docstring
describes, and 0 when there is none, including at or past `end`.
-}
getInnerWidth : String -> Int -> Int -> Int
getInnerWidth src pos end =
    if pos < end then
        getInnerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Returns the width of an inner character, where `word` must be the character
at `pos` in `src`: 1 for an ASCII letter, a digit or `_`, 2 to 4 for a group of
characters accepted as the module docstring describes, and 0 otherwise.

The third argument, the end of the input, is ignored. For a character with a
code from 0xC0 to 0xF7, the one to three characters after `pos` are read
whatever the end, and reading past the end of `src` crashes in `unsafeIndex`.

-}
getInnerWidthHelp : String -> Int -> Int -> Char -> Int
getInnerWidthHelp src pos _ word =
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

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isAlpha (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isAlpha (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isAlpha (chr4 src pos word) then
            4

        else
            0

    else
        0



-- ====== EXTRACT CHARACTERS ======


{-| Returns the character that `firstWord` and the character after `pos` would
encode if they were the two bytes of a UTF-8 sequence. Nothing checks that
either is in the range of such a byte.
-}
chr2 : String -> Int -> Char -> Char
chr2 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        c1 : Int
        c1 =
            (i1 - 0xC0) |> Bitwise.shiftLeftBy 6

        c2 : Int
        c2 =
            i2 - 0x80
    in
    Char.fromCode (c1 + c2)


{-| Returns the character that `firstWord` and the two characters after `pos`
would encode if they were the three bytes of a UTF-8 sequence, without checking
that any of them is in the range of such a byte.
-}
chr3 : String -> Int -> Char -> Char
chr3 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        i3 : Int
        i3 =
            unpack (P.unsafeIndex src (pos + 2))

        c1 : Int
        c1 =
            (i1 - 0xE0) |> Bitwise.shiftLeftBy 12

        c2 : Int
        c2 =
            (i2 - 0x80) |> Bitwise.shiftLeftBy 6

        c3 : Int
        c3 =
            i3 - 0x80
    in
    Char.fromCode (c1 + c2 + c3)


{-| Returns the character that `firstWord` and the three characters after `pos`
would encode if they were the four bytes of a UTF-8 sequence, without checking
that any of them is in the range of such a byte.
-}
chr4 : String -> Int -> Char -> Char
chr4 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        i3 : Int
        i3 =
            unpack (P.unsafeIndex src (pos + 2))

        i4 : Int
        i4 =
            unpack (P.unsafeIndex src (pos + 3))

        c1 : Int
        c1 =
            (i1 - 0xF0) |> Bitwise.shiftLeftBy 18

        c2 : Int
        c2 =
            (i2 - 0x80) |> Bitwise.shiftLeftBy 12

        c3 : Int
        c3 =
            (i3 - 0x80) |> Bitwise.shiftLeftBy 6

        c4 : Int
        c4 =
            i4 - 0x80
    in
    Char.fromCode (c1 + c2 + c3 + c4)


{-| Returns the code of a character, as `Char.toCode` does.
-}
unpack : Char -> Int
unpack =
    Char.toCode
